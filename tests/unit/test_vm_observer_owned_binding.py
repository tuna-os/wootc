"""Owned lifecycle controls with real private directories and controlled mounts.

No native bind mount, chroot, builder or target image invocation occurs.
"""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('binding',ROOT/'payload/vm-observer/owned_binding.py')
binding=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(binding)

class LifecycleControls(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='wootc-owned-bind-');self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.root.chmod(0o755)
  self.source=self.root/'source';self.source.mkdir(mode=0o755)
  self.target=self.root/'target';self.target.mkdir(mode=0o755);(self.target/'run').mkdir(mode=0o755)
  self.namespace=self.target/'run/wootc-observer-input';self.mounted=False;self.calls=[];self.mount_noop=False;self.unmount_noop=False
  actual=Path.lstat
  def facts(path):
   s=actual(path);values={k:getattr(s,k) for k in dir(s) if k.startswith('st_')};values['st_uid']=0
   if str(path)=='/tmp':values['st_mode']=0o40755
   return SimpleNamespace(**values)
  p=mock.patch.object(Path,'lstat',facts);p.start();self.addCleanup(p.stop)
  original=binding.identity
  p=mock.patch.object(binding,'identity',side_effect=lambda p:original(self.source) if p==self.namespace and self.mounted else original(p));p.start();self.addCleanup(p.stop)
  p=mock.patch.object(binding,'mount_present',side_effect=lambda p:self.mounted);p.start();self.addCleanup(p.stop)
  self.row={'target':'/','source':'rootfs','maj:min':'0:1'}
 def execute(self,argv,deadline):
  self.calls.append(argv)
  if argv[1]=='--bind' and not self.mount_noop:self.mounted=True
  if argv[0]=='/fixed/umount' and not self.unmount_noop:self.mounted=False
 def context(self):return binding.readonly_bundle(self.source,self.target,self.row,{'mount':'/fixed/mount','umount':'/fixed/umount'},self.execute,123)
 def test_order_and_current_readbacks_remove_only_owned_directory(self):
  with self.context() as (path,expected):
   self.assertEqual(path,self.namespace);self.assertTrue(self.mounted)
   self.assertEqual(expected,'rootfs['+str(self.source)+']')
  self.assertFalse(self.namespace.exists());self.assertTrue(self.source.exists())
  self.assertEqual([a[1] for a in self.calls],['--bind','-o',str(self.namespace)])
 def test_successful_noop_bind_never_invokes_consumer(self):
  self.mount_noop=True;called=[]
  with self.assertRaises(ValueError):
   with self.context():called.append(True)
  self.assertEqual(called,[]);self.assertFalse(self.namespace.exists())
 def test_consumer_failure_still_unmounts_and_preserves_source(self):
  with self.assertRaisesRegex(ValueError,'consumer refusal'):
   with self.context():raise ValueError('consumer refusal')
  self.assertFalse(self.mounted);self.assertFalse(self.namespace.exists());self.assertTrue(self.source.exists())
 def test_failed_unmount_preserves_namespace_and_reports_failure(self):
  self.unmount_noop=True
  with self.assertRaisesRegex(ValueError,'kernel readback'):
   with self.context():pass
  self.assertTrue(self.namespace.exists());self.assertTrue(self.mounted)
 def test_collision_refuses_without_any_tool_call(self):
  self.namespace.mkdir()
  with self.assertRaises(ValueError):
   with self.context():self.fail('consumer invoked')
  self.assertEqual(self.calls,[]);self.assertTrue(self.namespace.exists())
 def test_retained_source_row_derives_exact_subtree_not_bound_claim(self):
  row={'target':'/','source':'/dev/vda3[/stateroot]','maj:min':'8:3'}
  self.assertEqual(binding.exact_source_subtree('/usr/lib/wootc-observer',row),'/dev/vda3[/stateroot/usr/lib/wootc-observer]')
  for row in [{'target':'/foreign','source':'rootfs','maj:min':'0:1'},{'target':'/','source':'rootfs[/../foreign]','maj:min':'0:1'}]:
   with self.assertRaises(ValueError):binding.exact_source_subtree('/usr/lib/wootc-observer',row)

if __name__=='__main__':unittest.main()
