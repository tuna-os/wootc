"""Real private OSTree/BLS files/links with controlled root UID metadata only."""
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
def load(name,file):
 spec=importlib.util.spec_from_file_location(name,ROOT/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
selection=load('selection','payload/vm-observer/deployment_selection.py')
bundle=load('bundle','payload/vm-observer/install_bundle.py')

class SelectionControls(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='wootc-installed-selection-');self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.root.chmod(0o755);self.checksum='a'*64
  self.deployment=self.root/'ostree/deploy/default/deploy'/(self.checksum+'.0');self.deployment.mkdir(parents=True,mode=0o755)
  for p in self.deployment.parents:
   if p==self.root:break
   p.chmod(0o755)
  (self.deployment/'usr/lib').mkdir(parents=True,mode=0o755);(self.deployment/'usr').chmod(0o755)
  self.file(self.deployment/'usr/lib/os-release','ID=actual-target\n')
  self.image='ghcr.io/tuna-os/yellowfin@sha256:'+'b'*64
  self.origin=self.deployment.with_name(self.deployment.name+'.origin');self.file(self.origin,'[origin]\ncontainer-image-reference=ostree-unverified-registry:'+self.image+'\n')
  self.var=self.root/'ostree/deploy/default/var';self.var.mkdir(mode=0o755)
  self.bootlink=self.root/'ostree/boot.1/default'/('c'*64)/'0';self.bootlink.parent.mkdir(parents=True,mode=0o755)
  self.bootlink.symlink_to(os.path.relpath(self.deployment,self.bootlink.parent))
  self.bls=self.root/'boot/loader/entries/selected.conf';self.bls.parent.mkdir(parents=True,mode=0o755)
  for p in self.bls.parents:
   if p==self.root:break
   p.chmod(0o755)
  self.file(self.bls,'title actual\noptions rw ostree=/'+str(self.bootlink.relative_to(self.root))+'\n')
  for directory in self.root.rglob("*"):
   if directory.is_dir() and not directory.is_symlink():directory.chmod(0o755)
  actual=Path.lstat
  def facts(path):
   s=actual(path);v={k:getattr(s,k) for k in dir(s) if k.startswith('st_')};v['st_uid']=0
   if str(path)=='/tmp':v['st_mode']=0o40755
   return SimpleNamespace(**v)
  patch=mock.patch.object(Path,'lstat',facts);patch.start();self.addCleanup(patch.stop)
 def file(self,path,text):path.write_text(text);path.chmod(0o644)
 def select(self,read=bundle.read_owned):return selection.select_installed_deployment(self.root,self.image,read,bundle.directory)
 def test_actual_bls_origin_link_select_same_deployment(self):
  result=self.select();self.assertEqual(result['deployment'],str(self.deployment));self.assertEqual(result['stateVar'],str(self.var));self.assertEqual(result['image'],self.image)
  self.assertTrue(result['configurationOnly'])
 def test_wrong_full_pinned_origin_refuses(self):
  self.file(self.origin,'[origin]\ncontainer-image-reference=ostree-unverified-registry:foreign@sha256:'+'b'*64+'\n')
  with self.assertRaises(ValueError):self.select()
 def test_wrong_bls_target_and_absolute_link_refuse(self):
  self.bootlink.unlink();self.bootlink.symlink_to(os.path.relpath(self.var,self.bootlink.parent))
  with self.assertRaises(ValueError):self.select()
  self.bootlink.unlink();self.bootlink.symlink_to(str(self.deployment))
  with self.assertRaises(ValueError):self.select()
 def test_missing_duplicate_or_malformed_bls_refuse(self):
  raw=self.bls.read_text();self.bls.unlink()
  with self.assertRaises(ValueError):self.select()
  self.file(self.bls,raw);self.file(self.bls.with_name('duplicate.conf'),raw)
  with self.assertRaises(ValueError):self.select()
  self.bls.with_name('duplicate.conf').unlink();self.file(self.bls,raw+'options rw\n')
  with self.assertRaises(ValueError):self.select()
 def test_changed_origin_during_readback_refuses(self):
  count=0
  def read(path):
   nonlocal count
   result=bundle.read_owned(path)
   if path==self.origin:
    count+=1
    if count==2:return result+b'changed'
   return result
  with self.assertRaisesRegex(ValueError,'changed'):self.select(read)
 def test_unprotected_bls_real_mode_and_unknown_layout_refuse(self):
  self.bls.chmod(0o666)
  with self.assertRaises(ValueError):self.select()
  self.bls.chmod(0o644);(self.deployment.parent/'unknown').mkdir(mode=0o755)
  with self.assertRaises(ValueError):self.select()

if __name__=='__main__':unittest.main()
