#!/usr/bin/env python3
"""One privileged local step: Kind DNS and this checkout's development CA."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import ssl
import subprocess

ROOT = Path(__file__).resolve().parents[3]
CA = ROOT / ".kind/local/ca.crt"
HOSTS = {name + ".kind.agentrelay.com" for name in ("relay", "cast", "history", "files")}
KEYCHAIN = "/Library/Keychains/System.keychain"


def certificate_present(ca):
    """Match the exact stored CA, independently of leaf validity or trust."""
    result = subprocess.run(["security", "find-certificate", "-a", "-p", KEYCHAIN], check=True, capture_output=True, text=True)
    wanted = ssl.PEM_cert_to_DER_cert(ca.read_text())
    return any(ssl.PEM_cert_to_DER_cert(pem) == wanted for pem in re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", result.stdout, re.DOTALL))


def host_aliases_present():
    return bool(set(Path("/etc/hosts").read_text().split()) & HOSTS)


def remove_ca(ca, sha1):
    result = subprocess.run(["security", "remove-trusted-cert", "-d", str(ca)], capture_output=True, text=True)
    if result.returncode and "The specified item could not be found in the keychain" not in result.stderr:
        raise RuntimeError("could not remove local CA trust; local state is preserved for retry: " + result.stderr.strip())
    if certificate_present(ca):
        subprocess.run(["security", "delete-certificate", "-Z", sha1, KEYCHAIN], check=True)
    if certificate_present(ca):
        raise RuntimeError("local CA remains in System keychain; local state is preserved for retry")


def host_contents(original, enabled):
    lines = []
    for line in original.splitlines():
        value, sep, comment = line.partition("#")
        parts = value.split()
        if len(parts) > 1 and HOSTS.intersection(parts[1:]):
            other = [p for p in parts[1:] if p not in HOSTS]
            if other:
                lines.append(parts[0] + " " + " ".join(other) + (" #" + comment if sep else ""))
        else:
            lines.append(line)
    if enabled:
        lines.append("127.0.0.1 " + " ".join(sorted(HOSTS)) + " # Agent Relay local development")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("up", "down"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this trust helper supports macOS")
    if os.geteuid() != 0:
        parser.error("run make local-trust once from an interactive terminal; macOS requires sudo for /etc/hosts and CA trust")
    if not CA.is_file():
        parser.error("this checkout has no local CA; run make local-up first")
    der = ssl.PEM_cert_to_DER_cert(CA.read_text())
    sha1 = hashlib.sha1(der).hexdigest().upper()
    if args.action == "up":
        subprocess.run(["security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", KEYCHAIN, str(CA)], check=True)
    else:
        remove_ca(CA, sha1)
    hosts = Path("/etc/hosts")
    wanted = host_contents(hosts.read_text(), args.action == "up")
    # Preserve hosts inode, ownership and mode rather than replacing the file.
    with hosts.open("r+") as handle:
        handle.write(wanted)
        handle.truncate()
    subprocess.run(["dscacheutil", "-flushcache"], check=True)
    print("Local DNS and CA " + ("installed" if args.action == "up" else "removed") + "; CA SHA-256 " + hashlib.sha256(der).hexdigest())


if __name__ == "__main__":
    main()
