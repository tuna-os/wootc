#!/usr/bin/env python3
import sys
from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'payload/migration/lib'))
import wootc_chain_verify as c


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self): self.temp.cleanup()

    def variable(self, name, guid, value):
        (self.dir / (name + '-' + guid)).write_bytes(b'\x07\0\0\0' + value)

    def test_unknown_secure_boot_never_means_disabled(self):
        for value in (b'', b'\2', b'\0\0', b'unknown'):
            self.variable('SecureBoot', c.GLOBAL, value)
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'unknown EFI state'):
                c.verify_transition(self.dir, self.dir, self.dir, self.dir)

    def test_missing_efi_variable_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'required EFI variable missing'):
            c.verify_transition(self.dir, self.dir, self.dir, self.dir)

    def test_setup_mode_refuses_before_any_verifier_run(self):
        self.variable('SecureBoot', c.GLOBAL, b'\1')
        self.variable('SetupMode', c.GLOBAL, b'\1')
        with self.assertRaisesRegex(ValueError, 'SetupMode'):
            c.verify_transition(self.dir, self.dir, self.dir, self.dir)

    def test_malformed_db_cannot_yield_partial_trust(self):
        self.variable('SecureBoot', c.GLOBAL, b'\1')
        self.variable('SetupMode', c.GLOBAL, b'\0')
        self.variable('db', c.DB_GUID, b'truncated')
        with self.assertRaisesRegex(ValueError, 'truncated container'):
            c.verify_transition(self.dir, self.dir, self.dir, self.dir)

    def test_optional_missing_mok_blacklist_is_empty_not_unreadable_override(self):
        self.assertEqual(c.efi_variable(self.dir, 'MokListXRT', c.SHIM_GUID, optional=True), b'')
        self.variable('MokListXRT', c.SHIM_GUID, b'bad')
        self.assertEqual(c.efi_variable(self.dir, 'MokListXRT', c.SHIM_GUID, optional=True), b'bad')
        with self.assertRaises(ValueError): c.checked_database(b'bad')

    def test_key_rotation_requires_both_shims_accept_both_companions(self):
        for name,guid,value in [('SecureBoot',c.GLOBAL,b'\1'),('SetupMode',c.GLOBAL,b'\0'),
                                ('db',c.DB_GUID,b'fixture'),('dbx',c.DB_GUID,b''),
                                ('SbatLevelRT',c.SHIM_GUID,b'sbat,1\n')]:self.variable(name,guid,value)
        old=self.dir/'old';new=self.dir/'new';old.mkdir();new.mkdir()
        for folder in (old,new):
            for name in c.FILES:(folder/name).write_bytes((folder.name+'/'+name).encode())
        class Image:
            def __init__(self,data):self.data=data
            def vendor_trust(self):return [(c.X509,self.data.split(b'/')[0])],[]
            def embedded_sbat_policies(self):return [{'sbat':1}]
            def sbat(self):return {'sbat':1,'shim':4,'grub':5}
        calls=[]
        class Verifier:
            def __init__(self,*_):pass
            def authenticate(self,path,anchors):
                calls.append((path.parent.name,path.name,anchors))
                if path.name!='shimx64.efi' and path.parent.name.encode() not in anchors:
                    raise ValueError('opposite shim cannot authenticate companion')
            def check_revocations(self,*_):pass
        with patch.object(c,'PE',Image),patch.object(c,'Verifier',Verifier),             patch.object(c,'checked_database',side_effect=lambda raw:[(c.X509,b'firmware')] if raw else []):
            with self.assertRaisesRegex(ValueError,'opposite shim'):
                c.verify_transition(old,new,self.dir,self.dir)
        self.assertTrue(any(name!='shimx64.efi' and anchors!=[folder.encode()] for folder,name,anchors in calls))

    def test_sbat_ratcheted_policy_refuses_old_grub(self):
        class Image:
            def sbat(self): return {'sbat': 1, 'grub': 4, 'grub.almalinux': 2}
        with self.assertRaisesRegex(ValueError, 'grub'):
            c.check_sbat(Image(), [{'sbat': 1, 'grub': 5}])
        c.check_sbat(Image(), [{'sbat': 1, 'grub': 4}])


if __name__ == '__main__': unittest.main()
