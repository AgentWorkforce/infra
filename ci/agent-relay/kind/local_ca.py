"""Opt-in retention of the local trust anchor across disposable data rebuilds."""
import hashlib
import os
from pathlib import Path
import ssl
import stat
import sys

from local_host_setup import certificate_present, managed_cas
from stack import ROOT, StackError

FILES = ("ca.crt", "ca.key")


def enabled():
    value = os.environ.get("LOCAL_CA_REUSE", "0")
    if value not in ("", "0", "1"):
        raise StackError("LOCAL_CA_REUSE must be 0 or 1")
    return value == "1"


def fingerprint(cert):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()


def validate(stack, directory):
    cert, key = (directory / name for name in FILES)
    if directory.is_symlink() or any(p.is_symlink() or not p.is_file() for p in (cert, key)):
        raise StackError("retained CA requires a plain certificate/key pair; nothing was regenerated")
    if key.stat().st_uid != os.getuid() or stat.S_IMODE(key.stat().st_mode) & 0o077:
        raise StackError("retained CA key must be owned by this user and private (0600)")
    parsed = stack.cmd(["openssl", "x509", "-in", cert, "-noout", "-text"], sensitive=True)
    expiry = stack.cmd(["openssl", "x509", "-in", cert, "-checkend", str(31 * 86400), "-noout"], check=False, sensitive=True)
    public = stack.cmd(["openssl", "x509", "-in", cert, "-pubkey", "-noout"], sensitive=True).stdout
    paired = stack.cmd(["openssl", "pkey", "-in", key, "-pubout"], sensitive=True).stdout
    if "CA:TRUE" not in parsed.stdout or "Subject Key Identifier" not in parsed.stdout or expiry.returncode or public != paired:
        raise StackError("retained CA is expired, expiring or mismatched; trust was not rotated")
    stack.cmd(["openssl", "verify", "-x509_strict", "-CAfile", cert, cert], sensitive=True)
    if sys.platform == "darwin":
        if not certificate_present(cert):
            raise StackError("retained CA is not in the System keychain; use default local-up/local-trust instead")
        stack.cmd(["security", "verify-cert", "-c", cert, "-p", "basic"], sensitive=True)
    return fingerprint(cert)


def copy_pair(source, target):
    created = []
    try:
        for name in FILES:
            path = target / name
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            created.append(path)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write((source / name).read_bytes())
    except BaseException:
        for path in created:
            path.unlink()
        raise


def prepare(stack):
    """Import/export only a verified trust pair. Application state is never read."""
    if not enabled():
        return False
    raw = Path(os.environ.get("LOCAL_CA_REUSE_DIR", str(Path.home() / ".agentworkforce/kind-local-ca"))).expanduser()
    store = raw.resolve()
    if raw.is_symlink() or store == ROOT or ROOT in store.parents:
        raise StackError("retained CA directory must be a plain directory outside this checkout")
    if store.exists() and (not store.is_dir() or store.stat().st_uid != os.getuid() or stat.S_IMODE(store.stat().st_mode) & 0o077):
        raise StackError("retained CA directory must be owned by this user and private (0700)")
    if store.exists() and any(p.name not in FILES for p in store.iterdir()):
        raise StackError("retained CA directory must contain only the certificate/key pair")
    present = [(stack.state / name).exists() for name in FILES]
    if any(present) and not all(present):
        raise StackError("local CA pair is incomplete; retained trust was not replaced")
    if not any(present):
        validate(stack, store)
        copy_pair(store, stack.state)
    sha = validate(stack, stack.state)
    if any(fingerprint(cert) != sha for cert in managed_cas(stack.state / "ca.crt")):
        raise StackError("other saved CAs require ordinary trust cleanup before retained-CA rebuild")
    store.mkdir(mode=0o700, parents=True, exist_ok=True)
    saved = [(store / name).exists() for name in FILES]
    if any(saved):
        if not all(saved):
            raise StackError("retained CA store is incomplete; no trust identity was overwritten")
        validate(stack, store)
        if any((store / name).read_bytes() != (stack.state / name).read_bytes() for name in FILES):
            raise StackError("retained CA store differs; no trust identity was overwritten")
    else:
        copy_pair(stack.state, store)
    print("Retained local CA SHA-256 " + sha + "; existing hosts/trust preserved.")
    return True
