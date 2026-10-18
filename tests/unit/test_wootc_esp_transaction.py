#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'payload/migration/lib'))
import wootc_esp_transaction as t
from wootc_chain_verify import FILES


def fixture_verify(old, new, *_):
    return {'verified':True,'current': {n: t.digest(old/n) for n in FILES},
            'candidate': {n: t.digest(new/n) for n in FILES}}


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.esp = self.root/'esp'; self.vendor = self.esp/'EFI/fedora'
        self.vendor.mkdir(parents=True)
        (self.esp/'EFI/wootc').mkdir()
        self.source = self.root/'updates/EFI/almalinux'; self.source.mkdir(parents=True)
        (self.source.parent.parent/'EFI.json').write_text(json.dumps({'version':'public-fixture','timestamp':'2026-09-27T00:00:00Z'}))
        files = {}
        for n in FILES:
            (self.vendor/n).write_bytes(('old-'+n).encode())
            (self.source/n).write_bytes(('new-'+n).encode())
            files['EFI/fedora/'+n] = t.digest(self.vendor/n)
        (self.vendor/'grub.cfg').write_text('# wootc\n')
        files['EFI/fedora/grub.cfg'] = t.digest(self.vendor/'grub.cfg')
        manifest = ('\n'.join(files)+'\n').encode()
        (self.esp/'EFI/wootc/wootc-owned.txt').write_bytes(manifest)
        self.mirror = self.root/'esp-manifest'; self.mirror.write_bytes(manifest)
        self.receipt = {'schemaVersion':1,'hostEspUuid':'fixture-uuid', 'loaderVendor':'fedora',
                        'sourceVendor':'almalinux','files':files,
                        'ownedManifestSha256':hashlib.sha256(manifest).hexdigest()}
        self.receipt_path = self.root/'receipt.json'; t.atomic_json(self.receipt_path,self.receipt)
        self.state = self.root/'state'

    def tearDown(self): self.temp.cleanup()

    def transaction(self, point=None):
        return t.Transaction(self.esp,self.state,self.receipt_path,'fixture-uuid',point, self.mirror)

    def assert_old(self):
        for n in FILES:self.assertEqual((self.vendor/n).read_bytes(),('old-'+n).encode())

    def test_artifact_publication_failure_restores_content_and_receipt(self):
        source=self.root/'replacement';source.write_bytes(b'new config')
        def fail(point):
            if point=='after-artifact':raise OSError('injected artifact interruption')
        with self.transaction(fail) as tx,self.assertRaises(OSError):
            tx.write_artifact(source,'EFI/fedora/grub.cfg',self.receipt)
        self.assertEqual((self.vendor/'grub.cfg').read_bytes(),b'# wootc\n')
        self.assertEqual(t.read_json(self.receipt_path),self.receipt)
        self.assertFalse((self.state/'pending.json').exists())

    def test_artifact_refuses_unowned_destination(self):
        source=self.root/'replacement';source.write_bytes(b'new config')
        with self.transaction() as tx,self.assertRaisesRegex(ValueError,'absent'):
            tx.write_artifact(source,'EFI/fedora/foreign.cfg',self.receipt)
        self.assertFalse((self.state/'pending.json').exists())

    def test_classic_package_stamp_cannot_describe_another_signed_bundle(self):
        facts={'schemaVersion':1,'sourceKind':'classic','components':{name:t.digest(self.source/name) for name in FILES}}
        stamp=hashlib.sha256(json.dumps(facts,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        facts.update(version='classic-sha256:'+stamp,timestamp='2026-09-27T00:00:00Z')
        (self.source.parent.parent/'EFI.json').write_text(json.dumps(facts))
        (self.source/'grubx64.efi').write_bytes(b'another hypothetically signed GRUB')
        with self.transaction() as tx,self.assertRaisesRegex(ValueError,'classic source stamp'):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assert_old();self.assertFalse((self.state/'pending.json').exists())
        self.assertFalse((self.esp/'EFI/wootc/archive').exists())

    def test_complete_same_source_trio_and_hash_bound_receipt(self):
        with self.transaction() as tx:
            self.assertTrue(tx.refresh(self.source,self.receipt,None,None,fixture_verify))
        for n in FILES:self.assertEqual((self.vendor/n).read_bytes(),('new-'+n).encode())
        current=t.read_json(self.receipt_path)
        t.ownership(self.esp,self.mirror,current,'fixture-uuid')
        archive=next((self.esp/'EFI/wootc/archive').iterdir())
        for n in FILES:self.assertEqual((archive/n).read_bytes(),('old-'+n).encode())
        self.assertFalse((self.state/'pending.json').exists())

    def test_every_publication_failpoint_restores_entire_trio(self):
        for boundary in ['before-','after-']:
            for name in ('grubx64.efi','mmx64.efi','shimx64.efi'):
                point=boundary+name
                def fail(value):
                    if value==point:raise OSError('injected write failure')
                with self.subTest(point=point), self.transaction(fail) as tx:
                    with self.assertRaises(OSError):tx.refresh(self.source,self.receipt,None,None,fixture_verify)
                self.assert_old();self.assertEqual(t.read_json(self.receipt_path),self.receipt)
                self.assertFalse((self.state/'pending.json').exists())

    def test_foreign_config_refuses_before_any_esp_write(self):
        (self.vendor/'grub.cfg').write_text('foreign Linux')
        snapshot={str(p):p.read_bytes() for p in self.esp.rglob('*') if p.is_file()}
        with self.transaction() as tx, self.assertRaisesRegex(ValueError,'changed outside'):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assertEqual(snapshot,{str(p):p.read_bytes() for p in self.esp.rglob('*') if p.is_file()})

    def test_manifest_marker_is_not_ownership(self):
        (self.esp/'EFI/wootc/wootc-owned.txt').unlink()
        with self.transaction() as tx,self.assertRaises(ValueError):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assert_old()

    def test_missing_component_refuses_entire_bundle(self):
        (self.source/'mmx64.efi').unlink()
        with self.transaction() as tx,self.assertRaises(FileNotFoundError):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assert_old();self.assertFalse((self.esp/'EFI/wootc/archive').exists())

    def test_wrong_source_vendor_refuses(self):
        self.receipt['sourceVendor']='redhat'
        with self.transaction() as tx,self.assertRaisesRegex(ValueError,'source vendor differs'):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assert_old()

    def test_rollback_failure_preserves_journal_and_refuses_success(self):
        def fail(point):
            if point=='after-grubx64.efi':
                archive=next((self.esp/'EFI/wootc/archive').iterdir())
                (archive/'shimx64.efi').write_bytes(b'corrupt')
                raise OSError('injected failure with corrupt rollback')
        with self.transaction(fail) as tx,self.assertRaisesRegex(ValueError,'archive corrupt'):
            tx.refresh(self.source,self.receipt,None,None,fixture_verify)
        self.assertTrue((self.state/'pending.json').exists())

    def test_killed_writer_recovers_before_next_refresh(self):
        library=str(ROOT/'payload/migration/lib')
        for name in ('grubx64.efi','mmx64.efi','shimx64.efi'):
            script='''import sys,os
sys.path.insert(0,sys.argv[1])
import wootc_esp_transaction as t
from wootc_chain_verify import FILES
from pathlib import Path
root=Path(sys.argv[2]);point=sys.argv[3]
def verify(old,new,*args):return {'verified':True,'current':{n:t.digest(old/n) for n in FILES},'candidate':{n:t.digest(new/n) for n in FILES}}
def fail(value):
 if value=='after-'+point:os._exit(73)
with t.Transaction(root/'esp',root/'state',root/'receipt.json','fixture-uuid',fail,root/'esp-manifest') as tx:
 tx.refresh(root/'updates/EFI/almalinux',t.read_json(root/'receipt.json'),None,None,verify)
'''
            result=subprocess.run([sys.executable,'-c',script,library,str(self.root),name])
            self.assertEqual(result.returncode,73)
            self.assertTrue((self.state/'pending.json').exists())
            with self.transaction() as tx:tx.recover()
            self.assert_old();self.assertEqual(t.read_json(self.receipt_path),self.receipt)

    def test_killed_artifact_writer_restores_content_and_receipt(self):
        source=self.root/'replacement';source.write_bytes(b'new config')
        script="""import sys,os
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import wootc_esp_transaction as t
root=Path(sys.argv[2])
def fail(value):
 if value=='after-artifact':os._exit(73)
with t.Transaction(root/'esp',root/'state',root/'receipt.json','fixture-uuid',fail,root/'esp-manifest') as tx:
 tx.write_artifact(root/'replacement','EFI/fedora/grub.cfg',t.read_json(root/'receipt.json'))
"""
        result=subprocess.run([sys.executable,'-c',script,str(ROOT/'payload/migration/lib'),str(self.root)])
        self.assertEqual(result.returncode,73)
        with self.transaction() as tx:tx.recover()
        self.assertEqual((self.vendor/'grub.cfg').read_bytes(),b'# wootc\n')
        self.assertEqual(t.read_json(self.receipt_path),self.receipt)

    def test_mutated_verifier_evidence_does_not_publish(self):
        def bad(old,new,*args):
            proof=fixture_verify(old,new);proof['candidate']['shimx64.efi']='0'*64;return proof
        with self.transaction() as tx,self.assertRaisesRegex(ValueError,'evidence differs'):
            tx.refresh(self.source,self.receipt,None,None,bad)
        self.assert_old()


if __name__=='__main__':unittest.main()
