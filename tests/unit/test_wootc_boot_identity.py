#!/usr/bin/env python3
import json
import struct
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'payload/migration/lib'))
import wootc_boot_identity as b
GUID='12345678-1234-5678-abcd-123456789abc'
LOADER='\\EFI\\fedora\\shimx64.efi'


def option(guid=GUID,loader=LOADER):
    hd=struct.pack('<BBHIQQ',4,1,42,1,2048,100000)+uuid.UUID(guid).bytes_le+bytes([2,2])
    name=(loader+'\0').encode('utf-16-le')
    nodes=hd+struct.pack('<BBH',4,4,4+len(name))+name+bytes([127,255,4,0])
    return bytes(4)+struct.pack('<IH',1,len(nodes))+'Linux\0'.encode('utf-16-le')+nodes


class BootIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.host,self.esp,self.proc,self.sys=[self.root/x for x in ('host','esp','proc','sys')]
        for p in (self.host/'wootc/disks',self.esp,self.proc/'self',self.proc/'sys/kernel/random',
                  self.sys/'firmware/efi/efivars',self.sys/'dev/block',self.sys/'devices/loop0/loop',self.sys/'devices/loop0/loop0p3'):
            p.mkdir(parents=True)
        (self.host/'wootc/disks/root.disk').write_bytes(b'actual rootdisk')
        (self.proc/'cmdline').write_text('loop=/wootc/disks/root.disk wootc.host_uuid=1234567890ABCDEF')
        (self.proc/'sys/kernel/random/boot_id').write_text(GUID)
        (self.proc/'self/mountinfo').write_text(f'1 0 8:3 / {self.host} rw - ntfs3 /dev/vda3 rw\n2 0 7:3 / /sysroot rw - xfs /dev/loop0p3 rw\n3 0 8:1 / {self.esp} rw - vfat /dev/vda1 rw\n')
        (self.sys/'devices/loop0/loop0p3/partition').write_text('3')
        (self.sys/'dev/block/7:3').symlink_to(self.sys/'devices/loop0/loop0p3')
        self.backing=self.sys/'devices/loop0/loop/backing_file';self.backing.write_text(str(self.host)+'/wootc/disks/root.disk')
        self.efi=self.sys/'firmware/efi/efivars'
        (self.efi/('BootCurrent-'+b.EFI_GUID)).write_bytes(bytes(4)+struct.pack('<H',4))
        self.boot=self.efi/('Boot0004-'+b.EFI_GUID);self.boot.write_bytes(option())
        (self.efi/('SecureBoot-'+b.EFI_GUID)).write_bytes(bytes(4)+b'\1')
        self.fallback_calls=0;self.host_uuid='1234567890ABCDEF';self.esp_uuid='1234-5678'

    def tearDown(self):self.temp.cleanup()

    def command(self,*args):
        if args==('bootc','status','--json'):
            return json.dumps({'status':{'booted':{'image':{'image':{'image':'ghcr.io/tuna-os/yellowfin:gnome'},'imageDigest':'sha256:'+'a'*64}}}})
        if args[0]=='blkid':
            if args[-1]=='/dev/vda3':return self.host_uuid
            if args[2]=='PARTUUID':return GUID
            return self.esp_uuid
        if args==('efibootmgr','-v'):
            self.fallback_calls+=1
            return 'BootCurrent: 0004\nBoot0004* Linux HD(1,GPT,'+GUID+',0x800,0x32000)/File('+LOADER+')\n'
        raise AssertionError(args)

    def observe(self):return b.observe_installed_boot(self.esp,self.host,'1234-5678',self.proc,self.sys,self.command)

    def test_fresh_positive_identity_includes_observed_ancestry_and_bootid(self):
        record=self.observe();self.assertEqual(record['rootKind'],'loop');self.assertEqual(record['bootId'],GUID)
        self.assertEqual(record['loaderVendor'],'fedora');self.assertEqual(record['bootCurrent']['espPartitionGuid'],GUID)
        self.assertEqual(record['hostEspUuid'],'1234-5678');self.assertEqual(record['imageDigest'],'sha256:'+'a'*64)

    def test_classic_deployment_requires_observed_current_root(self):
        original=self.command
        def missing(*args):
            if args==('bootc','status','--json'):raise FileNotFoundError('bootc unavailable')
            return original(*args)
        self.command=missing
        with self.assertRaisesRegex(ValueError,'missing installed root mount'):self.observe()

    def test_classic_observes_current_root_and_never_invents_image_identity(self):
        original=self.command
        def classic(*args):
            if args==('bootc','status','--json'):raise FileNotFoundError('bootc unavailable')
            return original(*args)
        self.command=classic
        path=self.proc/'self/mountinfo'
        path.write_text(path.read_text().replace(' / /sysroot ', ' / / '))
        record=self.observe()
        self.assertEqual(record['deploymentKind'],'classic')
        self.assertEqual(record['rootDevice'],'7:3')
        self.assertNotIn('imageRef',record);self.assertNotIn('imageDigest',record)

    def test_native_boot_with_old_config_and_healthy_record_cannot_refresh(self):
        (self.root/'host-esp.conf').write_text('HOST_ESP_UUID=1234-5678')
        (self.root/'installed-linux-boot.json').write_text('{"state":"healthy"}')
        (self.proc/'cmdline').write_text('root=UUID=native-root')
        with self.assertRaisesRegex(ValueError,'native/unknown root'):self.observe()

    def test_native_ancestry_cannot_be_disguised_with_loop_cmdline(self):
        self.backing.unlink()
        with self.assertRaisesRegex(ValueError,'no loop block-device ancestor'):self.observe()

    def test_other_loop_backing_refuses(self):
        self.backing.write_text('/different/root.disk')
        with self.assertRaisesRegex(ValueError,'not this root.disk'):self.observe()

    def test_wrong_ntfs_identity_refuses(self):
        self.host_uuid='FFFFFFFFFFFFFFFF'
        with self.assertRaisesRegex(ValueError,'NTFS UUID differs'):self.observe()

    def test_wrong_esp_uuid_refuses(self):
        self.esp_uuid='ABCD-9876'
        with self.assertRaisesRegex(ValueError,'ESP UUID differs'):self.observe()

    def test_other_bootcurrent_partition_refuses(self):
        self.boot.write_bytes(option('aaaaaaaa-1234-5678-abcd-123456789abc'))
        with self.assertRaisesRegex(ValueError,'different ESP'):self.observe()

    def test_malformed_existing_efi_never_falls_back(self):
        self.boot.write_bytes(option()[:-1])
        with self.assertRaises(ValueError):self.observe()
        self.assertEqual(self.fallback_calls,0)

    def test_missing_efi_uses_complete_fresh_fallback(self):
        self.boot.unlink();self.assertEqual(self.observe()['loaderVendor'],'fedora');self.assertEqual(self.fallback_calls,1)

    def test_other_loader_not_accepted(self):
        self.boot.write_bytes(option(loader='\\EFI\\Microsoft\\Boot\\bootmgfw.efi'))
        with self.assertRaisesRegex(ValueError,'not a vendor shim'):self.observe()


if __name__=='__main__':unittest.main()
