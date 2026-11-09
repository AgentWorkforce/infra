import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import archive_source
class Archive(unittest.TestCase):
    def setUp(self):
        base=Path('/Volumes/T7/Projects/AgentWorkforce/.cache')
        self.temp=tempfile.TemporaryDirectory(dir=base if base.exists() else None);self.base=Path(self.temp.name);self.root=self.base/'source';self.root.mkdir()
        (self.root/'public.txt').write_bytes(b'public-fixture')
        self.manifest={'format':'actual-rds-source-archive-v1','composition_commit':'0'*40,'composition_tree':'1'*40,'bun_lock_sha256':'2'*64,'packages':{},'files':{'public.txt':hashlib.sha256(b'public-fixture').hexdigest()}}
        (self.root/'archive-manifest.json').write_text(json.dumps(self.manifest))
    def tearDown(self):self.temp.cleanup()
    def test_identical_bytes_and_fresh_output_required(self):
        a=archive_source.build(self.root,self.base/'a.tar.gz');b=archive_source.build(self.root,self.base/'b.tar.gz')
        self.assertEqual(a,b)
        with self.assertRaises(RuntimeError):archive_source.build(self.root,self.base/'a.tar.gz')
    def test_modified_extra_and_symlink_files_refused(self):
        path=self.root/'public.txt';path.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError,'bytes_changed'):archive_source.build(self.root,self.base/'changed.tar.gz')
        path.write_bytes(b'public-fixture');extra=self.root/'extra';extra.write_bytes(b'public')
        with self.assertRaisesRegex(RuntimeError,'inventory_bound'):archive_source.build(self.root,self.base/'extra.tar.gz')
        extra.unlink();extra.symlink_to(path)
        with self.assertRaisesRegex(RuntimeError,'symlink_refused'):archive_source.build(self.root,self.base/'link.tar.gz')
if __name__=='__main__':unittest.main()
