"""Actual lifecycle orchestration with explicit observation/command fixtures."""
import hashlib
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest import mock

MODULE=runpy.run_path(str(Path(__file__).resolve().parents[2]/'tests/e2e/package-runtime/bootstrap.py'))
BOOT='12345678-1234-1234-1234-123456789abc'
UNIT='ActiveState=active\nSubState=running\nMainPID=123\nFragmentPath=/usr/lib/systemd/system/qemu-guest-agent.service\nDropInPaths=\n'


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.prepare=MODULE['prepare_guest_agent'];self.globals=self.prepare.__globals__
        self.files={name:name.encode() for name in MODULE['AGENT_FILES']}
        self.hashes={name:hashlib.sha256(value).hexdigest() for name,value in self.files.items()}
        self.policy={'phases':{'old':{'packages':[{'package':'qemu-guest-agent','sha256':MODULE['AGENT_ARCHIVE']}]}}}
        self.calls=[]
        self.device={'kernelPath':'/sys/devices/fixture/vport0p1','node':'/dev/vport0p1','majorMinor':'240:1','device':1,'inode':2,'rdev':3}
        self.process={'pid':123,'startTicks':'456','openedDeviceFd':'9'}

    def command(self,argv,deadline):
        self.calls.append(argv)
        return UNIT if argv[1]=='show' else ''

    def execute(self,**changes):
        args=dict(observe_boot=lambda:BOOT,command=self.command,read=lambda path,limit:self.files[path],device=lambda:dict(self.device),process=lambda unit,device:dict(self.process))
        args.update(changes)
        with mock.patch.dict(self.globals,AGENT_FILES=self.hashes):return self.prepare(self.policy,**args)

    def test_exact_once_commands_and_prepared_is_not_response(self):
        receipt=self.execute()
        self.assertTrue(receipt['unitPrepared']);self.assertIs(receipt['agentResponding'],False)
        self.assertEqual([argv[1] for argv in self.calls],['control','trigger','settle','daemon-reload','start','show','show'])
        self.assertEqual(self.calls[1],['/usr/bin/udevadm','trigger','--action=add',self.device['kernelPath']])
        self.assertEqual(self.calls[4],['/usr/bin/systemctl','start','qemu-guest-agent.service'])

    def test_each_failed_command_with_plausible_stdout_refuses(self):
        for failure in range(7):
            with self.subTest(failure=failure):
                self.calls=[]
                def command(argv,deadline):
                    self.calls.append(argv)
                    if len(self.calls)==failure+1:raise subprocess.CalledProcessError(1,argv,UNIT.encode())
                    return UNIT if argv[1]=='show' else ''
                with self.assertRaises(subprocess.CalledProcessError):self.execute(command=command)
                self.assertEqual(len(self.calls),failure+1)

    def test_wrong_archive_source_or_device_refuses_before_mutation(self):
        self.policy['phases']['old']['packages'][0]['sha256']='f'*64
        with self.assertRaises(ValueError):self.execute()
        self.assertEqual(self.calls,[])
        self.policy['phases']['old']['packages'][0]['sha256']=MODULE['AGENT_ARCHIVE']
        with self.assertRaises(ValueError):self.execute(read=lambda path,limit:b'foreign')
        self.assertEqual(self.calls,[])
        def absent():raise ValueError('actual named device absent')
        with self.assertRaises(ValueError):self.execute(device=absent)
        self.assertEqual(self.calls,[])

    def test_unit_states_duplicates_unknown_fields_or_different_process_refuse(self):
        for text in (UNIT.replace('active','inactive'),UNIT.replace('running','dead'),UNIT.replace('MainPID=123','MainPID=0'),UNIT+'MainPID=123\n',UNIT+'Unknown=true\n',UNIT.replace('DropInPaths=','DropInPaths=/etc/override')):
            with self.subTest(text=text),self.assertRaises(ValueError):self.execute(command=lambda argv,deadline:text if argv[1]=='show' else '')
        def unopened(unit,device):raise ValueError('named device not opened')
        with self.assertRaises(ValueError):self.execute(process=unopened)
        count=0
        def changed(unit,device):
            nonlocal count
            count+=1
            return dict(self.process,startTicks=str(count))
        with self.assertRaises(ValueError):self.execute(process=changed)

    def test_changed_boot_device_and_source_refuse(self):
        boots=iter((BOOT,'foreign'))
        with self.assertRaises(ValueError):self.execute(observe_boot=lambda:next(boots))
        devices=iter((self.device,dict(self.device,inode=3)))
        with self.assertRaises(ValueError):self.execute(device=lambda:next(devices))
        count=0
        def read(path,limit):
            nonlocal count
            count+=1
            return self.files[path] if count<=3 else b'changed'
        with self.assertRaises(ValueError):self.execute(read=read)


if __name__=='__main__':unittest.main()
