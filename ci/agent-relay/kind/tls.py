"""Host-only CA key and strict-verifier-compatible local server certificate."""
import re


def create(stack, hosts, namespace):
    ca, ca_key = stack.state / "ca.crt", stack.state / "ca.key"
    cert, key = stack.state / "tls.crt", stack.state / "tls.key"

    def current(path, extension, seconds):
        if not path.exists():
            return False
        parsed = stack.cmd(["openssl", "x509", "-in", path, "-noout", "-text"], check=False)
        return parsed.returncode == 0 and extension in parsed.stdout and stack.cmd(
            ["openssl", "x509", "-in", path, "-checkend", str(seconds), "-noout"], check=False).returncode == 0

    renew_ca = not current(ca, "Subject Key Identifier", 31 * 86400)
    if renew_ca:
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
    stack.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "kind-tls", "namespace": namespace},
                 "type": "kubernetes.io/tls", "stringData": {"tls.crt": cert.read_text(), "tls.key": key.read_text()}})
    (stack.state / "hosts").write_text("127.0.0.1 " + " ".join(hosts) + "\n")
