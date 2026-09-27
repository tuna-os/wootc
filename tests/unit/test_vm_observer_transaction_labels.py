"""Controlled SELinux native-call boundaries; no actual target labels claimed."""
import importlib.util
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('labels',ROOT/'payload/vm-observer/label_policy.py')
labels=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(labels)

class LabelControls(unittest.TestCase):
 def setUp(self):
  names=[*(str(p) for p in labels.FILES),'/var/usrlocal/lib/wootc/observer',labels.ACTIVATION]
  self.objects=[{'path':path,'device':1,'inode':index+10,'kind':'link' if path==labels.ACTIVATION else 'directory' if path in labels.TRANSACTION_DIRS else 'file'} for index,path in enumerate(names)]
  self.lookup={record['path']:record for record in self.objects};self.values={};self.writes=[];self.fds={};self.nextfd=100
  def facts(path):
   record=self.lookup.get(str(path),{'kind':'directory','device':1,'inode':999});mode={'file':0o100644,'directory':0o40755,'link':0o120777}[record['kind']]
   return SimpleNamespace(st_mode=mode,st_uid=0,st_dev=record['device'],st_ino=record['inode'])
  self.facts=facts
  def opened(path,flags):
   fd=self.nextfd;self.nextfd+=1;self.fds[fd]=str(path);return fd
  def keyed(path):
   if type(path) is int:return self.fds[path]
   if str(path).startswith('/proc/self/fd/'):return labels.ACTIVATION
   return str(path)
  self.keyed=keyed
  for patch in [mock.patch.object(labels.os,'open',side_effect=opened),mock.patch.object(labels.os,'fstat',side_effect=lambda fd:facts(Path(self.fds[fd]))),mock.patch.object(labels.os,'close'),mock.patch.object(labels.os,'fsync'),mock.patch.object(Path,'lstat',facts),mock.patch.object(labels.os,'readlink',return_value='../wootc-observer.service'),mock.patch.object(labels.os,'setxattr',side_effect=self.set),mock.patch.object(labels.os,'getxattr',side_effect=lambda p,k,**kw:self.values[self.keyed(p)])]:
   patch.start();self.addCleanup(patch.stop)
 def set(self,path,key,value,**kwargs):
  self.assertEqual(key,'security.selinux');self.assertEqual(kwargs,{} if type(path) is int else {'follow_symlinks':False});key=self.keyed(path);self.values[key]=value;self.writes.append(key)
 def read(self,path):return b'SELINUX=enforcing\nSELINUXTYPE=targeted\n' if str(path)=='/etc/selinux/config' else b'protected actual policy source fixture'
 def call(self, objects=None, execute=None):return labels.label_transaction_objects(self.objects if objects is None else objects,self.read,lambda p:p,execute or (lambda a:'system_u:object_r:usr_t:s0'))
 def test_native_calls_cover_exact_new_directory_and_activation_link(self):
  receipt=self.call();self.assertEqual(set(receipt['labels']),set(self.lookup));self.assertEqual(set(self.writes),set(self.lookup))
 def test_failed_native_setter_refuses_before_readback(self):
  with mock.patch.object(labels.os,'setxattr',side_effect=OSError('injected native xattr refusal')):
   with self.assertRaises(OSError):self.call()
  self.assertEqual(self.writes,[])
 def test_failed_plausible_policy_lookup_never_sets_label(self):
  def failed(argv):raise ValueError('native command status failed despite context stdout')
  with self.assertRaises(ValueError):self.call(execute=failed)
  self.assertEqual(self.writes,[])
 def test_missing_activation_proof_refuses(self):
  with self.assertRaisesRegex(ValueError,'complete observer'):self.call(self.objects[:-1])
 def test_wrong_readback_context_refuses(self):
  with mock.patch.object(labels.os,'getxattr',return_value=b'system_u:object_r:wrong_t:s0'):
   with self.assertRaisesRegex(ValueError,'readback differs'):self.call()
 def test_link_replaced_during_lookup_refuses_before_link_setter(self):
  changed=False
  def lookup(argv):
   nonlocal changed
   if argv[-1]==labels.ACTIVATION:changed=True
   return 'system_u:object_r:usr_t:s0'
  def facts(path):
   value=self.facts(path)
   if changed and str(path)==labels.ACTIVATION:
    return SimpleNamespace(st_mode=value.st_mode,st_uid=value.st_uid,st_dev=value.st_dev,st_ino=value.st_ino+1)
   return value
  with mock.patch.object(Path,'lstat',facts):
   with self.assertRaisesRegex(ValueError,'link identity changed'):self.call(execute=lookup)
  self.assertNotIn(labels.ACTIVATION,self.writes)
 def test_opened_foreign_inode_refuses_before_native_file_setter(self):
  original=self.facts
  def foreign(fd):
   value=original(Path(self.fds[fd]))
   return SimpleNamespace(st_mode=value.st_mode,st_uid=value.st_uid,st_dev=value.st_dev,st_ino=value.st_ino+1)
  with mock.patch.object(labels.os,'fstat',side_effect=foreign):
   with self.assertRaisesRegex(ValueError,'opened label inode differs'):self.call()
  self.assertEqual(self.writes,[])

 def test_foreign_existing_parent_path_is_not_relabelled(self):
  bad=dict(self.objects[0],path='/etc/shadow')
  with self.assertRaisesRegex(ValueError,'outside owned'):self.call([bad])
  self.assertEqual(self.writes,[])

