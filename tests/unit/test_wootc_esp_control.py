#!/usr/bin/env python3
"""The actual CLI must observe this boot before either mutation path."""
import importlib.machinery
import importlib.util
import os
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch,MagicMock
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
os.environ.setdefault('WOOTC_CHAIN_LIBRARY',str(ROOT/'payload/migration/lib'))
loader=importlib.machinery.SourceFileLoader('esp_control',str(ROOT/'payload/migration/wootc-esp-control'))
spec=importlib.util.spec_from_loader('esp_control',loader)
control=importlib.util.module_from_spec(spec);loader.exec_module(control)

class ControlTests(unittest.TestCase):
    def test_fresh_observation_is_mandatory_before_prepare_or_write(self):
        with tempfile.TemporaryDirectory() as directory:
            esp=Path(directory)/'esp';esp.mkdir();foreign=esp/'foreign';foreign.write_bytes(b'foreign work')
            for action in ('prepare','write'):
                args=['esp-control',action,'--esp',str(esp),'--uuid','fixture']
                if action=='write':args+=['--source',str(foreign),'--destination','foreign']
                with self.subTest(action=action),patch.object(sys,'argv',args),\
                     patch.object(control,'observe_installed_boot',side_effect=ValueError('native ancestry')) as observe,\
                     patch.object(control,'prepare') as prepare,patch.object(control,'write') as write:
                    with self.assertRaisesRegex(ValueError,'native ancestry'):control.main()
                    observe.assert_called_once();prepare.assert_not_called();write.assert_not_called()
                    self.assertEqual(foreign.read_bytes(),b'foreign work')
    def test_source_swap_after_control_approval_refuses_before_esp_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);esp=root/'esp';folder=esp/'EFI/wootc';folder.mkdir(parents=True)
            kernel=folder/'phase2-vmlinuz';kernel.write_bytes(b'old kernel')
            source=root/'approved-kernel';source.write_bytes(b'approved kernel')
            manifest=b'EFI/wootc/phase2-vmlinuz\n';(folder/'wootc-owned.txt').write_bytes(manifest)
            mirror=root/'manifest';mirror.write_bytes(manifest)
            receipt={'schemaVersion':1,'hostEspUuid':'fixture','loaderVendor':'fedora',
                     'preparedBootId':'this-boot','approvedKernelBootId':'this-boot',
                     'approvedKernelSha256':control.digest(source),
                     'ownedManifestSha256':hashlib.sha256(manifest).hexdigest(),
                     'files':{'efi/wootc/phase2-vmlinuz':control.digest(kernel)}}
            receipt_path=root/'receipt';control.atomic_json(receipt_path,receipt)
            args=SimpleNamespace(esp=str(esp),receipt=str(receipt_path),state=str(root/'state'),
                                 uuid='fixture',manifest=str(mirror),source=str(source),
                                 destination='EFI/wootc/phase2-vmlinuz')
            original=control.Transaction.write_artifact
            captured=[]
            def swap(transaction,path,relative,record,approved_hash=None):
                captured.append(approved_hash)
                path.write_bytes(b'unauthenticated replacement')
                return original(transaction,path,relative,record,approved_hash=approved_hash)
            before={str(p):p.read_bytes() for p in esp.rglob('*') if p.is_file()}
            with patch.object(control.Transaction,'write_artifact',swap),                 self.assertRaisesRegex(ValueError,'authenticated preflight hash'):
                control.write(args,{'loaderVendor':'fedora','bootId':'this-boot'})
            self.assertEqual(captured,[receipt['approvedKernelSha256']])
            self.assertEqual(before,{str(p):p.read_bytes() for p in esp.rglob('*') if p.is_file()})
            self.assertFalse((root/'state/pending.json').exists())
            self.assertEqual(control.read_json(receipt_path),receipt)

    def test_artifact_api_cannot_bypass_complete_trio_publication(self):
        args=SimpleNamespace(esp='/fixture',receipt='/fixture/receipt',state='/fixture/state',
                             uuid='fixture',manifest='/fixture/manifest')
        receipt={'loaderVendor':'fedora','preparedBootId':'this-boot'}
        transaction=MagicMock()
        for name in ('shimx64.efi','grubx64.efi','mmx64.efi','deployer-vmlinuz'):
            args.destination='EFI/fedora/'+name
            with self.subTest(name=name),patch.object(control,'Transaction',return_value=transaction),                 patch.object(control,'read_json',return_value=receipt),patch.object(control,'ownership'):
                with self.assertRaisesRegex(ValueError,'cannot publish signed-chain'):
                    control.write(args,{'loaderVendor':'fedora','bootId':'this-boot'})
                transaction.__enter__.return_value.write_artifact.assert_not_called()

    def test_previous_boot_preflight_cannot_authorize_artifact_write(self):
        args=SimpleNamespace(esp='/fixture',receipt='/fixture/receipt',state='/fixture/state',
                             uuid='fixture',manifest='/fixture/manifest',destination='EFI/fedora/grub.cfg')
        receipt={'loaderVendor':'fedora','preparedBootId':'previous-boot'}
        transaction=MagicMock()
        with patch.object(control,'Transaction',return_value=transaction),             patch.object(control,'read_json',return_value=receipt),patch.object(control,'ownership'):
            with self.assertRaisesRegex(ValueError,'no authenticated preflight for this boot'):
                control.write(args,{'loaderVendor':'fedora','bootId':'this-boot'})
            transaction.__enter__.return_value.write_artifact.assert_not_called()

    def test_live_observation_is_passed_to_actual_operation(self):
        observed={'bootId':'this-boot','loaderVendor':'fedora','rootKind':'loop'}
        with patch.object(sys,'argv',['esp-control','prepare','--esp','/fixture','--uuid','fixture']),\
             patch.object(control,'observe_installed_boot',return_value=observed),\
             patch.object(control,'prepare',return_value={'cfgs':['efi/fedora/grub.cfg']}) as prepare,\
             patch('builtins.print'):
            control.main();self.assertIs(prepare.call_args.args[1],observed)

if __name__=='__main__':unittest.main()
