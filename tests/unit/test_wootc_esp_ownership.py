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

    def test_pre_manifest_own_namespace_leftover_is_claimed_for_reinstall(self):
        # A wootc install from before the manifest left its Phase-2 pair in
        # EFI/wootc unclaimed; its reinstall must not be refused (#477 review).
        existing=self.esp/'EFI/wootc/phase2-vmlinuz';existing.write_bytes(b'older wootc kernel')
        self.assertEqual(self.claim('EFI/wootc/phase2-vmlinuz').returncode,0)
        self.assertIn(b'efi/wootc/phase2-vmlinuz',self.manifest.read_bytes())
        self.assertEqual(existing.read_bytes(),b'older wootc kernel')
        (self.esp/'loader/entries').mkdir(parents=True);(self.esp/'loader/entries/wootc.conf').write_text('title old')
        self.assertEqual(self.claim('loader/entries/wootc.conf').returncode,0)

    def test_existing_unclaimed_shared_vendor_file_cannot_be_claimed(self):
        (self.esp/'EFI/fedora/grub.cfg').write_text('set default=0\n')
        existing=self.esp/'EFI/fedora/grubx64.efi';existing.write_bytes(b'foreign grub')
        before=self.manifest.read_bytes()
        self.assertNotEqual(self.claim('EFI/fedora/grubx64.efi').returncode,0)
        self.assertEqual(existing.read_bytes(),b'foreign grub');self.assertEqual(self.manifest.read_bytes(),before)

    def test_wootc_marked_fedora_tree_is_claimed_without_prior_manifest_entry(self):
        # setup-wootc.ps1 and pre-manifest installers stage EFI/fedora under
        # the "# wootc" grub.cfg marker without claims (app ownsFedoraNamespace).
        existing=self.esp/'EFI/fedora/grubx64.efi';existing.write_bytes(b'wootc staged grub')
        self.assertEqual(self.claim('EFI/fedora/grubx64.efi').returncode,0)
        self.assertIn(b'efi/fedora/grubx64.efi',self.manifest.read_bytes())

    def test_absent_manifest_is_started_empty_in_own_namespace(self):
        self.manifest.unlink()
        ensure=lambda:subprocess.run(['bash','-c','source "$1";esp_ensure_manifest "$2"','ensure',
            str(ROOT/'payload/migration/wootc-esp-own'),str(self.esp)],capture_output=True)
        self.assertEqual(ensure().returncode,0);self.assertEqual(self.manifest.read_bytes(),b'')
        self.manifest.write_bytes(b'efi/fedora/grub.cfg\n')
        self.assertEqual(ensure().returncode,0);self.assertEqual(self.manifest.read_bytes(),b'efi/fedora/grub.cfg\n')
        self.manifest.unlink();self.manifest.symlink_to(self.esp/'EFI/fedora/grub.cfg')
        self.assertNotEqual(ensure().returncode,0)

    def test_symlink_in_own_namespace_refuses(self):
        link=self.esp/'EFI/wootc/phase2-vmlinuz';link.symlink_to(self.esp/'EFI/fedora/shimx64.efi')
        self.assertNotEqual(self.claim('EFI/wootc/phase2-vmlinuz').returncode,0)

    def test_missing_manifest_or_traversal_refuses(self):
        self.assertNotEqual(self.claim('../EFI/foreign').returncode,0)
        self.manifest.unlink();self.assertNotEqual(self.claim('EFI/wootc/phase2-vmlinuz').returncode,0)


if __name__=='__main__':unittest.main()
