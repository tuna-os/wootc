#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.esp=Path(self.temp.name)
        (self.esp/'EFI/wootc').mkdir(parents=True);(self.esp/'EFI/fedora').mkdir()
        self.manifest=self.esp/'EFI/wootc/wootc-owned.txt'
        self.manifest.write_bytes(b'EFI\\fedora\\shimx64.efi\r\n\r\nEFI\\fedora\\grub.cfg\r\n')
        (self.esp/'EFI/fedora/shimx64.efi').write_bytes(b'ours')
        (self.esp/'EFI/fedora/grub.cfg').write_text('# wootc')

    def tearDown(self):self.temp.cleanup()

    def claim(self,relative):
        return subprocess.run(['bash','-c','source "$1";esp_claim_before_write "$2" "$3"','claim',
            str(ROOT/'payload/migration/wootc-esp-own'),str(self.esp),relative],capture_output=True)

    def test_crlf_actual_windows_manifest_owned_path_is_accepted(self):
        before=self.manifest.read_bytes();self.assertEqual(self.claim('EFI/fedora/grub.cfg').returncode,0)
        self.assertEqual(self.manifest.read_bytes(),before)

    def test_foreign_config_marker_never_mints_ownership(self):
        (self.esp/'EFI/redhat').mkdir();foreign=self.esp/'EFI/redhat/grub.cfg';foreign.write_text('# wootc foreign marker')
        before=self.manifest.read_bytes();self.assertNotEqual(self.claim('EFI/redhat/grub.cfg').returncode,0)
        self.assertEqual(self.manifest.read_bytes(),before);self.assertEqual(foreign.read_text(),'# wootc foreign marker')

    def test_new_absent_file_is_claimed_before_creation(self):
        relative='EFI/wootc/phase2-vmlinuz';self.assertEqual(self.claim(relative).returncode,0)
        self.assertFalse((self.esp/relative).exists());self.assertIn(b'efi/wootc/phase2-vmlinuz',self.manifest.read_bytes())

    def test_existing_unclaimed_kernel_cannot_be_deleted_or_claimed(self):
        existing=self.esp/'EFI/wootc/phase2-vmlinuz';existing.write_bytes(b'foreign kernel')
        self.assertNotEqual(self.claim('EFI/wootc/phase2-vmlinuz').returncode,0);self.assertEqual(existing.read_bytes(),b'foreign kernel')

    def test_missing_manifest_or_traversal_refuses(self):
        self.assertNotEqual(self.claim('../EFI/foreign').returncode,0)
        self.manifest.unlink();self.assertNotEqual(self.claim('EFI/wootc/phase2-vmlinuz').returncode,0)


if __name__=='__main__':unittest.main()
