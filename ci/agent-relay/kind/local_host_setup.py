#!/usr/bin/env python3
"""One privileged local step: Kind DNS and this checkout's development CA."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import ssl
import subprocess

ROOT = Path(__file__).resolve().parents[3]
CA = ROOT / ".kind/local/ca.crt"
HOSTS = {name + ".kind.agentrelay.com" for name in ("relay", "cast", "history", "files")}
KEYCHAIN = "/Library/Keychains/System.keychain"


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
        subprocess.run(["security", "remove-trusted-cert", "-d", str(CA)], check=False)
        subprocess.run(["security", "delete-certificate", "-Z", sha1, KEYCHAIN], check=False)
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
