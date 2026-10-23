#!/usr/bin/env python3
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock
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

    def test_phase2_grub_entry_repeats_the_root_disk_arguments(self):
        # The Phase-2 grub.cfg line is ${ROOT_OPTIONS} (the BLS options,
        # which deploy.sh already gave both arguments) followed by loop= and
        # wootc.host_uuid= again. E2E 38996488933 (bluefin:lts) booted with
        # that shape; the exactly-one check refused it.
        (self.proc/'cmdline').write_text(
            'BOOT_IMAGE=(hd0,gpt1)/EFI/wootc/phase2-vmlinuz root=UUID=0b3c rw '
            'ostree=/ostree/boot.1/default/abc/0 wootc.host_uuid=1234567890ABCDEF '
            'loop=/wootc/disks/root.disk loop=/wootc/disks/root.disk '
            'wootc.host_uuid=1234567890ABCDEF console=tty1 console=ttyS0,115200\n')
        record=self.observe()
        self.assertEqual(record['rootDiskPath'],'/wootc/disks/root.disk')
        self.assertEqual(record['hostUuid'],'1234567890ABCDEF')

    def test_fuse_backing_path_relative_to_the_initramfs_mount(self):
        # E2E 39007144179 (bluefin:lts, fuse-ntfs-3g): the initramfs attached
        # root.disk through its own FUSE mount and the real root read
        # loop0/loop/backing_file as "/wootc/disks/root.disk". The controller
        # refused: "installed root is not this root.disk".
        (self.host/'wootc/disks/root.disk').write_bytes(b'\0'*4096)
        self.backing.write_text('/wootc/disks/root.disk\n')
        size=self.sys/'devices/loop0/size'
        size.write_text('8\n')
        self.assertEqual(self.observe()['rootDiskPath'],'/wootc/disks/root.disk')
        size.write_text('16\n')
        with self.assertRaisesRegex(ValueError,'not this root.disk'):self.observe()
        size.write_text('8\n')
        self.backing.write_text('/wootc/disks/root.disk (deleted)\n')
        with self.assertRaisesRegex(ValueError,'not this root.disk'):self.observe()
        self.backing.write_text('/wootc/disks/old-root.disk\n')
        with self.assertRaisesRegex(ValueError,'not this root.disk'):self.observe()

    def test_one_loop_rule_for_controller_and_collector(self):
        sys.path.insert(0,str(ROOT/'payload/migration/lib'))
        import wootc_firstboot_evidence as f
        self.assertIs(f.loop_backs_file,b.loop_backs_file)

    def test_conflicting_or_missing_root_disk_arguments_refuse(self):
        for cmdline,message in (
                ('loop=/wootc/disks/root.disk loop=/wootc/disks/old.disk wootc.host_uuid=1234567890ABCDEF','conflicting boot arguments: loop'),
                ('loop=/wootc/disks/root.disk wootc.host_uuid=1234567890ABCDEF wootc.host_uuid=FEDCBA0987654321','conflicting boot arguments: wootc.host_uuid'),
                ('loop=/wootc/disks/root.disk','missing boot argument: wootc.host_uuid')):
            with self.subTest(cmdline):
                (self.proc/'cmdline').write_text(cmdline)
                with self.assertRaisesRegex(ValueError,message):self.observe()

    def test_one_rule_for_both_readers(self):
        sys.path.insert(0,str(ROOT/'payload/migration/lib'))
        import wootc_firstboot_evidence as f
        self.assertIs(f.cmdline_argument,b.boot_argument)
        self.assertEqual(b.boot_argument(['loop=/a','x=1','loop=/a'],'loop'),'/a')
        self.assertEqual(b.boot_argument(['rd.loop=/b','loop=/a'],'loop'),'/a')

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


# The shape `bootc status --json` prints for a booted ostree-backed install
# (org.containers.bootc/v1), here for ghcr.io/projectbluefin/bluefin:stable as
# published 2026-09-17 (the image E2E 39874539856 ran).
STABLE_DIGEST='sha256:a50af2d633f72b549b395d0973a2cc317654e4e4ad679543b9c52c63c34a0d61'
STABLE_STATUS={
    'apiVersion':'org.containers.bootc/v1','kind':'BootcHost','metadata':{'name':'host'},
    'spec':{'bootOrder':'default','image':{'image':'ghcr.io/projectbluefin/bluefin:stable','transport':'registry'}},
    'status':{'staged':None,'rollback':None,'rollbackQueued':False,'type':'bootcHost',
              'booted':{'image':{'image':{'image':'ghcr.io/projectbluefin/bluefin:stable','transport':'registry'},
                                 'version':'44.20260917.0','timestamp':'2026-09-17T06:33:23Z',
                                 'imageDigest':STABLE_DIGEST,'architecture':'amd64'},
                        'cachedUpdate':None,'incompatible':False,'pinned':False,'store':'ostreeContainer',
                        'ostree':{'checksum':'feddb8baa299a2ff28bb449609ba4d8ab085c895cf92edef486ad97b93330757',
                                  'deploySerial':0,'stateroot':'default'}}}}


