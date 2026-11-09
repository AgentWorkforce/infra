import os
import sys
import unittest
from secret_io import run,SecretIoError
class SensitiveIo(unittest.TestCase):
    def test_private_input_has_no_result_repr_or_error_repr(self):
        canary=b'synthetic-not-real-credential'
        result=run([sys.executable,'-c','import sys;v=sys.stdin.buffer.read();sys.stdout.buffer.write(v);sys.stderr.buffer.write(v)'],input_bytes=canary,env={},timeout=5)
        self.assertEqual(result.stdout,canary);self.assertEqual(result.stderr,canary)
        self.assertNotIn(canary.decode(),repr(result))
    def test_output_bound_and_timeout_are_typed(self):
        for code,expected in [('import sys;sys.stdout.write("x"*10000)','sensitive_output_bound'),('import time;time.sleep(30)','sensitive_timeout')]:
            with self.subTest(expected=expected),self.assertRaises(SecretIoError) as error:
                run([sys.executable,'-c',code],env={},timeout=.2,max_output=256)
            self.assertEqual(error.exception.code,expected)
            self.assertNotIn('sys.',str(error.exception))
    def test_closed_stdin_without_consumption_and_nonzero_exit(self):
        result=run([sys.executable,'-c','raise SystemExit(3)'],input_bytes=b'canary',env={},timeout=5)
        self.assertEqual(result.returncode,3)
    def test_timeout_reaps_owned_grandchild(self):
        code='import subprocess,sys,time;subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);time.sleep(30)'
        with self.assertRaises(SecretIoError) as error:run([sys.executable,'-c',code],env={},timeout=.3)
        self.assertEqual(error.exception.code,'sensitive_timeout')
    def test_closed_interactive_frames_keep_secret_replies_off_stdout(self):
        seen=[]
        def frame(line):
            seen.append(line)
            return b'synthetic-canary\n' if len(seen)==1 else b''
        code='import sys;sys.stdin.readline();print("rotate",flush=True);assert sys.stdin.readline().strip()=="synthetic-canary";print("done",flush=True)'
        r=run([sys.executable,'-c',code],input_bytes=b'initial\n',on_frame=frame,env={},timeout=5)
        self.assertEqual(r.returncode,0);self.assertEqual(r.stdout,b'');self.assertEqual(seen,[b'rotate',b'done'])
    def test_unterminated_or_oversized_frame_reply_fails_closed(self):
        with self.assertRaisesRegex(SecretIoError,'unterminated'):run([sys.executable,'-c','import sys;sys.stdout.write("partial")'],on_frame=lambda _:None,env={},timeout=5)
        with self.assertRaisesRegex(SecretIoError,'input_bound'):run([sys.executable,'-c','print("request",flush=True);input()'],on_frame=lambda _:b'x'*1000,env={},timeout=5,max_input=256)
if __name__=='__main__':unittest.main()
