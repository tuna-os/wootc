#!/usr/bin/env python3
"""First-boot evidence collector: every field measured, refusals stay refusals."""
import datetime
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'payload/migration/lib'))
import wootc_firstboot_evidence as f  # noqa: E402
from wootc_boot_identity import EFI_GUID  # noqa: E402

GUID = '12345678-1234-5678-abcd-123456789abc'
BOOT_ID = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0'
LOADER = '\\EFI\\fedora\\shimx64.efi'
HOST_UUID = '1234567890ABCDEF'
DIGEST = 'sha256:' + 'a' * 64


def option(guid=GUID, loader=LOADER):
    hd = struct.pack('<BBHIQQ', 4, 1, 42, 1, 2048, 100000) + uuid.UUID(guid).bytes_le + bytes([2, 2])
    name = (loader + '\0').encode('utf-16-le')
    nodes = hd + struct.pack('<BBH', 4, 4, 4 + len(name)) + name + bytes([127, 255, 4, 0])
    return bytes(4) + struct.pack('<IH', 1, len(nodes)) + 'Linux\0'.encode('utf-16-le') + nodes


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.host, self.proc, self.sys, self.etc = [self.root / x for x in ('host', 'proc', 'sys', 'etc')]
        for p in (self.host / 'wootc/disks', self.proc / 'self', self.proc / 'sys/kernel/random',
                  self.sys / 'firmware/efi/efivars', self.sys / 'block/loop0/loop', self.sys / 'block/loop1/loop',
                  self.etc / 'wootc', self.host / 'Users/alice/Documents'):
            p.mkdir(parents=True)
        self.disk = self.host / 'wootc/disks/root.disk'
        self.disk.write_bytes(b'root disk')
        (self.host / 'wootc/disks/other.disk').write_bytes(b'not this one')
        (self.proc / 'cmdline').write_text('ro loop=/wootc/disks/root.disk wootc.host_uuid=1234567890abcdef quiet\n')
        (self.proc / 'sys/kernel/random/boot_id').write_text(BOOT_ID + '\n')
        (self.proc / 'sys/kernel/osrelease').write_text('6.12.0-55.el10.x86_64\n')
        self.mounts = [
            f'1 0 8:3 / {self.host} rw - ntfs3 /dev/vda3 rw',
            '2 0 8:3 /Users/alice/Documents /var/home/alice/Documents rw - ntfs3 /dev/vda3 rw',
            '3 0 8:3 /Users/alice/Documents /home/alice/Documents rw - ntfs3 /dev/vda3 rw',
            '4 0 8:3 /Users/alice/Pictures /var/home/alice/Pictures rw - ntfs3 /dev/vda3 rw',
            '5 0 8:3 /Users/bob/Music /var/home/bob/Music rw - ntfs3 /dev/vda3 rw',
            '6 0 0:44 / /var/home/carol/Documents rw - tmpfs tmpfs rw',
        ]
        self.write_mounts()
        (self.sys / 'block/loop0/loop/backing_file').write_text(str(self.host / 'wootc/disks/other.disk') + '\n')
        (self.sys / 'block/loop1/loop/backing_file').write_text(str(self.disk) + '\n')
        self.efi = self.sys / 'firmware/efi/efivars'
        (self.efi / ('BootCurrent-' + EFI_GUID)).write_bytes(bytes(4) + struct.pack('<H', 4))
        (self.efi / ('Boot0004-' + EFI_GUID)).write_bytes(option())
        (self.efi / ('SecureBoot-' + EFI_GUID)).write_bytes(bytes(4) + b'\1')
        (self.etc / 'wootc/host-esp.conf').write_text('HOST_ESP_UUID=1234-5678\nSOURCE_IMAGE_REF=ghcr.io/projectbluefin/bluefin:lts\n')
        self.status = {'status': {'booted': {'image': {'image': {'image': 'localhost/wootc-ntfs-injected:latest'},
                                                       'imageDigest': DIGEST}}}}
        self.host_uuid = HOST_UUID
        self.failed = 'bad.service loaded failed failed Bad\n'
        self.efibootmgr = None

    def tearDown(self):
        self.temp.cleanup()

    def write_mounts(self):
        (self.proc / 'self/mountinfo').write_text('\n'.join(self.mounts) + '\n')

    def run_command(self, *args):
        if args == ('bootc', 'status', '--json'):
            if self.status is None:
                raise FileNotFoundError('bootc')
            return json.dumps(self.status)
        if args[0] == 'blkid':
            self.assertEqual(args[-1], '/dev/vda3')
            return self.host_uuid + '\n'
        if args[0] == 'systemctl':
            return self.failed
        if args == ('efibootmgr', '-v'):
            if self.efibootmgr is None:
                raise subprocess.CalledProcessError(1, args)
            return self.efibootmgr
        raise AssertionError(args)

    def collect(self):
        return f.collect(self.host, self.proc, self.sys, self.etc, self.run_command,
                         datetime.datetime(2026, 10, 17, 5, 0, tzinfo=datetime.timezone.utc))

    def test_complete_record_is_measured_from_the_running_boot(self):
        record = self.collect()
        self.assertEqual(record['schema'], 1)
        self.assertEqual(record['state'], 'healthy')
        self.assertEqual(record['sequence'], 1)
        self.assertEqual(record['bootId'], BOOT_ID)
        self.assertEqual(record['kernel'], '6.12.0-55.el10.x86_64')
        self.assertEqual(record['image'], {'ref': 'localhost/wootc-ntfs-injected:latest', 'digest': DIGEST,
                                           'sourceRef': 'ghcr.io/projectbluefin/bluefin:lts'})
        self.assertEqual(record['bootCurrent'], {'bootNumber': '0004', 'source': 'efivarfs',
                                                 'espPartitionGuid': GUID, 'loaderPath': LOADER})
        self.assertEqual(record['rootDisk'], {'path': '/wootc/disks/root.disk', 'hostUuid': HOST_UUID})
        # /home/alice/Documents and /var/home/alice/Documents are one folder;
        # carol's tmpfs is not the Windows volume.
        self.assertEqual(record['bridge'], {'boundFolders': 3, 'matchedUsers': 2, 'bitlockerUnlocked': False})
        self.assertTrue(record['secureBoot'])
        self.assertEqual(record['failedUnits'], ['bad.service'])
        self.assertEqual(record['writtenAt'], '2026-10-17T05:00:00Z')
        self.assertEqual(record['updatedBy'], 'wootc-firstboot')

    def test_phase2_grub_entry_repeats_the_root_disk_arguments(self):
        # E2E 38996488933 (bluefin:lts): the Phase-2 grub.cfg line is
        # ${ROOT_OPTIONS} (BLS options, already carrying both arguments) plus
        # loop= and wootc.host_uuid= again (deploy.sh). The collector refused
        # it as a duplicate and the first boot never reported healthy.
        (self.proc / 'cmdline').write_text(
            'BOOT_IMAGE=(hd0,gpt1)/EFI/wootc/phase2-vmlinuz root=UUID=0b3c rw '
            'ostree=/ostree/boot.1/default/abc/0 wootc.host_uuid=1234567890ABCDEF '
            'loop=/wootc/disks/root.disk loop=/wootc/disks/root.disk '
            'wootc.host_uuid=1234567890ABCDEF console=tty1 console=ttyS0,115200\n')
        self.assertEqual(self.collect()['rootDisk'], {'path': '/wootc/disks/root.disk', 'hostUuid': HOST_UUID})

    def test_fuse_ntfs_host_mount_is_accepted(self):
        self.mounts[0] = f'1 0 0:52 / {self.host} rw - fuseblk.lowntfs-3g /dev/vda3 rw'
        self.write_mounts()
        self.assertEqual(self.collect()['rootDisk']['hostUuid'], HOST_UUID)

    def test_bitlocker_profiles_count_as_bridged(self):
        self.mounts += ['7 0 253:0 / /run/wootc/bitlk-tmp ro - ntfs3 /dev/mapper/bitlk rw',
                        '8 0 253:0 /Users/dana/Documents /var/home/dana/Documents rw - ntfs3 /dev/mapper/bitlk rw']
        self.write_mounts()
        self.assertEqual(self.collect()['bridge'], {'boundFolders': 4, 'matchedUsers': 3, 'bitlockerUnlocked': True})

    def test_undecodable_boot_option_falls_back_then_reports_unavailable(self):
        (self.efi / ('Boot0004-' + EFI_GUID)).write_bytes(b'\0' * 8)
        self.efibootmgr = 'BootCurrent: 0004\nBoot0004* Linux HD(1,GPT,' + GUID + ',0x800,0x32000)/File(' + LOADER + ')\n'
        self.assertEqual(self.collect()['bootCurrent']['source'], 'efibootmgr')
        self.efibootmgr = None
        self.assertEqual(self.collect()['bootCurrent'], {'source': 'unavailable', 'bootNumber': '0004'})

    def test_missing_secure_boot_variable_is_off(self):
        (self.efi / ('SecureBoot-' + EFI_GUID)).unlink()
        self.assertFalse(self.collect()['secureBoot'])

    def test_refusals(self):
        cases = {
            'host UUID differs': lambda: setattr(self, 'host_uuid', 'FEDCBA0987654321'),
            'root.disk not attached': lambda: (self.sys / 'block/loop1/loop/backing_file').write_text('/nowhere\n'),
            'root.disk missing': lambda: self.disk.unlink(),
            'wrong loop path': lambda: (self.proc / 'cmdline').write_text('loop=/wootc/disks/x.disk wootc.host_uuid=1234567890ABCDEF'),
            'conflicting host uuid': lambda: (self.proc / 'cmdline').write_text('loop=/wootc/disks/root.disk wootc.host_uuid=1234567890ABCDEF wootc.host_uuid=FEDCBA0987654321'),
            'conflicting loop': lambda: (self.proc / 'cmdline').write_text('loop=/wootc/disks/root.disk loop=/wootc/disks/x.disk wootc.host_uuid=1234567890ABCDEF'),
            'missing loop': lambda: (self.proc / 'cmdline').write_text('wootc.host_uuid=1234567890ABCDEF'),
            'no bootc': lambda: setattr(self, 'status', None),
            'no digest': lambda: self.status['status']['booted']['image'].pop('imageDigest'),
            'bad digest': lambda: self.status['status']['booted']['image'].update(imageDigest='sha256:xyz'),
            'bad boot id': lambda: (self.proc / 'sys/kernel/random/boot_id').write_text('not-a-uuid'),
            'host not NTFS': lambda: (self.mounts.__setitem__(0, f'1 0 8:3 / {self.host} rw - ext4 /dev/vda3 rw'), self.write_mounts()),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                self.tearDown()
                self.setUp()
                mutate()
                with self.assertRaises((ValueError, OSError)):
                    self.collect()

    def test_cli_prints_json_or_fails_without_output(self):
        script = ROOT / 'payload/migration/lib/wootc_firstboot_evidence.py'
        result = subprocess.run([sys.executable, '-I', str(script), '--host', str(self.root / 'absent'),
                                 '--proc', str(self.proc), '--sys', str(self.sys), '--etc', str(self.etc)],
                                capture_output=True, text=True, env=dict(os.environ, PATH='/nonexistent'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('first-boot evidence unavailable', result.stderr)


if __name__ == '__main__':
    unittest.main()
