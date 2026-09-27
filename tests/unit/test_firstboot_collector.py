#!/usr/bin/env python3
"""Real binary EFI fixtures and mounted-device identities; no success proxies."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('collector', ROOT / 'payload/migration/wootc-collect-firstboot.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
GUID = '12345678-1234-5678-abcd-123456789abc'
LOADER = '\\EFI\\fedora\\shimx64.efi'
UUID = '1234567890ABCDEF'


def option(loader=LOADER, guid=GUID):
    hd = struct.pack('<BBHIQQ', 4, 1, 42, 1, 2048, 100000) + uuid.UUID(guid).bytes_le + bytes([2, 2])
    path = (loader + '\0').encode('utf-16-le')
    file = struct.pack('<BBH', 4, 4, 4 + len(path)) + path
    nodes = hd + file + bytes([0x7f, 0xff, 4, 0])
    return bytes(4) + struct.pack('<IH', 1, len(nodes)) + 'Linux\0'.encode('utf-16-le') + nodes


class FirstbootCollector(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.host, self.proc, self.sys, self.etc = [self.base / p for p in ('host', 'proc', 'sys', 'etc')]
        for directory in (self.host / 'wootc/install', self.proc / 'self', self.sys / 'firmware/efi/efivars',
                          self.sys / 'devices/loop0/loop', self.sys / 'devices/loop0/loop0p3',
                          self.sys / 'dev/block', self.etc / 'wootc', self.host / 'wootc/disks',
                          self.host / 'Users/alice/Documents'):
            directory.mkdir(parents=True, exist_ok=True)
        self.plan = {'schemaVersion': 1, 'installationId': 'a' * 32,
                     'armedAt': '2026-01-01T00:00:00Z', 'imageRef': 'ghcr.io/tuna-os/yellowfin:gnome',
                     'espPartitionGuid': GUID, 'loaderPath': LOADER, 'hostUuid': UUID,
                     'rootDiskPath': '/wootc/disks/root.disk'}
        self.write_plan()
        self.efi = self.sys / 'firmware/efi/efivars'
        (self.efi / ('BootCurrent-' + c.EFI_GUID)).write_bytes(bytes(4) + struct.pack('<H', 4))
        self.boot_option = self.efi / ('Boot0004-' + c.EFI_GUID)
        self.boot_option.write_bytes(option())
        self.secure = self.efi / ('SecureBoot-' + c.EFI_GUID)
        self.secure.write_bytes(bytes(4) + bytes([1]))
        (self.proc / 'uptime').write_text('1000.00 0.00\n')
        (self.proc / 'cmdline').write_text('loop=/wootc/disks/root.disk wootc.host_uuid=' + UUID)
        (self.proc / 'self/mountinfo').write_text(
            f'1 0 8:2 / {self.host} rw - ntfs3 /dev/vda3 rw\n'
            '2 0 7:3 / /sysroot rw - xfs /dev/loop0p3 rw\n'
            '3 0 8:2 /Users/alice/Documents /var/home/alice/Documents rw - ntfs3 /dev/vda3 rw\n')
        (self.sys / 'devices/loop0/loop0p3/partition').write_text('3')
        (self.sys / 'dev/block/7:3').symlink_to(self.sys / 'devices/loop0/loop0p3')
        self.backing = self.sys / 'devices/loop0/loop/backing_file'
        self.backing.write_text(str(self.host) + '/wootc/disks/root.disk\n')
        (self.host / 'wootc/disks/root.disk').write_bytes(bytes(8))
        (self.etc / 'wootc/host-esp.conf').write_text('SOURCE_IMAGE_REF=' + self.plan['imageRef'] + '\n')
        (self.etc / 'wootc/installed-image-ref').write_text(self.plan['imageRef'] + '\n')
        (self.etc / 'passwd').write_text('alice:x:1000:1000::/var/home/alice:/bin/bash\n')
        self.digest = 'sha256:' + 'a' * 64
        self.status = {'status': {'booted': {'image': {'image': {'image': self.plan['imageRef']},
                                                      'imageDigest': self.digest}}}}
        self.uuid = UUID
        self.efibootmgr = 'BootCurrent: 0004\nBoot0004* Fedora HD(1,GPT,' + GUID + ',0x800,0x32000)/File(' + LOADER + ')\n'
        self.failed = ''
        self.unit_result = 'ActiveState=active\nSubState=exited\nResult=success\n'

    def write_plan(self):
        (self.host / 'wootc/install/installation.json').write_text(json.dumps(self.plan))

    def run_command(self, *args):
        if args[0] == 'efibootmgr':
            self.assertEqual(args, ('efibootmgr', '-v'))
            return self.efibootmgr
        if args[0] == 'blkid':
            self.assertEqual(args[-1], '/dev/vda3')
            return self.uuid + '\n'
        if args[0] == 'bootc':
            self.assertEqual(args, ('bootc', 'status', '--json'))
            return json.dumps(self.status)
        if args[0] == 'cryptsetup':
            self.assertEqual(args, ('cryptsetup', 'status', '/dev/mapper/wootc-bitlk-42'))
            return '  type: BITLK\n'
        if args[0] == 'systemctl':
            if args[1] == 'show':
                return self.unit_result
            return self.failed
        self.fail('unexpected probe: ' + str(args))

    def collect(self):
        return c.collect(self.host, self.proc, self.sys, self.etc, self.run_command)

    def test_actual_boot_record(self):
        record = self.collect()
        self.assertEqual(record['bootCurrent'], {'bootNumber': '0004', 'espPartitionGuid': GUID,
                                                 'loaderPath': LOADER})
        self.assertEqual(record['installationId'], self.plan['installationId'])
        self.assertEqual(record['rootDisk'], {'path': '/wootc/disks/root.disk', 'hostUuid': UUID})
        self.assertEqual(record['imageDigest'], self.digest)
        self.assertEqual(record['bridge']['boundFolders'], 1)
        self.assertEqual(record['bridge']['matchedUsers'], 1)
        self.assertEqual(record['bridge']['matchedProfiles'], [{'windowsProfile': 'alice',
            'linuxUser': 'alice', 'profileRoot': str(self.host / 'Users/alice')}])
        self.assertEqual(record['bridge']['bindings'][0]['target'], '/var/home/alice/Documents')
        self.assertTrue(record['secureBoot'])
        self.assertFalse(record['bridge']['bitlockerUnlocked'])

    def test_bitlocker_summary_requires_actual_unlocked_mount(self):
        mountinfo = self.proc / 'self/mountinfo'
        mountinfo.write_text(mountinfo.read_text() +
            '4 0 253:1 / /run/wootc/bitlk-tmp ro - ntfs3 /dev/mapper/wootc-bitlk-42 ro\n'
            '5 0 253:1 /Users/alice/Pictures /var/home/alice/Pictures ro - ntfs3 /dev/mapper/wootc-bitlk-42 ro\n')
        result = self.collect()
        self.assertTrue(result['bridge']['bitlockerUnlocked'])
        self.assertEqual(result['bridge']['boundFolders'], 2)

    def test_current_boot_must_follow_installation_attempt(self):
        self.plan['armedAt'] = c.datetime.datetime.now(c.datetime.timezone.utc).isoformat()
        self.write_plan()
        with self.assertRaisesRegex(ValueError, 'boot predates'):
            self.collect()

    def test_missing_boot_option_uses_complete_efibootmgr_fallback(self):
        self.boot_option.unlink()
        result = self.collect()
        self.assertEqual(result['bootCurrent']['espPartitionGuid'], GUID)
        self.assertTrue(result['secureBoot'])

    def test_missing_bootcurrent_uses_complete_efibootmgr_fallback(self):
        (self.efi / ('BootCurrent-' + c.EFI_GUID)).unlink()
        self.assertEqual(self.collect()['bootCurrent']['loaderPath'], LOADER)

    def test_malformed_available_efi_never_falls_back(self):
        self.boot_option.write_bytes(option()[:-1])
        with self.assertRaisesRegex(ValueError, 'truncated'):
            self.collect()

    def test_efibootmgr_fallback_refuses_incomplete_or_ambiguous_paths(self):
        self.boot_option.unlink()
        valid = self.efibootmgr
        for output in (valid.replace('BootCurrent: 0004', 'BootCurrent: 0005'),
                       valid.replace(',GPT,', ',MBR,'), valid[:-3],
                       valid + valid, valid.replace('/File(', '/HD(1,GPT,' + GUID + ',1,2)/File('),
                       valid.replace('/File(', '/File(\\EFI\\other.efi)/File(')):
            self.efibootmgr = output
            with self.subTest(output=output), self.assertRaises(ValueError):
                self.collect()

    def test_fallback_never_guesses_secure_boot(self):
        self.boot_option.unlink()
        self.secure.unlink()
        with self.assertRaises(FileNotFoundError):
            self.collect()

    def test_binary_guid_endianness_and_unicode_path(self):
        record = c.decode_boot_option(option('\\EFI\\tünä\\shimx64.efi'))
        self.assertEqual(record['espPartitionGuid'], GUID)
        self.assertEqual(record['loaderPath'], '\\EFI\\tünä\\shimx64.efi')

    def test_every_truncated_device_path_refused(self):
        data = option()
        for size in range(len(data)):
            with self.subTest(size=size), self.assertRaises((ValueError, UnicodeDecodeError)):
                c.decode_boot_option(data[:size])

    def test_invalid_node_and_ambiguous_identity_refused(self):
        data = bytearray(option())
        # Header is 10 bytes followed by UTF-16 description (12 bytes).
        for length in (0, 3, 65535):
            broken = bytearray(data)
            struct.pack_into('<H', broken, 24, length)
            with self.subTest(length=length), self.assertRaises(ValueError):
                c.decode_boot_option(broken)
        for loader, guid in (('\\EFI\\Microsoft\\Boot\\bootmgfw.efi', GUID),
                             (LOADER, '22345678-1234-5678-abcd-123456789abc')):
            self.boot_option.write_bytes(option(loader, guid))
            with self.subTest(loader=loader, guid=guid), self.assertRaisesRegex(ValueError, 'BootCurrent'):
                self.collect()

    def test_no_plan_no_evidence(self):
        (self.host / 'wootc/install/installation.json').unlink()
        with self.assertRaises(FileNotFoundError):
            self.collect()

    def test_mounted_host_uuid_cannot_be_replaced_by_cmdline(self):
        self.uuid = '1111111111111111'
        with self.assertRaisesRegex(ValueError, 'mounted NTFS UUID'):
            self.collect()

    def test_wrong_loop_backing_file_refused(self):
        self.backing.write_text(str(self.host) + '/wootc/disks/other.disk')
        with self.assertRaisesRegex(ValueError, 'not this root.disk'):
            self.collect()

    def test_missing_or_duplicate_cmdline_refused(self):
        for cmdline in ('wootc.host_uuid=' + UUID,
                        'loop=/wootc/disks/root.disk loop=/wootc/disks/root.disk wootc.host_uuid=' + UUID):
            (self.proc / 'cmdline').write_text(cmdline)
            with self.subTest(cmdline=cmdline), self.assertRaisesRegex(ValueError, 'kernel argument'):
                self.collect()

    def test_missing_digest_or_booted_image_refused(self):
        for booted in (None, {}, {'image': {'image': {'image': 'x'}, 'imageDigest': 'sha256:bad'}}):
            self.status['status']['booted'] = booted
            with self.subTest(booted=booted), self.assertRaises((ValueError, KeyError, TypeError)):
                self.collect()

    def test_source_image_mismatch_refused(self):
        self.plan['imageRef'] = 'ghcr.io/another/image:latest'
        self.write_plan()
        with self.assertRaisesRegex(ValueError, 'source image'):
            self.collect()

    def test_unrelated_actual_image_refused(self):
        self.status['status']['booted']['image']['image']['image'] = 'ghcr.io/another/image:latest'
        with self.assertRaisesRegex(ValueError, 'booted image'):
            self.collect()

    def test_derived_image_has_separate_source_and_actual_identity(self):
        derived = 'localhost/wootc-ntfs-injected:trial'
        (self.etc / 'wootc/installed-image-ref').write_text(derived)
        self.status['status']['booted']['image']['image']['image'] = derived
        result = self.collect()
        self.assertEqual(result['image'], derived)
        self.assertEqual(result['sourceImageRef'], self.plan['imageRef'])

    def test_pinned_digest_cannot_be_replaced(self):
        image = self.plan['imageRef'].split(':')[0] + '@sha256:' + 'b' * 64
        (self.etc / 'wootc/installed-image-ref').write_text(image)
        self.status['status']['booted']['image']['image']['image'] = image
        with self.assertRaisesRegex(ValueError, 'pinned install'):
            self.collect()

    def test_luks_root_follows_real_device_mapper_ancestry(self):
        dm = self.sys / 'devices/dm-0'
        (dm / 'slaves').mkdir(parents=True)
        (dm / 'slaves/loop0p3').symlink_to(self.sys / 'devices/loop0/loop0p3')
        (self.sys / 'dev/block/7:3').unlink()
        (self.sys / 'dev/block/7:3').symlink_to(dm)
        self.assertEqual(self.collect()['rootDisk']['hostUuid'], UUID)

    def test_secure_boot_malformed_refused(self):
        for data in (bytes(4), bytes(4) + bytes([2]), bytes(6)):
            self.secure.write_bytes(data)
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.collect()

    def test_bridge_that_never_ran_is_not_healthy(self):
        self.unit_result = 'ActiveState=inactive\nSubState=dead\nResult=success\n'
        with self.assertRaisesRegex(ValueError, 'did not complete'):
            self.collect()

    def test_failed_bridge_is_not_healthy(self):
        self.failed = 'wootc-passthrough.service loaded failed failed Bind profiles\n'
        with self.assertRaisesRegex(ValueError, 'failed units'):
            self.collect()

    def test_failed_unrelated_units_prevent_healthy(self):
        self.failed = 'unrelated.service loaded failed failed Other service\n'
        with self.assertRaisesRegex(ValueError, 'unrelated.service'):
            self.collect()


class PublicSummary(unittest.TestCase):
    def test_private_fields_are_never_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / 'summary'
            evidence = Path(tmp) / 'evidence.json'
            record = {'kernel': '6.1', 'sourceImageRef': 'example/image:tag', 'imageDigest': 'sha256:' + 'a' * 64,
                      'writtenAt': '2026-09-27T00:00:00Z', 'installationId': 'private-attempt',
                      'rootDisk': {'hostUuid': 'PRIVATE-UUID'},
                      'bridge': {'boundFolders': 1, 'matchedUsers': 1,
                                 'bindings': [{'source': 'private-profile'}]}}
            evidence.write_text(json.dumps(record))
            c.publish_summary(evidence, directory)
            summary = directory / 'installed-linux-boot-summary.json'
            self.assertEqual(summary.stat().st_mode & 0o777, 0o644)
            self.assertEqual(set(json.loads(summary.read_text())),
                {'kernel', 'sourceImageRef', 'imageDigest', 'writtenAt', 'boundFolders', 'matchedUsers'})
            self.assertNotIn('PRIVATE', summary.read_text())
            self.assertNotIn('private-profile', summary.read_text())

    def test_summary_refuses_untrusted_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / 'summary'
            directory.mkdir()
            directory.chmod(0o777)
            evidence = Path(tmp) / 'evidence.json'
            evidence.write_text(json.dumps({'kernel': '6', 'sourceImageRef': 'image', 'imageDigest': 'digest',
                'writtenAt': 'date', 'bridge': {'boundFolders': 0, 'matchedUsers': 0}}))
            with self.assertRaisesRegex(ValueError, 'not writable'):
                c.publish_summary(evidence, directory)
            self.assertFalse((directory / 'installed-linux-boot-summary.json').exists())


if __name__ == '__main__':
    unittest.main()
