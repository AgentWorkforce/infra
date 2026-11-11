"""Local SSH Ed25519 signatures over canonical JSON, with explicit trust on verify."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

NAMESPACE = "agent-relay-local-acceptance-v1"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def private_json(path):
    """Do not follow a credential-file symlink or accept a shared credential file."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("private_file_required")
        raw = stream.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError("input_too_large")
    return json.loads(raw)


def command(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=30)
    if result.returncode:
        # Never copy a subprocess's stderr or request data into a public receipt.
        raise ValueError("signature_command_failed")
    return result.stdout


def public_key(text):
    fields = text.split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        raise ValueError("ed25519_key_required")
    base64.b64decode(fields[1], validate=True)
    return " ".join(fields[:2])


def fingerprint(key):
    digest = hashlib.sha256(base64.b64decode(key.split()[1])).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def signing_key(path):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists() and not path.is_symlink():
        command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "local-acceptance", "-f", str(path)])
    # Check metadata without reading or reporting the private key's contents.
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("private_signing_key_required")
    return public_key(command(["ssh-keygen", "-y", "-f", str(path)]).decode())


def write_signed(path, payload, key_path):
    key = signing_key(key_path)
    signature = command(["ssh-keygen", "-Y", "sign", "-f", str(key_path), "-n", NAMESPACE], canonical(payload))
    envelope = {"payload": payload, "signature": {"format": "sshsig", "namespace": NAMESPACE,
        "publicKey": key, "keyId": fingerprint(key), "value": signature.decode()}}
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError("output_symlink_refused")
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(json.dumps(envelope, indent=2, allow_nan=False).encode() + b"\n")
            stream.flush()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return envelope


def verify(path, trusted_key_path):
    envelope = json.loads(Path(path).read_text())
    if set(envelope) != {"payload", "signature"}:
        raise ValueError("signature_envelope_invalid")
    key = public_key(Path(trusted_key_path).read_text())
    signature = envelope["signature"]
    if set(signature) != {"publicKey", "keyId", "namespace", "format", "value"}:
        raise ValueError("signature_envelope_invalid")
    if (signature["publicKey"] != key or signature["keyId"] != fingerprint(key)
            or signature["namespace"] != NAMESPACE or signature["format"] != "sshsig"):
        raise ValueError("signature_trust_mismatch")
    with tempfile.TemporaryDirectory() as directory:
        allowed = Path(directory) / "allowed"
        signed = Path(directory) / "signature"
        allowed.write_text("local-acceptance " + key + "\n")
        signed.write_text(signature["value"])
        command(["ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", "local-acceptance",
                 "-n", NAMESPACE, "-s", str(signed)], canonical(envelope["payload"]))
    return envelope["payload"]
