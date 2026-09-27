"""Native disposable process controls; no device or service mutations."""
import os
from pathlib import Path
import runpy
import signal
import subprocess
import tempfile
import time
import unittest

MODULE=runpy.run_path(str(Path(__file__).resolve().parents[2]/'tests/e2e/package-runtime/bootstrap.py'))


class AgentCommandTests(unittest.TestCase):
    def command(self,script,seconds=2):
        return MODULE['agent_command'](['/usr/bin/python3','-I','-S','-B','-c',script],time.monotonic()+seconds)

    def assert_gone(self,pid):
        self.assertFalse(Path('/proc/'+str(pid)).exists(),'owned descendant must be reaped, not merely signalled')

    def cleanup_marker(self,marker):
        if marker.exists():
            pid=int(marker.read_text())
            if Path('/proc/'+str(pid)).exists():
                os.kill(pid,signal.SIGKILL)
                os.waitpid(pid,0)

    def test_success(self):
        self.assertEqual(self.command("print('observed')"),'observed\n')

    def test_nonzero_preserves_status_and_empty_cleanup(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:self.command("print('plausible');raise SystemExit(7)")
        self.assertEqual(caught.exception.returncode,7)
        self.assertTrue(caught.exception.agentCommandFacts['empty'])

    def test_closed_stream_survivor_and_escaped_group_are_reaped(self):
        for escaped in (False,True):
            with self.subTest(escaped=escaped),tempfile.TemporaryDirectory() as directory:
                marker=Path(directory)/'pid'
                script="import os,time\npid=os.fork()\nif pid==0:\n " + ("os.setsid()\n " if escaped else '') + "os.close(1);os.close(2)\n open("+repr(str(marker))+",'w').write(str(os.getpid()))\n time.sleep(30)\nelse:\n while not os.path.exists("+repr(str(marker))+"):time.sleep(.001)\n print('parent complete')\n"
                try:
                    self.assertEqual(self.command(script),'parent complete\n')
                    self.assert_gone(int(marker.read_text()))
                finally:self.cleanup_marker(marker)

    def test_timeout_and_overflow_reap_closed_stream_children(self):
        for suffix,error in (("time.sleep(30)",TimeoutError),("os.write(1,b'x'*20000);time.sleep(30)",ValueError)):
            with self.subTest(suffix=suffix),tempfile.TemporaryDirectory() as directory:
                marker=Path(directory)/'pid'
                script="import os,time\npid=os.fork()\nif pid==0:\n os.setsid();os.close(1);os.close(2)\n open("+repr(str(marker))+",'w').write(str(os.getpid()))\n time.sleep(30)\nelse:\n while not os.path.exists("+repr(str(marker))+"):time.sleep(.001)\n "+suffix+"\n"
                started=time.monotonic()
                with self.assertRaises(error) as caught:self.command(script,.3)
                self.assertLess(time.monotonic()-started,2.5)
                self.assertTrue(caught.exception.agentCommandFacts['empty'])
                self.assert_gone(int(marker.read_text()))

    def test_existing_child_refuses_before_command(self):
        child=subprocess.Popen(['/usr/bin/sleep','3'])
        try:
            with self.assertRaisesRegex(ValueError,'child-free'):self.command("print('must not execute')")
        finally:child.kill();child.wait()


if __name__=='__main__':unittest.main()
