"""Bounded memory-only child IO. Never logs arguments, input, output or foreign errors.

This is transport, not approval authority or an isolation boundary. Callers must
provide trusted argument arrays, exact operation scope and a durable pending
record before mutation. No disk logger or credential discovery is used here.
"""
import os
import selectors
import signal
import subprocess
import time

class SecretIoError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)

class Result:
    def __init__(self, returncode, stdout, stderr):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr
    def __repr__(self): return '<SensitiveResult: contents omitted>'

def run(args, *, input_bytes=b'', env, timeout=90, max_output=65536, max_input=131072, on_frame=None):
    if not isinstance(input_bytes, bytes) or len(input_bytes)>max_input or not 0<max_input<=8*1024*1024 or not 0<timeout<=1800 or not 0<max_output<=1048576:
        raise SecretIoError('sensitive_input_bound')
    process=None;selector=selectors.DefaultSelector();buffers={'stdout':bytearray(),'stderr':bytearray()};offset=0
    pending=input_bytes;line_buffer=bytearray();stdout_count=0
    def settle():
        if process is None:return True
        for sig in [signal.SIGTERM,signal.SIGKILL]:
            process.poll()
            try:os.killpg(process.pid,sig)
            except ProcessLookupError:return True
            except PermissionError:return False
            end=time.monotonic()+5
            while time.monotonic()<end:
                process.poll()
                try:os.killpg(process.pid,0)
                except ProcessLookupError:return True
                except PermissionError:pass # Never infer absence from a denied group query.
                time.sleep(.05)
        return False
    try:
        process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
        for name,stream in [('stdout',process.stdout),('stderr',process.stderr)]:
            os.set_blocking(stream.fileno(),False);selector.register(stream,selectors.EVENT_READ,name)
        os.set_blocking(process.stdin.fileno(),False)
        if input_bytes:selector.register(process.stdin,selectors.EVENT_WRITE,'stdin')
        elif on_frame is None:process.stdin.close()
        deadline=time.monotonic()+timeout
        while selector.get_map():
            remaining=deadline-time.monotonic()
            if remaining<=0:raise SecretIoError('sensitive_timeout')
            for key,_ in selector.select(min(.1,remaining)):
                if key.data=='stdin':
                    try:offset+=os.write(key.fd,pending[offset:offset+4096])
                    except BrokenPipeError:offset=len(pending)
                    if offset==len(pending):
                        selector.unregister(key.fileobj)
                        if on_frame is None:key.fileobj.close()
                else:
                    chunk=os.read(key.fd,4096)
                    if not chunk:selector.unregister(key.fileobj);key.fileobj.close();continue
                    if key.data=='stdout' and on_frame is not None:
                        stdout_count+=len(chunk)
                        if stdout_count>max_output:raise SecretIoError('sensitive_output_bound')
                        line_buffer.extend(chunk)
                        while b'\n' in line_buffer:
                            frame,_,tail=line_buffer.partition(b'\n');line_buffer=bytearray(tail)
                            response=on_frame(bytes(frame))
                            if response is not None:
                                if not isinstance(response,bytes) or len(response)>max_input:raise SecretIoError('sensitive_input_bound')
                                if offset<len(pending) or process.stdin.closed:raise SecretIoError('sensitive_protocol_order')
                                if response:
                                    pending=response;offset=0;selector.register(process.stdin,selectors.EVENT_WRITE,'stdin')
                                else:process.stdin.close()
                    else:
                        if len(buffers[key.data])+len(chunk)>max_output:raise SecretIoError('sensitive_output_bound')
                        buffers[key.data].extend(chunk)
        if line_buffer:raise SecretIoError('sensitive_protocol_unterminated')
        remaining=deadline-time.monotonic()
        if remaining<=0:raise SecretIoError('sensitive_timeout')
        try:process.wait(timeout=remaining)
        except subprocess.TimeoutExpired:raise SecretIoError('sensitive_timeout') from None
        if not settle():raise SecretIoError('sensitive_process_unsettled')
        return Result(process.returncode,bytes(buffers['stdout']),bytes(buffers['stderr']))
    except BaseException as error:
        settled=settle()
        if not settled:raise SecretIoError('sensitive_process_unsettled') from None
        if isinstance(error,(KeyboardInterrupt,SystemExit,SecretIoError)):raise
        raise SecretIoError('sensitive_process_failed') from None
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                # Reap our still-unreaped immediate child even if group inspection
                # was denied. Its descendants remain explicitly unsettled.
                try:process.kill();process.wait(timeout=1)
                except (ProcessLookupError,PermissionError,subprocess.TimeoutExpired):pass
            for stream in [process.stdin,process.stdout,process.stderr]:
                if not stream.closed:stream.close()
