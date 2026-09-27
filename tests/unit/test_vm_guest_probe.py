#!/usr/bin/env python3
"""Fixed read-only producer controls; no guest install or desktop acceptance."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
probe = load('vm_guest_probe', ROOT/'payload/vm-observer/boot_probe.py')
ancestry = load('vm_guest_ancestry', ROOT/'tests/e2e/phase3_ancestry.py')
REQUEST = dict(schemaVersion=1, runId='run', installId='install',
               diskId='12345678-1234-1234-1234-123456789abc', sessionId='a'*32,
               requestId='b'*32, username='wootc', action='observe-boot-session')
SESSION = {'Id':'2', 'User':'1000', 'Name':'wootc', 'Active':'yes', 'Remote':'no',
           'Type':'wayland', 'Class':'user', 'State':'active', 'Leader':'99', 'LeaderStartTicks':'12345'}

class Probe(unittest.TestCase):
    def test_strict_request_no_execution_or_arbitrary_path(self):
        self.assertEqual(probe.request(json.dumps(REQUEST).encode()), REQUEST)
        for changes in [{'action':'exec'}, {'action':'write'}, {'path':'/etc/shadow'},
                        {'schemaVersion':True}, {'requestId':'short'}, {'username':'root'},
                        {'diskId':'cached-marker'}]:
            value=dict(REQUEST, **changes)
            if changes == {'username':'root'}:
                # Shape alone permits names; ordinary_session separately refuses
                # uid0. Do not pretend request validation proves session identity.
                self.assertEqual(probe.request(json.dumps(value).encode())['username'], 'root')
                continue
            with self.subTest(changes=changes), self.assertRaises(ValueError):probe.request(json.dumps(value).encode())
        with self.assertRaises(ValueError):probe.request(json.dumps(REQUEST).replace('"schemaVersion": 1', '"schemaVersion":1,"schemaVersion":1').encode())
        with self.assertRaises(ValueError):probe.request(b'x'*(probe.MAX_MESSAGE+1))
        with self.assertRaises(ValueError):probe.request(b'['*33+b'0'+b']'*33)
        with self.assertRaises(ValueError):probe.request(json.dumps(dict(REQUEST,schemaVersion=float('nan'))).encode())

    def test_failed_command_plausible_stdout_is_not_observation(self):
        for status in [1,124]:
            with self.assertRaises(ValueError):
                probe.run([sys.executable,'-c',f"import sys;print('Linux');sys.exit({status})"],time.monotonic()+1)
        with mock.patch.object(probe.subprocess, 'Popen') as run:
            with self.assertRaises(TimeoutError):probe.run(['uname'],time.monotonic()-1)
            run.assert_not_called()

    def test_actual_owned_child_output_overflow_and_stall_are_bounded(self):
        for stream in ('stdout','stderr'):
            with self.subTest(stream=stream), self.assertRaises(ValueError):
                probe.run([sys.executable,'-c',f"import sys,time;sys.{stream}.write('x'*300000);sys.{stream}.flush();time.sleep(20)"],time.monotonic()+2)
        began=time.monotonic()
        with self.assertRaises(TimeoutError):
            probe.run([sys.executable,'-c','import time;time.sleep(20)'],time.monotonic()+0.1)
        self.assertLess(time.monotonic()-began,1)

    def test_actual_local_linux_boot_read_is_canonical(self):
        self.assertRegex(probe.boot(), probe.UUID)

    def session(self, changes=None, duplicate=False, process_uid='1000'):
        row = dict(SESSION); row.pop('LeaderStartTicks'); row.update(changes or {})
        props = '\n'.join(key+'='+value for key,value in row.items())
        def command(argv, deadline):
            return '2 1000 wootc\n' if 'list-sessions' in argv else props + ('\nUser=1000' if duplicate else '')
        def read(path):
            return 'Uid:\t'+'\t'.join([process_uid]*4)+'\n' if str(path).endswith('/status') else '99 (ordinary session) '+' '.join(['S']+['0']*18+['12345'])
        with mock.patch.object(probe,'run',side_effect=command),mock.patch.object(Path,'read_text',read), \
             mock.patch('pwd.getpwnam',return_value=type('Account',(),{'pw_uid':1000})()):
            return probe.ordinary_session('wootc',time.monotonic()+1)

    def test_session_requires_actual_property_shape_uid_and_process_start(self):
        self.assertEqual(self.session()['LeaderStartTicks'],'12345')
        for changes in [{'User':'0'}, {'User':'1001'}, {'Type':'tty'}, {'Remote':'yes'}, {'State':'closing'}, {'Leader':'not-pid'}]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.session(changes)
        with self.assertRaises(ValueError):self.session(duplicate=True)
        with self.assertRaises(ValueError):self.session(process_uid='0')

    def observation(self, boots=None, sessions=None, root_error=None):
        with mock.patch.object(probe,'boot',side_effect=boots or [REQUEST['diskId']]*2), \
             mock.patch.object(probe,'ordinary_session',side_effect=sessions or [SESSION]*2), \
             mock.patch.object(probe,'backing',return_value={'currentRootVerified':True},side_effect=root_error):
            return probe.observe(REQUEST, ancestry.Ancestry)

    def test_same_boot_session_and_root_are_required_before_reply(self):
        observed=self.observation()
        self.assertEqual(observed['bootId'], REQUEST['diskId'])
        self.assertFalse(observed['desktopQualified']);self.assertFalse(observed['editorQualified'])
        for kw in [dict(boots=[REQUEST['diskId'],'00000000-0000-0000-0000-000000000000']),
                   dict(sessions=[SESSION,dict(SESSION,LeaderStartTicks='later')]),
                   dict(root_error=ValueError('root graph unknown'))]:
            with self.subTest(kw=kw),self.assertRaises(ValueError):self.observation(**kw)

    def test_no_reply_on_failed_observation_replay_or_bad_frame(self):
        raw=json.dumps(REQUEST).encode()+b'\n'
        with mock.patch.object(probe,'observe',side_effect=ValueError('unknown')):
            output=io.BytesIO()
            with self.assertRaises(ValueError):probe.serve(io.BytesIO(raw),output,ancestry.Ancestry)
            self.assertEqual(output.getvalue(),b'')
        with mock.patch.object(probe,'observe',return_value={'status':'observed'}) as observe:
            output=io.BytesIO()
            with self.assertRaises(ValueError):probe.serve(io.BytesIO(raw+raw),output,ancestry.Ancestry)
            self.assertEqual(observe.call_count,1)
        for frame in [raw[:-1], b'x'*(probe.MAX_MESSAGE+1)]:
            with self.assertRaises(ValueError):probe.serve(io.BytesIO(frame),io.BytesIO(),ancestry.Ancestry)

    def test_actual_pipe_incomplete_frame_deadline_and_identity_change(self):
        readfd,writefd=os.pipe()
        try:
            os.write(writefd,b'{')
            with os.fdopen(readfd,'rb',buffering=0) as stream:
                began=time.monotonic()
                with self.assertRaises(TimeoutError):probe.read_frame(stream)
                self.assertLess(time.monotonic()-began,4)
        finally:
            os.close(writefd)
        other=dict(REQUEST,requestId='c'*32,sessionId='d'*32)
        raw=json.dumps(REQUEST).encode()+b'\n'+json.dumps(other).encode()+b'\n'
        with mock.patch.object(probe,'observe',return_value={'status':'observed'}) as observe:
            with self.assertRaises(ValueError):probe.serve(io.BytesIO(raw),io.BytesIO(),ancestry.Ancestry)
            self.assertEqual(observe.call_count,1)

    def test_actual_stalled_pipe_writer_deadline_restores_fd_mode(self):
        readfd,writefd=os.pipe()
        try:
            with os.fdopen(writefd,'wb',buffering=0) as output:
                began=time.monotonic()
                with self.assertRaises(TimeoutError):probe.write_reply(output,b'x'*probe.MAX_MESSAGE)
                self.assertLess(time.monotonic()-began,3)
                self.assertTrue(os.get_blocking(output.fileno()))
        finally:os.close(readfd)

    def graph(self, outside=False, wrong_guid=False):
        target={'name':'/dev/vdb','kname':'/dev/vdb','type':'disk','maj:min':'252:16',
                'ptuuid':'0'*36 if wrong_guid else REQUEST['diskId'],
                'children':[{'name':'/dev/vdb3','kname':'/dev/vdb3','type':'part','maj:min':'252:19'}]}
        disks=[target]
        if outside:disks.append({'name':'/dev/vdc','kname':'/dev/vdc','type':'disk','maj:min':'252:32'})
        mounts={'filesystems':[dict(target='/', source='/dev/vdc' if outside else '/dev/vdb3',
                                    fstype='ext4',options='rw',**{'maj:min':'252:32' if outside else '252:19'})]}
        def command(argv, deadline):
            return {'lsblk':json.dumps({'blockdevices':disks}),
                    'findmnt':json.dumps(mounts) if '--json' in argv else 'rw',
                    'losetup':json.dumps({'loopdevices':[]}) if '--json' in argv else ''}[argv[0]]
        with mock.patch.object(probe,'run',side_effect=command),mock.patch.object(Path,'glob',return_value=[]):
            return probe.backing(REQUEST['diskId'],time.monotonic()+1,ancestry.Ancestry)

    def test_actual_ancestry_consumer_refuses_other_root_or_absent_gpt(self):
        self.assertTrue(self.graph()['currentRootVerified'])
        with self.assertRaises(ancestry.Mismatch):self.graph(outside=True)
        with self.assertRaises(ValueError):self.graph(wrong_guid=True)

if __name__ == '__main__':unittest.main()
