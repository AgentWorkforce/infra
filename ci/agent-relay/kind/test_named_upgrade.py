"""Retired legacy naming reconciliation and the storage-name postrenderer.

kind-reconcile-names only prepared an old single-phase fixture for a later
make kind-up, which ran the removed standalone RelayHistory server. It now
refuses before any state access. The storage-name postrenderer remains part of
the native bootstrap (native_bootstrap.py) and is still exercised here.
"""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import stack


class RetiredReconcile(unittest.TestCase):
    def test_reconcile_names_refuses_before_any_state_or_cluster_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); stderr = io.StringIO()
            with patch.object(stack, "ROOT", root), patch.object(stack, "run", side_effect=AssertionError("command ran")), \
                    patch("sys.argv", ["stack.py", "reconcile-names", "--profile", "core"]), contextlib.redirect_stderr(stderr):
                self.assertEqual(stack.main(), 1)
            self.assertIn("retired with the standalone RelayHistory server", stderr.getvalue())
            self.assertEqual(list(root.iterdir()), [])


class StorageRenderer(unittest.TestCase):
    def test_pinned_minio_chart_retains_the_claim_and_only_renames_the_deployment(self):
        root=HERE.parents[2]
        rendered=subprocess.run(['helm','template','kind-locker','charts/sessions-pipeline/charts/minio-5.4.0.tgz',
            '-n','agent-relay','--set','mode=standalone','--set','fullnameOverride=locker',
            '--set','existingSecret=kind-pipeline','--set','persistence.enabled=true'],cwd=root,
            text=True,capture_output=True,check=True).stdout
        renderer=HERE/'storage-name-renderer/postrender.py'
        result=subprocess.run([sys.executable,str(renderer)],input=rendered,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        before={(d['kind'],d['metadata']['name']):d for d in yaml.safe_load_all(rendered) if d}
        after={(d['kind'],d['metadata']['name']):d for d in yaml.safe_load_all(result.stdout) if d}
        changed=after.pop(('Deployment','session-object-storage'))
        changed['metadata']['name']='locker';changed['spec']['template']['metadata']['name']='locker'
        after[('Deployment','locker')]=changed
        self.assertEqual(before,after)
        self.assertIn(('PersistentVolumeClaim','locker'),after)
        for text in (rendered.replace('claimName: locker','claimName: empty-new-claim'),
                     rendered.replace('release: kind-locker','release: foreign-release'),
                     rendered.replace('kind: PersistentVolumeClaim','kind: UnexpectedResource')):
            refused=subprocess.run([sys.executable,str(renderer)],input=text,text=True,capture_output=True)
            self.assertNotEqual(refused.returncode,0)
            self.assertEqual(refused.stdout,'','refusal must emit no partially rewritten resources')


if __name__=='__main__':unittest.main()
