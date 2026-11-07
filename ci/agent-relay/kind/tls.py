"""Host-only CA key and strict-verifier-compatible local server certificate."""


def create(stack, hosts, namespace):
    ca, ca_key = stack.state / "ca.crt", stack.state / "ca.key"
    cert, key = stack.state / "tls.crt", stack.state / "tls.key"

    def current(path, extension, seconds):
        if not path.exists():
            return False
        text = stack.cmd(["openssl", "x509", "-in", path, "-noout", "-text"]).stdout
        return extension in text and stack.cmd(
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
    if renew_ca or not current(cert, "Authority Key Identifier", 86400):
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
