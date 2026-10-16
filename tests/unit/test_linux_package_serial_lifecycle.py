"""Native private PTYs only; no package installation or guest serial mutation."""
import errno
import json
import os
from pathlib import Path
import pty
import runpy
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/bootstrap.py'))


class SerialLifecycleTests(unittest.TestCase):
    def test_native_hangup_invalidates_retained_descriptor_fresh_publication_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            route=Path(directory)/'owned-serial'
            master,slave=pty.openpty();route.symlink_to(os.ttyname(slave))
            stale=os.open(route,os.O_WRONLY|os.O_NOCTTY)
            try:
                MODULE['serial_emit']({'stage':'baseline-observed'},route)
                self.assertIn(b'baseline-observed',os.read(master,4096))
                os.close(master);master=None
                with self.assertRaises(OSError) as refused:os.write(stale,b'old-installed\n')
                self.assertEqual(refused.exception.errno,errno.EIO)
                second,second_slave=pty.openpty()
                try:
                    route.unlink();route.symlink_to(os.ttyname(second_slave))
                    MODULE['serial_emit']({'stage':'old-installed'},route)
                    observed=os.read(second,4096).decode().strip()
                    self.assertEqual(json.loads(observed[len(MODULE['PREFIX']):]),{'stage':'old-installed'})
                    with self.assertRaises(OSError):os.write(stale,b'old-installed\n')
                finally:os.close(second);os.close(second_slave)
            finally:
                if master is not None:os.close(master)
                os.close(slave);os.close(stale)

    def test_current_hung_up_tty_refuses_without_retry(self):
        master,slave=pty.openpty();path=os.ttyname(slave);os.close(master)
        try:
            with self.assertRaises(OSError):MODULE['serial_emit']({'stage':'complete'},path)
        finally:os.close(slave)

    def test_actual_blocked_reader_bounds_writer(self):
        master,slave=pty.openpty();start=time.monotonic()
        try:
            with self.assertRaises(TimeoutError):
                MODULE['serial_emit']({'stage':'complete','padding':'x'*60000},os.ttyname(slave),.1)
            self.assertLess(time.monotonic()-start,1)
        finally:os.close(master);os.close(slave)

    def test_non_tty_and_oversize_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'regular';path.write_text('sentinel')
            with self.assertRaises(ValueError):MODULE['serial_emit']({'stage':'complete'},path)
            self.assertEqual(path.read_text(),'sentinel')
        with self.assertRaisesRegex(ValueError,'current TTY'):
            MODULE['serial_emit']({'stage':'complete'},'/dev/null')
        for seconds in (0,-1,True,4):
            with self.assertRaises(ValueError):MODULE['serial_emit']({},'/absent',seconds)
        with self.assertRaises(ValueError):MODULE['serial_emit']({'padding':'x'*65536},'/absent')
