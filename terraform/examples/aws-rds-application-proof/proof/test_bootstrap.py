import ast
import json
from pathlib import Path
import subprocess
import unittest

class Bootstrap(unittest.TestCase):
    def test_rendered_shell_and_embedded_python_parse_without_execution(self):
        root=Path(__file__).resolve().parents[1]
        extractor=(root/'proof/extract_payload.py').read_text()
        rendered=(root/'bootstrap.sh.tftpl').read_text().replace('${config}',json.dumps({'account_id':'111111111111','source_sha':'0'*40})).replace('${extractor}',extractor)
        result=subprocess.run(['/bin/bash','-n'],input=rendered,text=True,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
        for block in rendered.split("<<'PY'\n")[1:]:ast.parse(block.split('\nPY\n')[0])
        self.assertIn('[ "$result" -ne 75 ]',rendered)
        self.assertNotIn('set -x',rendered)
if __name__=='__main__':unittest.main()
