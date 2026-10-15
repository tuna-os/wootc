"""Actual Unix socket QGA controls; guest replies are fixtures, not OS proof."""
import base64
import json
from pathlib import Path
import runpy
import socket
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[2]


class QgaTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name);self.path=self.folder/'qga.sock'
        (self.folder/'qga-client.py').write_bytes((ROOT/'tests/e2e/qga.py').read_bytes())
        (self.folder/'qga-readback.py').write_bytes((ROOT/'tests/e2e/package-runtime/qga-readback.py').read_bytes())
        self.module=runpy.run_path(str(self.folder/'qga-readback.py'))
        self.server=socket.socket(socket.AF_UNIX);self.server.bind(str(self.path));self.server.listen(1)
        self.requests=[];self.errors=[];self.release=threading.Event();self.thread=None
        self.output=json.dumps({'fixtureGuestReply':True}).encode();self.status=0;self.stall=False

    def tearDown(self):
        self.release.set();self.server.close()
        if self.thread is not None:
            self.thread.join(timeout=1)
            self.assertFalse(self.thread.is_alive(),'owned socket thread remains alive')
        self.assertEqual(self.errors,[],'unexpected socket thread exception')

    def serve(self):
        try:
            connection,_=self.server.accept()
            with connection,connection.makefile('rwb') as stream:
                for raw in stream:
                    request=json.loads(raw.lstrip(b'\xff'));self.requests.append(request)
                    name=request['execute']
                    if name=='guest-sync-delimited':
                        stream.write(b'\xff'+json.dumps({'return':request['arguments']['id']}).encode()+b'\n')
                    elif name=='guest-exec':
                        stream.write(b'{"return":{"pid":7}}\n')
                    elif name=='guest-exec-status':
                        if self.stall:self.release.wait(1);return
                        response={'return':{'exited':True,'exitcode':self.status,
                                            'out-data':base64.b64encode(self.output).decode()}}
                        stream.write(json.dumps(response).encode()+b'\n')
                    else:raise AssertionError('unexpected QGA request')
                    stream.flush()
        except (BrokenPipeError,ConnectionResetError):
            # The deliberate deadline control closes its owned connection.
            if not self.stall:self.errors.append('unexpected client disconnect')
        except Exception as error:self.errors.append(repr(error))

    def execute(self,seconds=1):
        self.thread=threading.Thread(target=self.serve);self.thread.start()
        return self.module['read'](self.path,'b'*64,seconds)

    def test_actual_socket_executes_exact_readonly_guest_probe(self):
        self.assertEqual(self.execute(),{'fixtureGuestReply':True})
        request=next(value for value in self.requests if value['execute']=='guest-exec')
        self.assertEqual(request['arguments']['path'],'/usr/bin/python3')
        self.assertIn('b'*64,request['arguments']['arg'])
        self.assertIn('/run/wootc-package-seed/readback.py',request['arguments']['arg'])

    def test_failed_guest_status_with_plausible_stdout_refuses(self):
        self.status=1
        with self.assertRaisesRegex(ValueError,'exit status failed'):self.execute()

    def test_boolean_guest_status_is_not_success(self):
        self.status=False
        with self.assertRaisesRegex(ValueError,'exit status failed'):self.execute()

    def test_malformed_successful_stdout_refuses(self):
        self.output=b'{"truncated":'
        with self.assertRaises(ValueError):self.execute()

    def test_actual_socket_no_progress_is_bounded(self):
        self.stall=True
        with self.assertRaises((TimeoutError,OSError,RuntimeError)):self.execute(.05)


if __name__=='__main__':unittest.main()
