"""Controlled SELinux observations; no native labeling or image mutation."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock
SPEC=importlib.util.spec_from_file_location('label_policy',Path(__file__).resolve().parents[2]/'payload/vm-observer/label_policy.py')
labels=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(labels)
CONTEXT='system_u:object_r:usr_t:s0'

class LabelControls(unittest.TestCase):
    def setUp(self):self.calls=[]
    def read(self,p):return b'SELINUX=enforcing\nSELINUXTYPE=targeted\n' if str(p)=='/etc/selinux/config' else b'protected reviewed bytes'
    def execute(self,args):self.calls.append(args);return CONTEXT if '-n' in args else ''
    def invoke(self,read=None,execute=None):return labels.label_installed_files(read or self.read,lambda p:Path(p),execute or self.execute)
    def test_typed_policy_readback_before_any_enable(self):
        with mock.patch.object(labels.os,'getxattr',return_value=CONTEXT.encode()+b'\x00'):
            r=self.invoke();self.assertTrue(r['labelsRequired']);self.assertFalse(r['serviceEnabled']);self.assertEqual(len(r['labels']),3)
        self.assertEqual(self.calls[-1][0],'/usr/sbin/setfiles');self.assertEqual(len(self.calls),4)
    def test_failed_command_even_plausible_output_stops(self):
        def failed(args):raise OSError('native status nonzero with plausible context stdout')
        with mock.patch.object(labels.os,'getxattr') as readback:
            with self.assertRaises(OSError):self.invoke(execute=failed)
            readback.assert_not_called()
    def test_failed_setfiles_stops_before_label_readback(self):
        def failed(args):
            if '-F' in args:raise OSError('native label status failed')
            return CONTEXT
        with mock.patch.object(labels.os,'getxattr') as readback:
            with self.assertRaises(OSError):self.invoke(execute=failed)
            readback.assert_not_called()
    def test_wrong_missing_or_malformed_actual_label_refuses(self):
        for value in [b'system_u:object_r:wrong_t:s0',b'',b'x'*4097]:
            with self.subTest(value=value[:32]),mock.patch.object(labels.os,'getxattr',return_value=value),self.assertRaises(ValueError):self.invoke()
        with mock.patch.object(labels.os,'getxattr',side_effect=OSError('label absent')),self.assertRaises(OSError):self.invoke()
    def test_unknown_duplicate_or_disabled_policy(self):
        for value in [b'SELINUX=unknown\n',b'SELINUX=enforcing\nSELINUX=enforcing\n',b'SELINUX=enforcing\nSELINUXTYPE=../../foreign\n']:
            with self.subTest(value=value),self.assertRaises(ValueError):self.invoke(read=lambda p:value)
        r=self.invoke(read=lambda p:b'SELINUX=disabled\n');self.assertFalse(r['labelsRequired']);self.assertFalse(r['serviceEnabled']);self.assertEqual(self.calls,[])
    def test_malformed_lookup_never_calls_setfiles(self):
        for text in ['',CONTEXT+'\n'+CONTEXT,'plausible but untyped']:
            with self.subTest(text=text),self.assertRaises(ValueError):self.invoke(execute=lambda args:text)

if __name__=='__main__':unittest.main()
