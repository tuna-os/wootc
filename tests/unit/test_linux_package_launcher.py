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

    def test_actual_checked_requires_live_namespace_before_source_or_qemu_reads(self):
        record={'stage':str(self.folder),'runtimeExecuted':False,'hostDataPrefix':'/run/fixture'}
        (self.folder/'ownership.json').write_text(json.dumps(record))
        calls=[]
        def bound(prefix):
            calls.append(prefix);raise ValueError('actual namespace binding absent')
        original=runpy.run_path
        def module(path):
            if str(path).endswith('host-namespace.py'):return {'require_bound':bound,'checked':lambda *_:{}}
            return original(path)
        with patch.object(runpy,'run_path',module):
            with self.assertRaisesRegex(ValueError,'actual namespace binding absent'):
                MODULE['checked'](self.folder)
        self.assertEqual(calls,[Path('/run/fixture')])
        self.assertFalse((self.folder/'pid.json').exists())

    def test_actual_owned_spawn_reports_start_after_identity_before_observation(self):
        events=[]
        def started(identity):
            self.assertEqual(identity,MODULE['process_identity'](identity['pid']))
            events.append('started')
        def observe(*args):
            self.assertEqual(events,['started']);return {'fixtureObservation':True}
        MODULE['run_owned'](self.command,self.folder,observe,seconds=1,on_started=started)
        self.assertEqual(events,['started'])

    def launch_fixture(self,changes):
        record={'actualVirtualBytes':1,'scratchId':'a'*32,'vmUuid':'12345678-1234-1234-1234-123456789abc'}
        (self.folder/'base.qcow2').write_bytes(b'fixture')
        boundaries={'checked':lambda path:(self.folder,record),'qualify':lambda path:{'freeBytes':2**40}}
        boundaries.update(changes)
        with patch.dict(MODULE['launch'].__globals__,boundaries):
            with self.assertRaises((ValueError,FileNotFoundError)):
                MODULE['launch'](self.folder,None,None)
        persisted=json.loads((self.folder/'ownership.json').read_text())
        self.assertTrue(persisted['executionRequested'])
        for field in ('runtimeExecuted','processStarted','guestBaselineObserved'):
            self.assertFalse(persisted[field])
        self.assertFalse((self.folder/'pid.json').exists())

    def test_actual_launcher_qualification_failure_keeps_process_unstarted(self):
        def fail(*args):raise ValueError('qualified host absent')
        self.launch_fixture({'qualify':fail})

    def test_actual_launcher_protected_tool_failure_keeps_process_unstarted(self):
        def fail():raise ValueError('protected QEMU source absent')
        self.launch_fixture({'protected_qemu':fail})

    def test_actual_popen_missing_executable_keeps_process_unstarted(self):
        self.launch_fixture({'command':lambda *args:[str(self.folder/'missing-executable')]})

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
        record={'scratchId':'a'*32,'vmUuid':'12345678-1234-1234-1234-123456789abc',
                'qemuDataPath':'/run/wootc-package-host-1-1/usr/share/qemu'}
        # No guest executable is needed for this declarative argument control.
        with patch.dict(MODULE['command'].__globals__,{'protected_qemu':lambda:'/usr/bin/qemu-system-x86_64'}):
            command=MODULE['command'](self.folder,record)
        self.assertEqual(command[command.index('-nic')+1],'none')
        self.assertEqual(command[command.index('-L')+1],record['qemuDataPath'])
        self.assertNotIn('-netdev',command);self.assertNotIn('-virtfs',command);self.assertNotIn('-fsdev',command)
        self.assertEqual(sum(value.startswith('if=') for value in command),4)
        self.assertIn('virtio-blk-pci,drive=root,serial=WOOTC-PKG-'+record['scratchId'],command)


if __name__=='__main__':unittest.main()
