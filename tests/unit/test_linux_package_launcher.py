"""Real local process controls only; no QEMU or guest is launched."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/launch.py'))


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.folder=Path(self.temp.name)
        self.command=['/usr/bin/python3','-c','import time;time.sleep(10)']

    def test_no_progress_deadline_stops_and_reaps_actual_owned_process(self):
        began=time.monotonic()
        with self.assertRaises(TimeoutError):MODULE['run_owned'](self.command,self.folder,lambda *args:None,seconds=.05)
        self.assertLess(time.monotonic()-began,1)
        pid=json.loads((self.folder/'pid.json').read_text())['pid']
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_actual_success_observation_still_stops_owned_process(self):
        result=MODULE['run_owned'](self.command,self.folder,lambda *args:{'fixtureObservation':True},seconds=1)
        self.assertEqual(result,{'fixtureObservation':True})
        pid=json.loads((self.folder/'pid.json').read_text())['pid']
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_observer_failure_still_stops_owned_process(self):
        def fail(*args):raise ValueError('quota fixture failure')
        with self.assertRaisesRegex(ValueError,'quota fixture'):MODULE['run_owned'](self.command,self.folder,fail,seconds=1)
        pid=json.loads((self.folder/'pid.json').read_text())['pid']
        self.assertFalse(Path('/proc',str(pid)).exists())

    def test_wrong_process_identity_is_never_signalled(self):
        child=subprocess.Popen(self.command,start_new_session=True)
        try:
            identity=MODULE['process_identity'](child.pid);identity['startTime']='foreign'
            with self.assertRaisesRegex(ValueError,'identity changed'):MODULE['stop_owned'](child,identity)
            self.assertIsNone(child.poll())
        finally:
            child.terminate();child.wait(timeout=2)

    def test_foreign_process_survives_own_cancellation(self):
        foreign=subprocess.Popen(self.command,start_new_session=True)
        try:
            with self.assertRaises(TimeoutError):MODULE['run_owned'](self.command,self.folder,lambda *args:None,seconds=.05)
            self.assertIsNone(foreign.poll())
        finally:
            foreign.terminate();foreign.wait(timeout=2)

    def socket_child(self):
        path=self.folder/'qga.sock'
        child=subprocess.Popen(['/usr/bin/python3','-c',
            'import socket,sys,time;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen();time.sleep(10)',str(path)],start_new_session=True)
        deadline=time.monotonic()+2
        while not path.exists() and child.poll() is None and time.monotonic()<deadline:time.sleep(.01)
        self.assertTrue(path.exists())
        return child

    def test_actual_owned_socket_is_bound_to_child_descriptor(self):
        child=self.socket_child()
        try:MODULE['owned_qga_socket'](child,self.folder)
        finally:child.terminate();child.wait(timeout=2)

    def test_foreign_process_socket_is_not_owned_guest_authority(self):
        foreign=self.socket_child();child=subprocess.Popen(self.command,start_new_session=True)
        try:
            with self.assertRaisesRegex(ValueError,'exact owned guest'):MODULE['owned_qga_socket'](child,self.folder)
            self.assertIsNone(foreign.poll());self.assertIsNone(child.poll())
        finally:
            child.terminate();child.wait(timeout=2);foreign.terminate();foreign.wait(timeout=2)

    def test_command_has_only_owned_disks_no_network_or_shared_host_path(self):
        record={'scratchId':'a'*32,'vmUuid':'12345678-1234-1234-1234-123456789abc'}
        # No guest executable is needed for this declarative argument control.
        with patch.dict(MODULE['command'].__globals__,{'protected_qemu':lambda:'/usr/bin/qemu-system-x86_64'}):
            command=MODULE['command'](self.folder,record)
        self.assertEqual(command[command.index('-nic')+1],'none')
        self.assertNotIn('-netdev',command);self.assertNotIn('-virtfs',command);self.assertNotIn('-fsdev',command)
        self.assertEqual(sum(value.startswith('if=') for value in command),4)
        self.assertIn('virtio-blk-pci,drive=root,serial=WOOTC-PKG-'+record['scratchId'],command)


if __name__=='__main__':unittest.main()