class ActualDescriptorControls(unittest.TestCase):
 def test_real_descriptor_labels_original_inode_after_path_replacement(self):
  # Execute the production fd path using actual private files/native user xattrs.
  # UID facts and security.selinux -> user.wootc_pin mapping are controlled; this
  # is fd pinning proof, not native SELinux or target image proof.
  with tempfile.TemporaryDirectory(prefix='wootc-label-fd-') as tmp:
   path=Path(tmp)/'source';path.write_bytes(b'owned');path.chmod(0o644)
   retained=Path(tmp)/'retained';virtual=labels.FILES[0]
   original=path.stat();record={'path':str(virtual),'device':original.st_dev,'inode':original.st_ino,'kind':'file'}
   actual_lstat=Path.lstat;actual_open=os.open;actual_fstat=os.fstat;actual_set=os.setxattr;actual_get=os.getxattr
   def rootfacts(value):
    attrs={name:getattr(value,name) for name in dir(value) if name.startswith('st_')};attrs['st_uid']=0;return SimpleNamespace(**attrs)
   def facts(value):return rootfacts(actual_lstat(path)) if value==virtual else actual_lstat(value)
   def opened(value,flags):return actual_open(path if value==virtual else value,flags)
   def setter(fd,key,value,**kwargs):
    self.assertIs(type(fd),int);self.assertEqual(key,'security.selinux');self.assertEqual(kwargs,{})
    path.rename(retained);path.write_bytes(b'foreign');path.chmod(0o644)
    actual_set(fd,'user.wootc_pin',value)
   def reader(fd,key,**kwargs):return actual_get(fd,'user.wootc_pin')
   def read(value):return b'SELINUX=enforcing\nSELINUXTYPE=targeted\n' if str(value)=='/etc/selinux/config' else b'protected policy fixture'
   with mock.patch.object(Path,'lstat',facts),mock.patch.object(os,'open',side_effect=opened),mock.patch.object(os,'fstat',side_effect=lambda fd:rootfacts(actual_fstat(fd))),mock.patch.object(os,'setxattr',side_effect=setter),mock.patch.object(os,'getxattr',side_effect=reader):
    with self.assertRaisesRegex(ValueError,'readback differs'):
     labels.label_transaction_objects([record],read,lambda p:p,lambda a:'system_u:object_r:usr_t:s0')
   self.assertEqual(actual_get(retained,'user.wootc_pin'),b'system_u:object_r:usr_t:s0\x00')
   with self.assertRaises(OSError):actual_get(path,'user.wootc_pin')

if __name__=='__main__':unittest.main()
