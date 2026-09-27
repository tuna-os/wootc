"""Real private file/inode controls plus controlled mount/UID observations.

No bind mount or target image is created by these component tests.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
def load(name, file):
 spec=importlib.util.spec_from_file_location(name, ROOT/file); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
binding=load('binding','payload/vm-observer/input_binding.py')
bundle=load('bundle','payload/vm-observer/install_bundle.py')
commands=load('commands','payload/vm-observer/installer_commands.py')

class InputControls(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='wootc-input-closure-');self.addCleanup(self.tmp.cleanup)
  self.base=Path(self.tmp.name);self.base.chmod(0o755)
  self.source=self.base/'authenticated';self.foreign=self.base/'foreign';self.source.mkdir(mode=0o755);self.foreign.mkdir(mode=0o755)
  self.expected={}
  for name in bundle.FILES:
   value=('authenticated '+name).encode();self.expected[name]=hashlib.sha256(value).hexdigest()
   for directory in [self.source,self.foreign]:
    (directory/name).write_bytes(value);(directory/name).chmod(0o644)
  actual=Path.lstat
  def facts(path):
   s=actual(path);values={key:getattr(s,key) for key in dir(s) if key.startswith('st_')};values['st_uid']=0
   if str(path)=='/tmp':values['st_mode']=0o40755
   return SimpleNamespace(**values)
  self.patch=mock.patch.object(Path,'lstat',facts);self.patch.start();self.addCleanup(self.patch.stop)
  self.row={'target':'/run/wootc-observer-input','source':'rootfs[/lib/wootc-observer]','fstype':'rootfs','options':'ro','maj:min':'0:1'}
  self.calls=[]
 def arguments(self, **changes):
  value=dict(source=self.source,bound=self.source,expected=self.expected,expected_mount_source=self.row['source'],expected_major='0:1',execute=lambda a:json.dumps({'filesystems':[self.row]}),findmnt='/usr/bin/findmnt',observed_mount=commands.observed_mount,read_owned=bundle.read_owned,regular=bundle.regular,directory=bundle.directory)
  value.update(changes);return value
 def invoke(self, **changes):
  return binding.invoke_verified_input(lambda retained:self.calls.append(retained), **self.arguments(**changes))
 def test_current_exact_inode_hash_closure_before_callback(self):
  self.invoke()
  self.assertEqual(len(self.calls),1)
  for name,facts in self.calls[0].items():
   self.assertEqual(facts['inode'],(self.source/name).stat().st_ino)
   self.assertEqual(facts['sha256'],self.expected[name])
 def test_foreign_same_device_identical_bytes_refuse_before_callback(self):
  self.assertEqual(self.source.stat().st_dev,self.foreign.stat().st_dev)
  self.assertEqual((self.source/'boot_probe.py').read_bytes(),(self.foreign/'boot_probe.py').read_bytes())
  with self.assertRaises(ValueError):self.invoke(bound=self.foreign)
  self.assertEqual(self.calls,[])
 def test_same_device_foreign_mount_subtree_refuses_before_callback(self):
  expected=self.row['source'];self.row['source']='rootfs[/foreign-same-filesystem]'
  with self.assertRaises(ValueError):self.invoke(expected_mount_source=expected)
  self.assertEqual(self.calls,[])
 def test_actual_changed_source_bytes_refuse_before_callback(self):
  (self.source/'boot_probe.py').write_bytes(b'changed')
  with self.assertRaises(ValueError):self.invoke()
  self.assertEqual(self.calls,[])
 def test_actual_source_link_and_writable_modes_refuse(self):
  name=self.source/'boot_probe.py';name.chmod(0o666)
  with self.assertRaises(ValueError):self.invoke()
  name.unlink();name.symlink_to(self.foreign/'boot_probe.py')
  with self.assertRaises(ValueError):self.invoke()
  self.assertEqual(self.calls,[])
 def test_failed_mount_observation_and_rw_refuse_before_callback(self):
  def failed(argv):raise ValueError('actual command failed')
  with self.assertRaises(ValueError):self.invoke(execute=failed)
  self.row['options']='rw'
  with self.assertRaises(ValueError):self.invoke()
  self.assertEqual(self.calls,[])

if __name__=='__main__':unittest.main()
