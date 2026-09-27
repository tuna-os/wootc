"""Actual owned child command boundary; no native SELinux or target mutation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[2]
def module(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
commands=module('commands','payload/vm-observer/installer_commands.py')
probe=module('probe','payload/vm-observer/boot_probe.py')

class CommandControls(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='wootc-installer-tools-');self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.tools={name:self.root/name for name in ('findmnt','matchpathcon','setfiles')}
  for name,path in self.tools.items():path.write_text('#!/usr/bin/python3\nprint("system_u:object_r:usr_t:s0")\n');path.chmod(0o755)
  self.execute=commands.executor(probe._run_owned,self.tools,time.monotonic()+8)
 def test_positive_actual_fixed_child_then_failed_plausible_stdout_refusal(self):
  args=[str(self.tools['matchpathcon']),'-n','/var/usrlocal/lib/wootc/observer/boot_probe.py']
  self.assertEqual(self.execute(args),'system_u:object_r:usr_t:s0')
  self.tools['matchpathcon'].write_text('#!/usr/bin/python3\nprint("system_u:object_r:usr_t:s0")\nraise SystemExit(1)\n')
  with self.assertRaises(ValueError):self.execute(args)
 def test_actual_blocking_child_deadline(self):
  self.tools['matchpathcon'].write_text('#!/usr/bin/python3\nimport time\ntime.sleep(20)\n')
  execute=commands.executor(probe._run_owned,self.tools,time.monotonic()+0.1);start=time.monotonic()
  with self.assertRaises(TimeoutError):execute([str(self.tools['matchpathcon']),'-n','/var/usrlocal/lib/wootc/observer/boot_probe.py'])
  self.assertLess(time.monotonic()-start,1)
 def test_foreign_argv_refuses_before_owned_runner(self):
  calls=[];execute=commands.executor(lambda a,d:calls.append(a),self.tools,time.monotonic()+1)
  for argv in [['/bin/sh','-c','true'],[str(self.tools['matchpathcon']),'-n','/etc/shadow'],[str(self.tools['setfiles']),'-F','/foreign']]:
   with self.assertRaises(ValueError):execute(argv)
  self.assertEqual(calls,[])
 def test_mount_success_requires_typed_mode_identity(self):
  row={'target':'/run/wootc-observer-input','source':'rootfs[/lib/wootc-observer]','fstype':'rootfs','options':'ro,relatime','maj:min':'0:1'}
  def observe(r):return commands.observed_mount(lambda a:json.dumps({'filesystems':[r]}),'/usr/bin/findmnt',row['target'],'0:1',True)
  self.assertEqual(observe(row),row)
  for key,value in [('target','/foreign'),('options','rw,relatime'),('maj:min','0:2'),('fstype','nfs'),('source','')]:
   changed=dict(row);changed[key]=value
   with self.subTest(key=key),self.assertRaises(ValueError):observe(changed)
  with self.assertRaises(ValueError):commands.observed_mount(lambda a:'','/usr/bin/findmnt',row['target'],'0:1',True)
 def test_failed_mount_command_cannot_provide_typed_receipt(self):
  row={'target':'/run/wootc-observer-input','source':'rootfs[/lib/wootc-observer]','fstype':'rootfs','options':'ro','maj:min':'0:1'}
  self.tools['findmnt'].write_text('#!/usr/bin/python3\nprint('+repr(json.dumps({'filesystems':[row]}))+')\nraise SystemExit(1)\n')
  with self.assertRaises(ValueError):commands.observed_mount(self.execute,self.tools['findmnt'],row['target'],'0:1',True)

if __name__=='__main__':unittest.main()
