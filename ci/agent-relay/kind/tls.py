"""Host-only CA key and strict-verifier-compatible local server certificate."""
import re
import hashlib


def create(stack, hosts, namespace, *, preserve_ca=False):
    ca, ca_key = stack.state / "ca.crt", stack.state / "ca.key"
    cert, key = stack.state / "tls.crt", stack.state / "tls.key"

    def archive_ca():
        if not ca.exists() or stack.cmd(["openssl", "x509", "-in", ca, "-noout"], check=False).returncode != 0:
            return
        history = stack.state / "ca-history"
        history.mkdir(mode=0o700, exist_ok=True)
        previous = ca.read_bytes()
        archived = history / (hashlib.sha256(previous).hexdigest() + ".crt")
        if archived.exists():
            if archived.read_bytes() != previous:
                raise ValueError("saved CA history differs; refusing to overwrite it")
            return
        archived.touch(mode=0o600)
        archived.write_bytes(previous)

    def current(path, extension, seconds):
        if not path.exists():
            return False
        parsed = stack.cmd(["openssl", "x509", "-in", path, "-noout", "-text"], check=False)
        return parsed.returncode == 0 and extension in parsed.stdout and stack.cmd(
            ["openssl", "x509", "-in", path, "-checkend", str(seconds), "-noout"], check=False).returncode == 0

    renew_ca = not current(ca, "Subject Key Identifier", 31 * 86400)
    if renew_ca and preserve_ca:
        from stack import StackError
        raise StackError("retained CA requires renewal; refused to change the trusted root")
    if renew_ca:
        # Keep the exact old public certificate before renewal, so its trust
        # remains removable even after ca.crt is replaced.
        archive_ca()
        config = stack.state / "ca.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\n"
                          "CN=Agent Relay kind local CA\n[ext]\nbasicConstraints=critical,CA:TRUE\n"
                          "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
        if not ca_key.exists():
            stack.cmd(["openssl", "genrsa", "-out", ca_key, "2048"])
            ca_key.chmod(0o600)
        # Reuse this fixture's CA key when upgrading an old/expiring CA cert.
        stack.cmd(["openssl", "req", "-x509", "-new", "-key", ca_key, "-days", "365", "-config", config, "-out", ca])
    def matches(path, private_key):
        if not path.exists() or not private_key.exists():
            return False
        public = stack.cmd(["openssl", "x509", "-in", path, "-pubkey", "-noout"], check=False)
        paired = stack.cmd(["openssl", "pkey", "-in", private_key, "-pubout"], check=False)
        return public.returncode == paired.returncode == 0 and public.stdout == paired.stdout

    # macOS LibreSSL has no verify -verify_hostname. Our generated certificates
    # use literal DNS SANs, so check those exact names and the cryptographic
    # chain separately rather than needlessly reissuing a valid leaf each up.
    def matches_hosts():
        parsed = stack.cmd(["openssl", "x509", "-in", cert, "-noout", "-text"], check=False)
        names = set()
        lines = parsed.stdout.splitlines()
        for index, line in enumerate(lines):
            if "X509v3 Subject Alternative Name:" not in line:
                continue
            indent = len(line) - len(line.lstrip())
            for child in lines[index + 1:]:
                if child.strip() and len(child) - len(child.lstrip()) <= indent:
                    break
                names.update(re.findall(r"DNS:([^,\s]+)", child))
        return parsed.returncode == 0 and set(hosts) <= names

    valid_leaf = (current(cert, "Authority Key Identifier", 86400) and matches(cert, key) and matches_hosts()
                  and stack.cmd(["openssl", "verify", "-x509_strict", "-CAfile", ca, cert], check=False).returncode == 0)
    if renew_ca or not valid_leaf:
        config = stack.state / "tls.cnf"
        san = ",".join("DNS:" + host for host in hosts)
        config.write_text("[req]\ndistinguished_name=dn\nreq_extensions=req_ext\nprompt=no\n[dn]\n"
                          "CN=relay.kind.agentrelay.com\n[req_ext]\nsubjectAltName=" + san + "\n[ext]\n"
                          "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                          "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n"
                          "subjectAltName=" + san + "\n")
        csr = stack.state / "tls.csr"
        stack.cmd(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", config, "-keyout", key, "-out", csr])
        stack.cmd(["openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial",
                   "-days", "30", "-extfile", config, "-extensions", "ext", "-out", cert])
        key.chmod(0o600)
    stack.cmd(["openssl", "verify", "-x509_strict", "-CAfile", ca, cert])
    # Save newly created CAs too, before a later corrupt/expired working copy
    # could lose the bytes of a certificate that has been trusted.
    archive_ca()
    stack.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "kind-tls", "namespace": namespace},
                 "type": "kubernetes.io/tls", "stringData": {"tls.crt": cert.read_text(), "tls.key": key.read_text()}})
    (stack.state / "hosts").write_text("127.0.0.1 " + " ".join(hosts) + "\n")
