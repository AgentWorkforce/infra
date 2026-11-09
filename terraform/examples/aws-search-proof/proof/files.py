"""Private evidence writes; no process/provider/network access."""
import json
import os
from pathlib import Path
from contract import digest

def save(path, value):
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w') as f:
        os.chmod(tmp, 0o600); f.write(json.dumps(value, indent=2) + '\n'); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)

def sha(path): return digest(Path(path).read_bytes())
def read(path): return json.loads(Path(path).read_text())
