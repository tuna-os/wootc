#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'payload/migration/lib'))
import wootc_chain_source as s
from wootc_chain_verify import FILES

class SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.updates=self.root/'updates';self.updates.mkdir()
        self.versioned=self.root/'versioned'
        self.info={'version':'shim-16.1 grub2-2.12','timestamp':'2026-09-27T00:00:00Z',
                   'versions':[{'name':'shim','rpm_evr':'16.1-5'},
                               {'name':'grub2','rpm_evr':'1:2.12-64.fc44'}]}
        self.metadata()
    def metadata(self): (self.updates/'EFI.json').write_text(json.dumps(self.info))
    def bundle(self,root):
        root.mkdir(parents=True)
        for name in FILES:(root/name).write_bytes(name.encode())
    def freeze(self):return s.freeze_sources(self.root/'snapshot',None,self.updates,self.versioned)
    def test_direct_complete_same_vendor(self):
        self.bundle(self.updates/'EFI/almalinux')
        result=self.freeze()
        self.assertEqual(set(result),{'almalinux'})
        for n in FILES:self.assertEqual((result['almalinux']/n).read_bytes(),n.encode())
    def test_actual_fedora_versioned_package_layout(self):
        shim=self.versioned/'shim/16.1-5/EFI/fedora';shim.mkdir(parents=True)
        grub=self.versioned/'grub2/1:2.12-64.fc44/EFI/fedora';grub.mkdir(parents=True)
        for n in ('shimx64.efi','mmx64.efi'):(shim/n).write_bytes(n.encode())
        (grub/'grubx64.efi').write_bytes(b'grubx64.efi')
        self.assertEqual(set(self.freeze()),{'fedora'})
    def test_missing_mokmanager_refuses(self):
        path=self.updates/'EFI/fedora';self.bundle(path);(path/'mmx64.efi').unlink()
        with self.assertRaisesRegex(ValueError,'complete'):self.freeze()
    def test_conflicting_direct_and_versioned_refuses(self):
        self.bundle(self.updates/'EFI/fedora')
        shim=self.versioned/'shim/16.1-5/EFI/fedora';self.bundle(shim)
        grub=self.versioned/'grub2/1:2.12-64.fc44/EFI/fedora';self.bundle(grub)
        (grub/'grubx64.efi').write_bytes(b'other generation')
        with self.assertRaisesRegex(ValueError,'ambiguous'):self.freeze()
    def test_duplicate_version_and_traversal_refuse(self):
        self.bundle(self.updates/'EFI/fedora')
        for mutation in ([self.info['versions'][0]]*2,[{'name':'shim','rpm_evr':'../other'},{'name':'grub2','rpm_evr':'good'}]):
            self.info['versions']=mutation;self.metadata()
            with self.assertRaises(ValueError):self.freeze()
    def test_source_mutation_during_snapshot_refuses(self):
        self.bundle(self.updates/'EFI/fedora');original=s.write_bytes
        def mutate(path,data,**kwargs):
            original(path,data,**kwargs)
            if path.name=='shimx64.efi':(self.updates/'EFI/fedora/mmx64.efi').write_bytes(b'new source')
        with patch.object(s,'write_bytes',mutate),self.assertRaisesRegex(ValueError,'changed while'):self.freeze()

if __name__=='__main__':unittest.main()
