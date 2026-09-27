#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'payload/migration/lib'))
import wootc_chain_source as source


class ClassicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.install=self.root/'install';self.esp=self.root/'destination';self.fat=self.install/'boot/efi'
        self.host=self.root/'host';self.proc=self.root/'proc';self.sys=self.root/'sys'
        for p in (self.fat/'EFI/debian',self.install/'etc',self.esp,self.proc/'self',self.proc/'sys/kernel',
                  self.sys/'dev/block',self.sys/'devices/loop0/loop',self.sys/'devices/loop0/loop0p1'):
            p.mkdir(parents=True)
        (self.sys/'devices/loop0/loop0p1/partition').write_text('1')
        (self.sys/'dev/block/7:1').symlink_to(self.sys/'devices/loop0/loop0p1')
        (self.sys/'devices/loop0/loop/backing_file').write_text(str(self.host)+'/wootc/disks/root.disk')
        self.release=self.install/'etc/os-release';self.release.write_text('ID=debian\nVERSION_ID="13"\n')
        self.mountinfo=self.proc/'self/mountinfo'
        self.mountinfo.write_text(f'1 0 7:3 / {self.install} rw - ext4 /dev/loop0p3 rw\n'
                                 f'2 1 7:1 / {self.fat} rw - vfat /dev/loop0p1 rw\n'
                                 f'3 0 8:1 / {self.esp} rw - vfat /dev/vda1 rw\n')
        (self.proc/'sys/kernel/osrelease').write_text('6.12.0-public-fixture')
        self.paths={}
        for name,package,path in (
            ('shimx64.efi','shim-signed','usr/lib/shim/shimx64.efi.signed'),
            ('mmx64.efi','shim-helpers-amd64-signed','usr/lib/shim/mmx64.efi.signed'),
            ('grubx64.efi','grub-efi-amd64-signed','usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed')):
            canonical=self.install/path;canonical.parent.mkdir(parents=True,exist_ok=True)
            canonical.write_bytes(('fixture-'+name).encode());(self.fat/'EFI/debian'/name).write_bytes(canonical.read_bytes())
            self.paths[str(canonical)]=package
        self.observation={'deploymentKind':'classic','rootDevice':'7:3','rootFsUuid':'real-root-uuid',
                          'rootDiskPath':'/wootc/disks/root.disk'}
        self.version='1.0';self.status='installed';self.queries=0;self.change_package=False

    def tearDown(self):self.temp.cleanup()

    def command(self,*args):
        if args[0]=='blkid':return 'ABCD-1234'
        if args[1]=='--search':return self.paths[args[2]]+': '+args[2]
        if args[1]=='--show':
            self.queries+=1
            version='2.0' if self.change_package and self.queries>3 else self.version
            return args[-1]+'\t'+version+'\t'+self.status+'\tamd64\n'
        raise AssertionError(args)

    def freeze(self):
        return source.freeze_classic_sources(self.root/'snapshot',self.observation,self.esp,self.host,
                    self.fat,self.release,self.proc,self.sys,self.install,self.command)

    def test_complete_measured_bundle_has_actual_os_package_and_version_stamp(self):
        result=self.freeze();metadata=json.loads((self.root/'snapshot/EFI.json').read_text())
        self.assertEqual(set(result),{'debian'});self.assertEqual(metadata['os'],{'ID':'debian','VERSION_ID':'13'})
        self.assertEqual(len(metadata['packages']),3);self.assertTrue(metadata['version'].startswith('classic-sha256:'))
        self.assertNotIn('imageRef',metadata);self.assertNotIn('imageDigest',metadata)

    def test_missing_mokmanager_is_not_a_complete_bundle(self):
        (self.fat/'EFI/debian/mmx64.efi').unlink()
        with self.assertRaisesRegex(ValueError,'complete classic'):self.freeze()

    def test_same_vendor_name_cannot_hide_foreign_payload(self):
        (self.fat/'EFI/debian/grubx64.efi').write_bytes(b'foreign-payload')
        with self.assertRaisesRegex(ValueError,'differs from installed'):self.freeze()

    def test_foreign_package_owner_refuses(self):
        self.paths[next(iter(self.paths))]='foreign-package'
        with self.assertRaisesRegex(ValueError,'package owner'):self.freeze()

    def test_half_configured_package_refuses(self):
        self.status='half-configured'
        with self.assertRaisesRegex(ValueError,'not installed'):self.freeze()

    def test_upgrade_during_freeze_refuses(self):
        self.change_package=True
        with self.assertRaisesRegex(ValueError,'package changed'):self.freeze()

    def test_source_aliasing_destination_refuses(self):
        self.mountinfo.write_text(self.mountinfo.read_text().replace('2 1 7:1','2 1 8:1'))
        with self.assertRaisesRegex(ValueError,'aliases'):self.freeze()

    def test_source_on_other_rootdisk_refuses(self):
        (self.sys/'devices/loop0/loop/backing_file').write_text('/other/root.disk')
        with self.assertRaisesRegex(ValueError,'outside installed root.disk'):self.freeze()

    def test_vendor_directory_symlink_cannot_falsify_source_filesystem(self):
        vendor=self.fat/'EFI/debian';outside=self.root/'outside'
        vendor.rename(outside);vendor.symlink_to(outside,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'complete classic'):self.freeze()

    def test_os_release_on_foreign_mount_refuses(self):
        with self.mountinfo.open('a') as f:f.write(f'4 1 8:2 / {self.install}/etc rw - ext4 /dev/vda2 rw\n')
        with self.assertRaisesRegex(ValueError,'os-release is outside'):self.freeze()

    def test_duplicate_os_identity_refuses(self):
        self.release.write_text('ID=debian\nID=ubuntu\nVERSION_ID=13\n')
        with self.assertRaisesRegex(ValueError,'duplicate'):self.freeze()


if __name__=='__main__':unittest.main()
