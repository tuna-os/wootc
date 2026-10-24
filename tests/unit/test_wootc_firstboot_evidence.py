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
INSTALLATION_ID = '0123456789abcdef0123456789abcdef'
SOURCE = 'ghcr.io/projectbluefin/bluefin:lts'
INJECTED = 'localhost/wootc-ntfs-injected:latest'


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
                  self.sys / 'dev/block', self.etc / 'wootc', self.host / 'wootc/install',
                  self.host / 'Users/alice/Documents'):
            p.mkdir(parents=True)
        # What Windows staged for this attempt (app/boot_evidence.go).
        self.plan = {'schemaVersion': 1, 'installationId': INSTALLATION_ID, 'armedAt': '2026-10-17T04:00:00Z',
                     'imageRef': SOURCE, 'espPartitionGuid': GUID, 'loaderPath': LOADER,
                     'hostUuid': HOST_UUID, 'rootDiskPath': '/wootc/disks/root.disk'}
        self.write_plan()
        (self.proc / 'uptime').write_text('600.00 1100.00\n')
        (self.etc / 'wootc/installed-image-ref').write_text(INJECTED + '\n')
        (self.sys / 'dev/block/7:1').symlink_to('../../block/loop1')
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
            '9 0 7:1 / /sysroot ro - xfs /dev/loop1 ro',
        ]
        self.write_mounts()
        (self.sys / 'block/loop0/loop/backing_file').write_text(str(self.host / 'wootc/disks/other.disk') + '\n')
        (self.sys / 'block/loop1/loop/backing_file').write_text(str(self.disk) + '\n')
        (self.sys / 'block/loop0/size').write_text('1\n')
        (self.sys / 'block/loop1/size').write_text('1\n')
        self.efi = self.sys / 'firmware/efi/efivars'
        (self.efi / ('BootCurrent-' + EFI_GUID)).write_bytes(bytes(4) + struct.pack('<H', 4))
        (self.efi / ('Boot0004-' + EFI_GUID)).write_bytes(option())
        (self.efi / ('SecureBoot-' + EFI_GUID)).write_bytes(bytes(4) + b'\1')
        (self.etc / 'wootc/host-esp.conf').write_text('HOST_ESP_UUID=1234-5678\nSOURCE_IMAGE_REF=ghcr.io/projectbluefin/bluefin:lts\n')
        self.status = {'status': {'booted': {'image': {'image': {'image': 'localhost/wootc-ntfs-injected:latest'},
                                                       'imageDigest': DIGEST}}}}
        self.host_uuid = HOST_UUID
        self.failed = 'bad.service loaded failed failed Bad\n'
        self.units = {'wootc-host-bind.service': 'ActiveState=active\nSubState=exited\nResult=success\n',
                      'wootc-passthrough.service': 'ActiveState=active\nSubState=exited\nResult=success\n'}
        self.cryptsetup = 'type:    BITLK\ncipher:  aes-xts-plain64\n'
        self.efibootmgr = None

    def tearDown(self):
        self.temp.cleanup()

    def write_plan(self):
        (self.host / 'wootc/install/installation.json').write_text(json.dumps(self.plan))

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
        if args[:2] == ('systemctl', 'show'):
            return self.units[args[2]]
        if args[0] == 'systemctl':
            return self.failed
        if args[:2] == ('cryptsetup', 'status'):
            self.assertTrue(args[2].startswith('/dev/mapper/wootc-bitlk-'))
            return self.cryptsetup
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
        self.assertEqual(record['installationId'], INSTALLATION_ID)
        self.assertEqual(record['state'], 'healthy')
        self.assertEqual(record['sequence'], 1)
        self.assertEqual(record['bootId'], BOOT_ID)
        self.assertEqual(record['kernel'], '6.12.0-55.el10.x86_64')
        self.assertEqual(record['image'], {'ref': INJECTED, 'digest': DIGEST, 'sourceRef': SOURCE})
        self.assertEqual(record['bootCurrent'], {'bootNumber': '0004', 'source': 'efivarfs',
                                                 'espPartitionGuid': GUID, 'loaderPath': LOADER})
        self.assertEqual(record['rootDisk'], {'path': '/wootc/disks/root.disk', 'hostUuid': HOST_UUID})
        # /home/alice/Documents and /var/home/alice/Documents are one folder;
        # carol's tmpfs is not the Windows volume.
        self.assertEqual(record['bridge'], {'boundFolders': 3, 'matchedUsers': 2, 'bitlockerUnlocked': False, 'bindings': [
            {'source': f'{self.host}/Users/alice/Documents', 'target': '/home/alice/Documents', 'user': 'alice'},
            {'source': f'{self.host}/Users/alice/Pictures', 'target': '/home/alice/Pictures', 'user': 'alice'},
            {'source': f'{self.host}/Users/bob/Music', 'target': '/home/bob/Music', 'user': 'bob'}]})
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

    def test_initramfs_backing_path_that_does_not_resolve_in_the_real_root(self):
        # E2E 38999840752 (bluefin:lts, fuse-ntfs-3g): root.disk was attached
        # by the initramfs, and the backing path it reports did not lead to
        # this root.disk from the real root. Path suffix plus size identify it.
        self.disk.write_bytes(b'\0' * 4096)
        (self.sys / 'block/loop1/loop/backing_file').write_text('/run/initramfs/wootc-host/wootc/disks/root.disk\n')
        (self.sys / 'block/loop1/size').write_text('8\n')
        self.assertEqual(self.collect()['rootDisk']['path'], '/wootc/disks/root.disk')
        # Another file of another size under that name is not this root.disk.
        (self.sys / 'block/loop1/size').write_text('16\n')
        with self.assertRaisesRegex(ValueError, 'loop backing files: loop0=.*loop1=/run/initramfs'):
            self.collect()
        # Nor is a deleted file.
        (self.sys / 'block/loop1/size').write_text('8\n')
        (self.sys / 'block/loop1/loop/backing_file').write_text('/run/initramfs/wootc-host/wootc/disks/root.disk (deleted)\n')
        with self.assertRaises(ValueError):
            self.collect()

    def test_fuse_ntfs_host_mount_is_accepted(self):
        self.mounts[0] = f'1 0 0:52 / {self.host} rw - fuseblk.lowntfs-3g /dev/vda3 rw'
        self.write_mounts()
        self.assertEqual(self.collect()['rootDisk']['hostUuid'], HOST_UUID)

    def test_bitlocker_profiles_count_as_bridged(self):
        self.mounts += ['7 0 253:0 / /run/wootc/bitlk-tmp ro - ntfs3 /dev/mapper/wootc-bitlk-42 rw',
                        '8 0 253:0 /Users/dana/Pictures /var/home/dana/Pictures rw - ntfs3 /dev/mapper/wootc-bitlk-42 rw']
        self.write_mounts()
        bridge = self.collect()['bridge']
        self.assertEqual((bridge['boundFolders'], bridge['matchedUsers'], bridge['bitlockerUnlocked']), (4, 3, True))
        self.assertIn({'source': '/run/wootc/bitlk-tmp/Users/dana/Pictures', 'target': '/home/dana/Pictures',
                       'user': 'dana'}, bridge['bindings'])

    def test_bitlocker_unlock_is_the_bridge_mapping_of_an_actual_bitlk_volume(self):
        self.mounts.append('7 0 253:0 / /run/wootc/bitlk-tmp ro - ntfs3 /dev/mapper/wootc-bitlk-42 rw')
        self.write_mounts()
        self.assertTrue(self.collect()['bridge']['bitlockerUnlocked'])
        # A LUKS or plain mapping mounted there is not an unlocked C:.
        self.cryptsetup = 'type:    LUKS2\n'
        with self.assertRaisesRegex(ValueError, 'not an unlocked BitLocker volume'):
            self.collect()
        # Nor is anything that is not the bridge's own mapping.
        self.mounts[-1] = '7 0 253:0 / /run/wootc/bitlk-tmp ro - ntfs3 /dev/mapper/other rw'
        self.write_mounts()
        with self.assertRaisesRegex(ValueError, 'unexpected BitLocker profile source'):
            self.collect()

    def test_bridge_never_exposes_the_volume_or_installer_records(self):
        for root in ('/', '/wootc/install', '/WOOTC'):
            with self.subTest(root=root):
                self.tearDown()
                self.setUp()
                self.mounts.append(f'10 0 8:3 {root} /var/home/alice/Desktop rw - ntfs3 /dev/vda3 rw')
                self.write_mounts()
                with self.assertRaisesRegex(ValueError, 'bridge exposes'):
                    self.collect()

    def test_a_profile_named_wootc_is_an_ordinary_profile(self):
        self.mounts.append('10 0 8:3 /Users/wootc/Documents /var/home/wootc/Documents rw - ntfs3 /dev/vda3 rw')
        self.write_mounts()
        self.assertIn({'source': f'{self.host}/Users/wootc/Documents', 'target': '/home/wootc/Documents',
                       'user': 'wootc'}, self.collect()['bridge']['bindings'])

    def test_bridge_units_must_have_completed(self):
        for unit in ('wootc-host-bind.service', 'wootc-passthrough.service'):
            for state in ('ActiveState=failed\nSubState=failed\nResult=exit-code\n',
                          'ActiveState=inactive\nSubState=dead\nResult=success\n'):
                with self.subTest(unit=unit, state=state):
                    self.tearDown()
                    self.setUp()
                    self.units[unit] = state
                    with self.assertRaisesRegex(ValueError, 'did not complete: ' + unit):
                        self.collect()

    def test_record_is_bound_to_this_installation_attempt(self):
        cases = {
            'missing installation identity': lambda: (self.host / 'wootc/install/installation.json').unlink(),
            'missing installation identity ': lambda: (self.plan.update(installationId='XYZ'), self.write_plan()),
            'armed in the future': lambda: (self.plan.update(armedAt='2026-10-17T06:00:00Z'), self.write_plan()),
            'predates this installation': lambda: (self.proc / 'uptime').write_text('7200.00 1.00\n'),
            'root.disk kernel argument does not match': lambda: (self.plan.update(rootDiskPath='/wootc/disks/x.disk'), self.write_plan()),
            'host UUID kernel argument does not match': lambda: (self.plan.update(hostUuid='FEDCBA0987654321'), self.write_plan()),
            'source image does not match': lambda: (self.plan.update(imageRef='ghcr.io/ublue-os/aurora:stable'), self.write_plan()),
            'BootCurrent does not match': lambda: (self.plan.update(espPartitionGuid='87654321-1234-5678-abcd-123456789abc'), self.write_plan()),
            'BootCurrent does not match ': lambda: (self.plan.update(loaderPath='\\EFI\\systemd\\shimx64.efi'), self.write_plan()),
            'booted image does not match installed image': lambda: (self.etc / 'wootc/installed-image-ref').write_text('ghcr.io/other/image:tag\n'),
            'missing installed image reference': lambda: (self.etc / 'wootc/installed-image-ref').unlink(),
            'booted image does not match installed image ': lambda: (self.etc / 'wootc/installed-image-ref').write_text(INJECTED + '@sha256:' + 'b' * 64 + '\n'),
            'pinned install ': lambda: (self.status['status']['booted']['image']['image'].update(image=INJECTED + '@sha256:' + 'b' * 64),
                                        (self.etc / 'wootc/installed-image-ref').write_text(INJECTED + '@sha256:' + 'b' * 64 + '\n')),
            'installed sysroot is not this root.disk': lambda: ((self.sys / 'dev/block/7:1').unlink(),
                                                                (self.sys / 'dev/block/7:1').symlink_to('../../block/loop0')),
            'missing installed sysroot mount': lambda: (self.mounts.pop(), self.write_mounts()),
        }
        for message, mutate in cases.items():
            with self.subTest(message):
                self.tearDown()
                self.setUp()
                mutate()
                with self.assertRaisesRegex(ValueError, message.strip()):
                    self.collect()

    def test_docker_transport_and_digest_pin_of_the_same_image_match(self):
        self.plan['imageRef'] = 'docker://' + SOURCE
        self.write_plan()
        (self.etc / 'wootc/installed-image-ref').write_text('docker://' + INJECTED + '@' + DIGEST + '\n')
        self.status['status']['booted']['image']['image']['image'] = INJECTED + '@' + DIGEST
        record = self.collect()
        self.assertEqual(record['image']['sourceRef'], SOURCE)

    def test_undecodable_boot_entry_is_reported_not_matched(self):
        # Windows does not gate on an entry the firmware would not let us
        # decode (boot_current); a decoded one must be the staged ESP/loader.
        (self.efi / ('Boot0004-' + EFI_GUID)).write_bytes(b'\0' * 8)
        self.plan['espPartitionGuid'] = '87654321-1234-5678-abcd-123456789abc'
        self.write_plan()
        self.assertEqual(self.collect()['bootCurrent'], {'source': 'unavailable', 'bootNumber': '0004'})

    def test_luks_sysroot_follows_device_mapper_ancestry(self):
        dm = self.sys / 'block/dm-0'
        (dm / 'slaves').mkdir(parents=True)
        (dm / 'slaves/loop1').symlink_to('../../loop1')
        (self.sys / 'dev/block/253:1').symlink_to('../../block/dm-0')
        self.mounts[-1] = '9 0 253:1 / /sysroot ro - xfs /dev/mapper/root ro'
        self.write_mounts()
        self.assertEqual(self.collect()['rootDisk']['path'], '/wootc/disks/root.disk')

    def test_summary_publishes_only_public_facts(self):
        record = self.collect()
        evidence = self.root / 'evidence.json'
        evidence.write_text(json.dumps(record))
        summary_dir = self.root / 'summary'
        f.publish_summary(evidence, summary_dir)
        summary = json.loads((summary_dir / 'installed-linux-boot-summary.json').read_text())
        self.assertEqual(summary, {'kernel': record['kernel'], 'sourceImageRef': SOURCE, 'imageDigest': DIGEST,
                                   'writtenAt': record['writtenAt'], 'boundFolders': 3, 'matchedUsers': 2})
        self.assertEqual((summary_dir / 'installed-linux-boot-summary.json').stat().st_mode & 0o777, 0o644)
        text = (summary_dir / 'installed-linux-boot-summary.json').read_text()
        for private in (INSTALLATION_ID, HOST_UUID, str(self.host), GUID):
            self.assertNotIn(private, text)

    def test_summary_refuses_an_untrusted_directory(self):
        evidence = self.root / 'evidence.json'
        evidence.write_text(json.dumps(self.collect()))
        summary_dir = self.root / 'summary'
        summary_dir.mkdir()
        summary_dir.chmod(0o777)
        with self.assertRaisesRegex(ValueError, 'not writable by other users'):
            f.publish_summary(evidence, summary_dir)
        self.assertFalse((summary_dir / 'installed-linux-boot-summary.json').exists())
        evidence.write_text(json.dumps({'state': 'deployed'}))
        summary_dir.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'not a first-boot evidence record'):
            f.publish_summary(evidence, summary_dir)

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
            'not booted': lambda: self.status['status'].update(booted=None),
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

    def test_bootc_blocked_on_the_sysroot_lock_refuses_and_says_why(self):
        # E2E 39874539856 (bluefin:stable): `bootc status` was still waiting
        # behind the first boot's `bootc image set-unified` when the bound ran
        # out, and the unit logged only "cannot measure the booted bootc image".
        original = self.run_command

        def blocked(*args):
            if args == ('bootc', 'status', '--json'):
                raise subprocess.TimeoutExpired(args, 900, stderr=b'Waiting for sysroot lock...\n')
            return original(*args)
        self.run_command = blocked
        with self.assertRaisesRegex(ValueError, r'^cannot measure the booted bootc image: bootc status did not '
                                    r'answer within 900s \(bootc: Waiting for sysroot lock\.\.\.\)$'):
            self.collect()

    def test_bootc_on_bluefin_stable_is_measured(self):
        self.status['status']['booted']['image'] = {
            'image': {'image': 'ghcr.io/projectbluefin/bluefin:stable', 'transport': 'registry'},
            'version': '44.20260917.0', 'imageDigest': DIGEST, 'architecture': 'amd64'}
        self.status['status']['booted']['store'] = 'ostreeContainer'
        (self.etc / 'wootc/installed-image-ref').write_text('ghcr.io/projectbluefin/bluefin:stable\n')
        self.assertEqual(self.collect()['image']['ref'], 'ghcr.io/projectbluefin/bluefin:stable')

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
