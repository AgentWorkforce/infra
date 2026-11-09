#!/usr/bin/python3
"""Pinned MinIO 5.4.0 same-release naming transform; preserve PVC/DNS/selectors."""
import re
import sys

source = sys.stdin.read()
parts = re.split(r'(?m)^---[ \t]*\n', source)
deployments = [i for i,p in enumerate(parts) if re.search(r'(?m)^kind: Deployment$', p)]
claims = [p for p in parts if re.search(r'(?m)^kind: PersistentVolumeClaim$', p)]
if len(deployments) != 1 or len(claims) != 1:
    raise SystemExit('refusing storage naming: expected exactly one standalone Deployment and one rendered PVC')
claim = claims[0]
if len(re.findall(r'(?m)^  name: locker$', claim)) != 1:
    raise SystemExit('refusing storage naming: PVC identity is not locker')
i = deployments[0]
p = parts[i]
if len(re.findall(r'(?m)^  name: locker$', p)) != 1 or len(re.findall(r'(?m)^      name: locker$', p)) != 1:
    raise SystemExit('refusing storage naming: Deployment or template identity changed')
if len(re.findall(r'(?m)^ +claimName: locker$', p)) != 1:
    raise SystemExit('refusing storage naming: Deployment does not mount the original claim')
if 'release: kind-locker' not in p or not re.search(r'(?m)^      app: minio$', p):
    raise SystemExit('refusing storage naming: original same-release selector changed')
p = re.sub(r'(?m)^  name: locker$', '  name: session-object-storage', p)
p = re.sub(r'(?m)^      name: locker$', '      name: session-object-storage', p)
parts[i] = p
sys.stdout.write('---\n'.join(parts))
