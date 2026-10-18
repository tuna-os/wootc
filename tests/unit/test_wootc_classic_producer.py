"""Producer guards run before image commands; no libguestfs/OS result is simulated."""
import copy
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/produce-classic.py'))
FILES = ('shimx64.efi', 'grubx64.efi', 'mmx64.efi')


class ProducerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        def entry(name):
            path = self.root/name; path.write_bytes(name.encode())
            return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        self.config = {'windowsBaseline': entry('windows.qcow2'), 'classicCloudImage': entry('classic.qcow2'),
                       'oldPackages': [entry('old.deb')], 'newPackages': [entry('new.deb')],
                       'oldTrio': {n: entry('old-'+n) for n in FILES},
                       'newTrio': {n: entry('new-'+n) for n in FILES}, 'windowsVolume': 'F:', 'osId': 'debian',
                       'verifierClosure': str(self.root/'no-closure'), 'firmwareVariables': str(self.root/'no-variables'),
                       'firmwareVariableHashes': {}, 'minimumFreeBytes': 20*1024**3}

    def tearDown(self):
        self.temporary.cleanup()

    def refused_before_commands(self, config):
        calls = []
        with self.assertRaises((ValueError, OSError)):
            MODULE['produce'](self.root, config, run=lambda *a, **k: calls.append(a))
        self.assertEqual(calls, [])
        self.assertEqual(list(self.root.glob('*/scratch.json')), [])

    def test_changed_cloud_source_refuses_before_images(self):
        Path(self.config['classicCloudImage']['path']).write_bytes(b'mutated')
        self.refused_before_commands(self.config)

    def test_incomplete_target_trio_refuses_before_images(self):
        del self.config['newTrio']['mmx64.efi']
        self.refused_before_commands(self.config)

    def test_windows_volume_cannot_default_or_escape(self):
        for value in ('', 'C:\\arbitrary', "F:'; bad"):
            with self.subTest(value=value):
                config = copy.deepcopy(self.config); config['windowsVolume'] = value
                self.refused_before_commands(config)

    def test_source_symlink_refuses_before_images(self):
        link = self.root/'alias.qcow2'; link.symlink_to(self.config['classicCloudImage']['path'])
        self.config['classicCloudImage']['path'] = str(link)
        self.refused_before_commands(self.config)

    def test_missing_real_verifier_cannot_be_skipped(self):
        self.refused_before_commands(self.config)

    def test_mutation_after_check_refuses_before_consumer(self):
        Path(self.config['classicCloudImage']['path']).write_bytes(b'changed after preflight')
        with self.assertRaisesRegex(ValueError, 'changed before freezing'):
            MODULE['freeze_inputs'](self.root, self.config)
        self.assertFalse(list(self.root.rglob('disk.qcow2')))

    def test_mid_copy_source_mutation_refuses(self):
        source = Path(self.config['classicCloudImage']['path'])
        original_copy = MODULE['shutil'].copyfileobj
        def copy_then_mutate(reader, writer):
            original_copy(reader, writer)
            source.write_bytes(b'mutated during copy')
        with patch.object(MODULE['shutil'], 'copyfileobj', copy_then_mutate):
            with self.assertRaisesRegex(ValueError, 'changed while freezing'):
                MODULE['freeze_file'](source, self.root/'frozen', self.config['classicCloudImage']['sha256'])
        self.assertFalse(list(self.root.rglob('disk.qcow2')))

    def test_consumers_use_exclusive_frozen_bytes(self):
        frozen = MODULE['freeze_inputs'](self.root, self.config)
        Path(self.config['classicCloudImage']['path']).write_bytes(b'changed after freeze')
        path = Path(frozen['classicCloudImage']['path'])
        self.assertEqual(path.read_bytes(), b'classic.qcow2')
        self.assertEqual(path.stat().st_mode & 0o777, 0o400)
        self.assertNotEqual(frozen['classicCloudImage']['path'], self.config['classicCloudImage']['path'])

    def test_package_mutation_refuses_before_guest_upgrade(self):
        upgrade = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/upgrade-classic.py'))['upgrade']
        import json
        (self.root/'packages.json').write_text(json.dumps({'manager': 'dpkg', 'newPackages': {'new.deb': '0'*64}}))
        calls = []
        with self.assertRaisesRegex(ValueError, 'package hash differs'):
            upgrade(self.root, run=lambda *a, **k: calls.append(a))
        self.assertEqual(calls, [])

    def metadata(self, changes=None, mutate=False):
        calls = []
        info = {'format': 'qcow2', 'virtual-size': 3*1024**3,
                'format-specific': {'type': 'qcow2', 'data': {}}}
        info.update(changes or {})
        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if mutate:
                Path(self.config['classicCloudImage']['path']).write_bytes(b'changed during info')
            return SimpleNamespace(stdout=json.dumps(info).encode())
        return run, calls

    def test_metadata_observation_is_read_only_and_bounded(self):
        run, calls = self.metadata()
        result = MODULE['image_contract'](self.config['classicCloudImage'], run)
        self.assertEqual(result['virtualBytes'], 3*1024**3)
        self.assertEqual(calls[0][0][1:4], ['info', '--output=json', '-f'])
        self.assertEqual(calls[0][1]['timeout'], 30)
        self.assertFalse(list(self.root.glob('producer-inputs-*')))

    def test_external_backing_and_data_file_refuse_before_copy(self):
        for change in ({'backing-filename': 'foreign.qcow2'}, {'full-backing-filename': '/foreign'},
                       {'data-file': '/foreign'}, {'format-specific': {'data': {'data-file': '/foreign'}}}):
            with self.subTest(change=change):
                run, _ = self.metadata(change)
                with self.assertRaisesRegex(ValueError, 'external image'):
                    MODULE['image_contract'](self.config['classicCloudImage'], run)
        self.assertFalse(list(self.root.glob('producer-inputs-*')))

    def test_image_metadata_source_change_refuses(self):
        run, _ = self.metadata(mutate=True)
        with self.assertRaisesRegex(ValueError, 'changed during metadata'):
            MODULE['image_contract'](self.config['classicCloudImage'], run)

    def test_invalid_metadata_cannot_supply_capacity(self):
        for change in ({'format': 'raw'}, {'virtual-size': True}, {'virtual-size': 0},
                       {'virtual-size': 1024**4+1}, {'format-specific': []}):
            with self.subTest(change=change):
                run, _ = self.metadata(change)
                with self.assertRaises(ValueError):
                    MODULE['image_contract'](self.config['classicCloudImage'], run)

    def test_capacity_uses_observed_virtual_size_and_all_frozen_sources(self):
        contracts = {'windowsBaseline': {'sourceBytes': 9*1024**3},
                     'classicCloudImage': {'sourceBytes': 1024**3, 'virtualBytes': 8*1024**3}}
        small = sum(Path(e['path']).stat().st_size for key in ('oldPackages', 'newPackages') for e in self.config[key])
        small += sum(Path(e['path']).stat().st_size for key in ('oldTrio', 'newTrio') for e in self.config[key].values())
        self.assertEqual(MODULE['required_space'](self.config, contracts, 123), 38*1024**3+small+123)

    def test_guest_capacity_unknown_is_not_free_space(self):
        for fields in ({}, {'frsize': True, 'bavail': 100}, {'frsize': 4096, 'bavail': -1},
                       {'frsize': 4096, 'bavail': '100'}):
            with self.subTest(fields=fields):
                with self.assertRaisesRegex(ValueError, 'capacity is unknown'):
                    MODULE['guest_free_bytes'](SimpleNamespace(statvfs=lambda path: fields))
        self.assertEqual(MODULE['guest_free_bytes'](SimpleNamespace(statvfs=lambda path: {'frsize':4096,'bavail':100})),409600)


if __name__ == '__main__':
    unittest.main()
