"""Native20-byte Virtio wire calculation and actual producer/observer refusal controls."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
BOOTSTRAP=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/bootstrap.py'))
LAUNCH=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/launch.py'))


class DiskIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='.wootc-virtio-wire-',dir=ROOT)
        self.addCleanup(self.temp.cleanup);self.folder=Path(self.temp.name)
        self.scratch='a'*32;self.challenge='b'*64
        self.serial=BOOTSTRAP['disk_serial'](self.scratch,self.challenge)

    def graph(self,serial):
        return [{'name':'vda','type':'disk','serial':serial,'mountpoints':[None],
                 'children':[{'name':'vda1','type':'part','serial':None,'mountpoints':['/']}]}]

    def test_native_virtio20_wire_clips_original42_but_preserves_bound20(self):
        # Same GET_ID min(strlen(serial)+1, in-buffer-size, ID_BYTES) operation
        # as pinned QEMU8.2.2; installed Linux ABI defines ID_BYTES. This is a
        # native wire calculation, not a QEMU guest execution claim.
        code=self.folder/'wire.c';binary=self.folder/'wire'
        code.write_text('#include <linux/virtio_blk.h>\n#include <stdio.h>\n#include <string.h>\nint main(int argc,char **argv) { char out[VIRTIO_BLK_ID_BYTES]; size_t n=strlen(argv[1])+1; if(n>sizeof(out))n=sizeof(out); memcpy(out,argv[1],n); return fwrite(out,1,n,stdout)==n ? 0 : 1; }\n')
        subprocess.run(['/usr/bin/cc',str(code),'-o',str(binary)],check=True,capture_output=True,timeout=30)
        original='WOOTC-PKG-'+self.scratch
        observed=subprocess.run([str(binary),original],check=True,capture_output=True,timeout=2).stdout
        self.assertEqual(observed,original.encode()[:20]);self.assertNotEqual(observed,original.encode())
        with self.assertRaises(BOOTSTRAP['RootIdentityRefusal']):
            BOOTSTRAP['root_identity'](self.graph(observed.decode()),self.serial)
        new=subprocess.run([str(binary),self.serial],check=True,capture_output=True,timeout=2).stdout
        self.assertEqual(new,self.serial.encode())
        facts=BOOTSTRAP['root_identity'](self.graph(new.decode()),self.serial)
        self.assertEqual(facts['roots'][0],{'rootDevice':'vda1','rootType':'part','diskDevice':'vda','serial':self.serial})

    def test_all_scratch_and_challenge_bytes_bind_serial(self):
        self.assertEqual(len(self.serial.encode()),20)
        self.assertNotEqual(self.serial,BOOTSTRAP['disk_serial']('a'*31+'c',self.challenge))
        self.assertNotEqual(self.serial,BOOTSTRAP['disk_serial'](self.scratch,'b'*63+'c'))
        with self.assertRaises(ValueError):BOOTSTRAP['disk_serial']('a'*31,self.challenge)

    def test_wrong_disk_refusal_preserves_actual_bounded_root_facts(self):
        with self.assertRaises(BOOTSTRAP['RootIdentityRefusal']) as caught:
            BOOTSTRAP['root_identity'](self.graph('f'*20),self.serial)
        self.assertEqual(caught.exception.root_identity_facts['roots'][0]['serial'],'f'*20)
        self.assertEqual(caught.exception.root_identity_facts['expectedSerial'],self.serial)
        for rows in [[],self.graph(None),self.graph(self.serial)*2]:
            with self.assertRaises(ValueError):BOOTSTRAP['root_identity'](rows,self.serial)

    def test_root_partition_or_loop_serial_cannot_replace_actual_disk_identity(self):
        wrong=self.graph('f'*20);wrong[0]['children'][0]['serial']=self.serial
        with self.assertRaises(BOOTSTRAP['RootIdentityRefusal']):BOOTSTRAP['root_identity'](wrong,self.serial)
        for kind in ('part','loop','crypt',None):
            rows=[{'name':'pretender','type':kind,'serial':self.serial,'mountpoints':['/']}]
            with self.assertRaises(BOOTSTRAP['RootIdentityRefusal']):BOOTSTRAP['root_identity'](rows,self.serial)
        # A duplicate partition serial never changes the owning whole disk.
        good=self.graph(self.serial);good[0]['children'][0]['serial']=self.serial
        self.assertEqual(BOOTSTRAP['root_identity'](good,self.serial)['roots'][0]['diskDevice'],'vda')

    def test_command_tampered_serial_or_full_binding_refuses_before_tool_lookup(self):
        base={'scratchId':self.scratch,'challenge':self.challenge,'diskSerial':self.serial}
        def forbidden():raise AssertionError('tampered serial reached QEMU lookup')
        for key,value in [('diskSerial','f'*20),('scratchId','c'*32),('challenge','c'*64)]:
            record=dict(base);record[key]=value
            with patch.dict(LAUNCH['command'].__globals__,{'protected_qemu':forbidden}):
                with self.assertRaises(ValueError):LAUNCH['command'](self.folder,record)

    def test_actual_environment_refuses_wrong_wire_identity_before_mount_or_package(self):
        calls=[];original=Path.read_text
        def read(path,*args,**kwargs):
            if str(path)=='/proc/1/comm':return 'systemd\n'
            if str(path)=='/sys/class/dmi/id/product_uuid':return '12345678-1234-1234-1234-123456789abc\n'
            return original(path,*args,**kwargs)
        def command(argv,**kwargs):
            calls.append(argv)
            if argv[0]!='/usr/bin/lsblk':raise AssertionError('wrong disk reached mount/file observation')
            return subprocess.CompletedProcess(argv,0,json.dumps({'blockdevices':self.graph('f'*20)}).encode())
        manifest={'vmUuid':'12345678-1234-1234-1234-123456789abc','diskSerial':self.serial}
        with patch.object(Path,'read_text',read),patch.object(BOOTSTRAP['os'],'geteuid',return_value=0),patch.object(BOOTSTRAP['subprocess'],'run',command):
            with self.assertRaises(BOOTSTRAP['RootIdentityRefusal']):BOOTSTRAP['actual_environment'](manifest,self.folder)
        self.assertEqual(len(calls),1)

    def test_actual_observer_completed_failure_refuses_without_any_readback(self):
        record={'scratchId':self.scratch,'challenge':self.challenge,'actualVirtualBytes':1024,'vmUuid':'12345678-1234-1234-1234-123456789abc'}
        failure={'schemaVersion':1,'stage':'failed','scratchId':self.scratch,'challenge':self.challenge,
                 'failure':'root identity differs','rootIdentityFacts':{'observed':'f'*20},
                 'vmUuid':record['vmUuid'],'bootId':'87654321-4321-4321-4321-cba987654321'}
        path=self.folder/'serial.log';text='WOOTC_PACKAGE_RUNTIME_V1 '+json.dumps(failure)
        def forbidden(*args):raise AssertionError('failed producer reached success readback')
        observe=LAUNCH['make_observer'](self.folder,record,forbidden,forbidden)
        path.write_text(text)
        self.assertIsNone(observe(None,1))
        path.write_text(text+'\n')
        with self.assertRaisesRegex(ValueError,'guest producer refused'):observe(None,1)
        self.assertEqual(json.loads((self.folder/'guest-failure.json').read_text()),failure)

    def test_actual_owned_observation_refusal_still_waits_and_reaps(self):
        def refuse(*_):raise ValueError('actual observer fixture refuses')
        with self.assertRaisesRegex(ValueError,'actual observer fixture refuses'):
            LAUNCH['run_owned'](['/usr/bin/python3','-c','import time;time.sleep(5)'],self.folder,refuse,seconds=1)
        identity=json.loads((self.folder/'pid.json').read_text())
        reap=json.loads((self.folder/'process-reap.json').read_text())
        self.assertEqual(reap['ownedProcessIdentity'],identity)
        self.assertTrue(reap['waitCompleted']);self.assertEqual(type(reap['returnCode']),int)
        self.assertFalse(Path('/proc',str(identity['pid'])).exists())

    def test_actual_owned_deadline_retains_successful_wait_status_bound_to_pid(self):
        with self.assertRaises(TimeoutError):
            LAUNCH['run_owned'](['/usr/bin/python3','-c','import time;time.sleep(5)'],self.folder,lambda *_:None,seconds=.05)
        identity=json.loads((self.folder/'pid.json').read_text())
        reap=json.loads((self.folder/'process-reap.json').read_text())
        self.assertEqual(reap['ownedProcessIdentity'],identity)
        self.assertTrue(reap['waitCompleted']);self.assertIsInstance(reap['returnCode'],int)
        self.assertFalse(Path('/proc',str(identity['pid'])).exists())


if __name__=='__main__':unittest.main()
