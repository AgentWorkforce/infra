#!/usr/bin/env python3
"""Opt-in transport proof: exact Control source against the pinned MinIO image.

Requires an already-running local Docker daemon (<=4 GiB), gh and Bun. Does not
start/resize a VM or contact ar-lap. Uses only a temporary test container and
synthetic credentials; cleans that container even on failure. Run via aw-heavy.
This does not qualify a published Control/Desktop build or SQL admission.
"""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.request

import yaml

ROOT = Path(__file__).resolve().parents[2]
CONTROL_REF = '473ce224ab9da42a67d2970a269e969109e64ae7'


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def main():
    host = os.environ.get('DOCKER_HOST') or run(['docker', 'context', 'inspect', run(['docker', 'context', 'show']), '--format', '{{.Endpoints.docker.Host}}'])
    if not host.startswith('unix://'):
        raise RuntimeError('requires a local Docker Unix socket; remote contexts are refused')
    scratch = ROOT / '.kind' / 'minio-proof'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        tmp = Path(tmp)
        config = tmp / 'docker'; config.mkdir()
        (config / 'config.json').write_text('{"auths":{}}\n')
        env = {**os.environ, 'DOCKER_HOST':host, 'DOCKER_CONFIG':str(config)}
        memory = int(run(['docker','info','--format','{{.MemTotal}}'],env=env))
        if memory > 4 * 1024**3:
            raise RuntimeError('reuse the existing <=4 GiB test daemon; this probe does not resize VMs')
        image = yaml.safe_load((ROOT/'charts/sessions-pipeline/values.yaml').read_text())['session-object-storage']['image']
        image = image['repository'] + '@' + image['tag'].split('@',1)[1]
        run(['docker','image','inspect',image],env=env) # caller pulls the pinned image separately
        for path in ['src/aws/sigv4.ts','src/aws/sts.ts','src/history-upload/credentials.ts']:
            item = json.loads(run(['gh','api',f'repos/AgentWorkforce/relay-control/contents/{path}?ref={CONTROL_REF}']))
            dest = tmp/path; dest.parent.mkdir(parents=True,exist_ok=True)
            dest.write_bytes(base64.b64decode(item['content']))
        fixture = {'MINIO_ROOT_USER':'proof-'+secrets.token_hex(8), 'MINIO_ROOT_PASSWORD':secrets.token_hex(32)}
        envfile = tmp/'server.env'; envfile.write_text(''.join(k+'='+v+'\n' for k,v in fixture.items())); envfile.chmod(0o600)
        cid = None
        try:
            cid = run(['docker','run','--detach','--pull=never','--memory=256m','--cpus=1','--env-file',str(envfile),
                       '--tmpfs','/data:rw,size=64m,mode=0777','--publish','127.0.0.1::9000',image,
                       'server','/data','--address',':9000','--console-address',':9001'],env=env)
            endpoint = 'http://' + run(['docker','port',cid,'9000/tcp'],env=env)
            deadline=time.monotonic()+30
            while True:
                try:
                    with urllib.request.urlopen(endpoint+'/minio/health/live',timeout=1) as response:
                        if response.status==200: break
                except OSError:
                    pass
                if time.monotonic()>=deadline: raise RuntimeError('temporary MinIO did not become ready')
                time.sleep(0.5)
            process = subprocess.run(['bun',str(ROOT/'ci/history-upload/probe_minio.ts'),str(tmp),
                                      str(ROOT/'ci/history-upload/relay-upload-inbox-v1.vectors.json')],
                                     env={**env,**fixture,'PROOF_ENDPOINT':endpoint,'PROOF_WITNESS_HEX':secrets.token_hex(32)},
                                     capture_output=True,text=True)
            if process.returncode:
                # The runner emits only its stage, never an exception/URL.
                safe = next((line for line in process.stderr.splitlines() if line.startswith('MinIO proof failed at ')), 'MinIO proof runner failed')
                raise RuntimeError(safe)
            result = process.stdout.strip()
            receipt=json.loads(result)
            receipt.update(controlSource=CONTROL_REF,minioImage=image,scope='transport-only; no published-runtime or SQL qualification')
            print(json.dumps(receipt,indent=2))
        finally:
            if cid: run(['docker','rm','--force',cid],env=env)


if __name__=='__main__':
    main()