class BootcStatusTests(unittest.TestCase):
    """E2E 39874539856 (bluefin:stable): the first boot's
    bootc-unified-storage.service (`bootc image set-unified`) held the ostree
    sysroot lock. `bootc status` waits for that lock, printing "Waiting for
    sysroot lock..." on stderr; the ESP controller gave it the 30 s every other
    command gets and refused "cannot measure installed bootc deployment"
    (wootc-esp-sync 00:49:18 -> 00:49:52), as did the first-boot collector."""

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.bin=Path(self.temp.name)
        self.path=os.environ.get('PATH','')
        os.environ['PATH']=str(self.bin)+os.pathsep+self.path
        self.timeout=b.BOOTC_STATUS_TIMEOUT

    def tearDown(self):
        os.environ['PATH']=self.path;b.BOOTC_STATUS_TIMEOUT=self.timeout;self.temp.cleanup()

    def bootc(self,body):
        tool=self.bin/'bootc'
        tool.write_text('#!/bin/sh\n'+body);tool.chmod(0o755)

    def test_status_waits_for_the_sysroot_lock_and_is_then_measured(self):
        (self.bin/'status.json').write_text(json.dumps(STABLE_STATUS))
        self.bootc('[ "$*" = "status --json" ] || exit 64\n'
                   'echo "Waiting for sysroot lock..." >&2\nsleep 1\n'
                   'cat "$(dirname "$0")/status.json"\n')
        b.BOOTC_STATUS_TIMEOUT=30
        self.assertEqual(b.booted_image(b.bootc_status()),
                         ('ghcr.io/projectbluefin/bluefin:stable',STABLE_DIGEST))

    def test_status_still_waiting_at_the_bound_is_a_refusal_that_says_why(self):
        self.bootc('echo "Waiting for sysroot lock..." >&2\nexec sleep 30\n')
        b.BOOTC_STATUS_TIMEOUT=1
        with self.assertRaisesRegex(ValueError,r'did not answer within 1s \(bootc: Waiting for sysroot lock\.\.\.\)'):
            b.bootc_status()

    def test_failing_or_silent_bootc_is_a_refusal(self):
        self.bootc('echo "error: Not booted into a bootc deployment" >&2\nexit 1\n')
        with self.assertRaisesRegex(ValueError,'exited 1 \\(bootc: error: Not booted'):b.bootc_status()
        self.bootc('echo "Waiting for sysroot lock..."\n')
        with self.assertRaisesRegex(ValueError,'no JSON document'):b.bootc_status()

    def test_only_bootc_status_gets_the_long_bound(self):
        seen=[]
        def fake(args,**kw):
            seen.append((args,kw['timeout']))
            return subprocess.CompletedProcess(args,0,'{}','')
        with mock.patch.object(b.subprocess,'run',fake):
            b.command('bootc','status','--json');b.command('blkid','-s','UUID','-o','value','/dev/vda3')
        self.assertEqual(seen,[(('bootc','status','--json'),b.BOOTC_STATUS_TIMEOUT),
                               (('blkid','-s','UUID','-o','value','/dev/vda3'),30)])
        self.assertGreaterEqual(b.BOOTC_STATUS_TIMEOUT,600)

    def test_controller_refusal_names_the_unanswered_status(self):
        case=BootIdentityTests('test_fresh_positive_identity_includes_observed_ancestry_and_bootid')
        case.setUp();self.addCleanup(case.tearDown)
        original=case.command
        def blocked(*args):
            if args==('bootc','status','--json'):
                raise subprocess.TimeoutExpired(args,900,stderr='Waiting for sysroot lock...\n')
            return original(*args)
        case.command=blocked
        with self.assertRaisesRegex(ValueError,'^cannot measure installed bootc deployment: bootc status did not '
                                    'answer within 900s \\(bootc: Waiting for sysroot lock...\\)$'):case.observe()

    def test_booted_image_reads_the_v1_schema_strictly(self):
        self.assertEqual(b.booted_image(STABLE_STATUS),('ghcr.io/projectbluefin/bluefin:stable',STABLE_DIGEST))
        for name,mutate in (
                ('not booted',lambda s:s['status'].update(booted=None)),
                ('no image',lambda s:s['status']['booted'].update(image=None)),
                ('no digest',lambda s:s['status']['booted']['image'].pop('imageDigest')),
                ('bad digest',lambda s:s['status']['booted']['image'].update(imageDigest='sha256:xyz')),
                ('empty ref',lambda s:s['status']['booted']['image']['image'].update(image='')),
                ('no status',lambda s:s.pop('status'))):
            with self.subTest(name):
                status=json.loads(json.dumps(STABLE_STATUS));mutate(status)
                with self.assertRaises(ValueError):b.booted_image(status)

    def test_collector_reads_bootc_through_the_same_helpers(self):
        import wootc_firstboot_evidence as f
        self.assertIs(f.booted_image,b.booted_image);self.assertIs(f.bootc_status,b.bootc_status)


if __name__=='__main__':unittest.main()
