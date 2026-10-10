#!/usr/bin/env python3
import json
import hashlib
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
        if args[0]=='rpm':
            package=args[-1] if args[1]=='-q' else ('grub2-efi-x64' if args[-1].endswith('grubx64.efi') else 'shim-x64')
            if '%{NAME}' in args[3]:
                if args[1]=='-qf' and getattr(self,'rpm_wrong_owner',False):package='foreign-package'
                version='0:2.0-1' if getattr(self,'rpm_wrong_evr',False) else '0:1.0-1'
                return package+'\t'+version+'\tx86_64\t8\n'
            names=['grubx64.efi'] if package=='grub2-efi-x64' else ['shimx64.efi','mmx64.efi']
            rows=[]
            for name in names:
                path=self.fat/'EFI/almalinux'/name
                if getattr(self,'rpm_versioned_paths',False):
                    family='grub2' if name=='grubx64.efi' else 'shim'
                    path=self.install/'usr/lib/efi'/family/'1.0-1/EFI/almalinux'/name
                expected=hashlib.sha256(path.read_bytes()).hexdigest()
                if getattr(self,'rpm_bad_digest',False):expected='0'*64
                state='1' if getattr(self,'rpm_replaced_file',False) else '0'
                rows.append(str(path)+'\t'+expected+'\t'+state+'\t100700\n')
            return ''.join(rows)
        if args[1]=='--search':
            owner=self.paths[args[2]]
            if getattr(self,'mutate_owner_after_capture',False) and self.queries>=3:owner='foreign-package'
            return owner+': '+args[2]
        if args[1]=='--show':
            self.queries+=1
            version='2.0' if self.change_package and self.queries>3 else self.version
            name=args[-1]
            if getattr(self,'mutate_binary_after_capture',False) and self.queries>3:name='foreign-package'
            return name+'\t'+version+'\t'+self.status+'\tamd64\n'
        raise AssertionError(args)

    def freeze(self):
        return source.freeze_classic_sources(self.root/'snapshot',self.observation,self.esp,self.host,
                    self.fat,self.release,self.proc,self.sys,self.install,self.command)

    def test_complete_measured_bundle_has_actual_os_package_and_version_stamp(self):
        result=self.freeze();metadata=json.loads((self.root/'snapshot/EFI.json').read_text())
        self.assertEqual(set(result),{'debian'});self.assertEqual(metadata['os'],{'ID':'debian','VERSION_ID':'13'})
        self.assertEqual(len(metadata['packages']),3);self.assertTrue(metadata['version'].startswith('classic-sha256:'))
        self.assertNotIn('imageRef',metadata);self.assertNotIn('imageDigest',metadata)

    def ubuntu_layout(self):
        self.release.write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
        (self.fat/'EFI/debian').rename(self.fat/'EFI/ubuntu')
        shim=self.install/'usr/lib/shim/shimx64.efi.signed'
        shim.rename(self.install/'usr/lib/shim/shimx64.efi.signed.latest')
        shim.symlink_to(str(shim)+'.latest')
        self.paths.pop(str(shim));self.paths[str(shim)+'.latest']='shim-signed'
        mm=self.install/'usr/lib/shim/mmx64.efi.signed'
        mm.rename(self.install/'usr/lib/shim/mmx64.efi')
        self.paths.pop(str(mm));self.paths[str(mm).removesuffix('.signed')]='shim-signed'
    def test_ubuntu_package_layout_binds_mokmanager_to_shim_signed(self):
        self.ubuntu_layout()
        result=self.freeze();metadata=json.loads((self.root/'snapshot/EFI.json').read_text())
        self.assertEqual(set(result),{'ubuntu'});self.assertEqual(len(metadata['packages']),2)
        self.assertEqual(metadata['os']['ID'],'ubuntu')

    def test_selected_ubuntu_alternative_changed_during_capture_refuses(self):
        from unittest.mock import patch
        self.ubuntu_layout()
        link=self.install/'usr/lib/shim/shimx64.efi.signed'
        previous=link.with_name('shimx64.efi.signed.previous')
        previous.write_bytes(link.read_bytes())
        original=source.write_bytes
        def flip(path,data,**kwargs):
            original(path,data,**kwargs)
            if path.name=='shimx64.efi':
                link.unlink();link.symlink_to(previous)
        with patch.object(source,'write_bytes',flip),self.assertRaisesRegex(ValueError,'selection changed'):
            self.freeze()

    def rpm_layout(self):
        self.release.write_text('ID=almalinux\nVERSION_ID="10"\n')
        (self.fat/'EFI/debian').rename(self.fat/'EFI/almalinux')

    def test_rpm_classic_source_uses_installed_digest_and_file_state(self):
        self.rpm_layout();result=self.freeze()
        metadata=json.loads((self.root/'snapshot/EFI.json').read_text())
        self.assertEqual(set(result),{'almalinux'});self.assertEqual(metadata['packageManager'],'rpm')
        self.assertEqual(set(metadata['packages']),{'shim-x64','grub2-efi-x64'})

    def versioned_rpm_layout(self):
        self.rpm_layout();self.rpm_versioned_paths=True
        for name in source.FILES:
            family='grub2' if name=='grubx64.efi' else 'shim'
            canonical=self.install/'usr/lib/efi'/family/'1.0-1/EFI/almalinux'/name
            canonical.parent.mkdir(parents=True,exist_ok=True)
            canonical.write_bytes((self.fat/'EFI/almalinux'/name).read_bytes())

    def test_versioned_rpm_payload_binds_unowned_classic_fat_copy(self):
        self.versioned_rpm_layout()
        self.assertEqual(set(self.freeze()),{'almalinux'})

    def test_versioned_rpm_canonical_owner_refuses_foreign_package(self):
        self.versioned_rpm_layout();self.rpm_wrong_owner=True
        with self.assertRaisesRegex(ValueError,'owner differs'):self.freeze()

    def test_versioned_rpm_payload_must_match_exact_installed_evr(self):
        self.versioned_rpm_layout();self.rpm_wrong_evr=True
        with self.assertRaisesRegex(ValueError,'missing, ambiguous'):self.freeze()

    def test_versioned_rpm_payload_on_foreign_mount_refuses(self):
        self.versioned_rpm_layout()
        with self.mountinfo.open('a') as stream:
            stream.write(f'5 1 8:4 / {self.install}/usr rw - ext4 /dev/vda4 rw\n')
        with self.assertRaisesRegex(ValueError,'outside classic root'):self.freeze()

    def test_rpm_package_digest_mismatch_refuses(self):
        self.rpm_layout();self.rpm_bad_digest=True
        with self.assertRaisesRegex(ValueError,'differs from installed'):self.freeze()

    def test_rpm_replaced_file_state_refuses(self):
        self.rpm_layout();self.rpm_replaced_file=True
        with self.assertRaisesRegex(ValueError,'not installed normally'):self.freeze()

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

    def test_package_owner_changed_after_capture_refuses(self):
        self.mutate_owner_after_capture=True
        with self.assertRaisesRegex(ValueError,'package changed while freezing'):self.freeze()

    def test_binary_package_identity_changed_after_capture_refuses(self):
        self.mutate_binary_after_capture=True
        with self.assertRaisesRegex(ValueError,'package changed while freezing'):self.freeze()

    def test_source_directory_on_measured_loop_root_is_supported(self):
        self.observation['rootFsUuid']='ABCD-1234'
        self.mountinfo.write_text('\n'.join(row for row in self.mountinfo.read_text().splitlines() if not row.startswith('2 '))+'\n')
        part=self.sys/'devices/loop0/loop0p3';part.mkdir();(part/'partition').write_text('3')
        (self.sys/'dev/block/7:3').symlink_to(part)
        self.assertEqual(set(self.freeze()),{'debian'})

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
