"""Actual offline consumer and native archive parsing; apt/dpkg state is a fixture."""
import copy
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/package-consumer.py'))


class PackageConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        build = self.folder/'build'; (build/'DEBIAN').mkdir(parents=True)
        (build/'DEBIAN/control').write_text('Package: fixture-package\nVersion: 2\nArchitecture: amd64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: Unsigned native format fixture only\n')
        self.archive = self.folder/'fixture-package_2_amd64.deb'
        subprocess.run(['/usr/bin/dpkg-deb', '--build', '--root-owner-group', str(build), str(self.archive)], check=True, capture_output=True)
        self.before = {'fixture-package': {'version': '1', 'architecture': 'amd64'}}
        self.after = {'fixture-package': {'version': '2', 'architecture': 'amd64'}}
        entry = {'name': self.archive.name, 'package': 'fixture-package', 'version': '2', 'architecture': 'amd64',
                 'sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.policy = {'schemaVersion': 1, 'manager': 'dpkg', 'scratchId': 'a'*32,
                       'phases': {'old': {'packages': [entry], 'beforeInventory': self.before,
                                         'afterInventory': self.after, 'allowedRemovals': []}}}
        self.save_policy()
        self.state = copy.deepcopy(self.before); self.calls = []; self.applied = False
        self.status_failure = False; self.status_partial = False; self.unapproved_remove = False
        self.mutate_during_deb = False; self.bad_post_status = False
        self.simulation_output = None

    def save_policy(self):
        path = self.folder/'packages.json'; path.write_text(json.dumps(self.policy))
        path.chmod(0o600)
        (self.folder/'ownership.json').write_text(json.dumps({'scope':'exclusive-classic-qa-root',
            'scratchId': self.policy['scratchId'], 'policySha256':hashlib.sha256(path.read_bytes()).hexdigest()}))
        (self.folder/'ownership.json').chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def run_command(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if argv[0] == '/usr/bin/dpkg-query':
            if self.status_failure: raise subprocess.CalledProcessError(1, argv, output=b'plausible installed state')
            output = ''.join(n+'\t'+v['version']+'\t'+v['architecture']+'\t'+('unpacked' if self.status_partial else 'installed')+'\n' for n,v in self.state.items())
            return SimpleNamespace(stdout=output.encode())
        if argv[0] == '/usr/bin/dpkg-deb':
            result = subprocess.run(argv, **kwargs)
            if self.mutate_during_deb:
                self.archive.write_bytes(b'mutated source after frozen snapshot')
            return result
        if '--simulate' in argv:
            output = (b'Inst fixture-package [1] (2 Local [amd64])\n'
                      if self.simulation_output is None else self.simulation_output)
            if self.unapproved_remove: output += b'Remv foreign-work [1]\n'
            return SimpleNamespace(stdout=output)
        self.applied = True
        self.state = copy.deepcopy(self.before if self.bad_post_status else self.after)
        return SimpleNamespace(stdout=b'')

    def consume(self, callback=None):
        return MODULE['consume'](self.folder, 'old', self.run_command, callback)

    def assert_preflight_refuses(self, exception=ValueError):
        with self.assertRaises(exception): self.consume()
        self.assertFalse(self.applied)

    def test_actual_consumer_freezes_native_archive_and_uses_no_network_command(self):
        self.consume()
        install = next((argv, kwargs) for argv, kwargs in self.calls if argv[0] == '/usr/bin/apt-get' and '--simulate' not in argv)
        self.assertIn('--no-download', install[0]); self.assertIn('--allow-downgrades', install[0])
        self.assertIn('Dir::Etc::sourcelist=/dev/null', install[0])
        self.assertNotIn('--force-depends', install[0])
        self.assertNotEqual(install[0][-1], str(self.archive))
        self.assertEqual(self.state, self.after)
        self.assertEqual(list(self.folder.glob('offline-bundle-*')), [])

    def test_missing_or_wrong_package_never_calls_installer(self):
        self.archive.unlink(); self.assert_preflight_refuses()

    def test_wrong_hash_never_calls_installer(self):
        self.archive.write_bytes(b'foreign bytes'); self.assert_preflight_refuses()

    def test_native_control_identity_differs_from_declared_pin(self):
        self.policy['phases']['old']['packages'][0]['version'] = '999'; self.save_policy()
        self.assert_preflight_refuses()

    def test_package_symlink_refuses(self):
        other = self.folder/'other.deb'; self.archive.rename(other); self.archive.symlink_to(other)
        self.assert_preflight_refuses()

    def test_changed_copy_refuses_before_native_package_consumption(self):
        original = MODULE['shutil'].copyfileobj
        def copy_and_change(reader, writer):
            original(reader, writer); self.archive.write_bytes(b'changed during snapshot')
        with patch.object(MODULE['shutil'], 'copyfileobj', copy_and_change): self.assert_preflight_refuses()

    def test_mutation_after_freeze_never_consumes_changed_source(self):
        self.mutate_during_deb = True
        self.consume()
        self.assertTrue(self.applied)
        self.assertEqual(self.state, self.after)

    def test_wrong_actual_inventory_refuses_before_package_commands(self):
        self.state['fixture-package']['version'] = 'foreign'
        self.assert_preflight_refuses()
        self.assertEqual(len(self.calls), 1)

    def test_failed_status_with_plausible_output_is_not_inventory(self):
        self.status_failure = True; self.assert_preflight_refuses(subprocess.CalledProcessError)

    def test_partial_package_status_refuses(self):
        self.status_partial = True; self.assert_preflight_refuses()

    def test_only_exact_allowlisted_retired_config_state_is_accepted(self):
        retired = {'initramfs-tools': {'version':'1','architecture':'all'}}
        data = b'fixture-package\t2\tamd64\tinstalled\ninitramfs-tools\t1\tall\tconfig-files\n'
        def query(*args, **kwargs): return SimpleNamespace(stdout=data)
        self.assertEqual(MODULE['inventory'](query, retired), self.after)
        with self.assertRaises(ValueError): MODULE['inventory'](query, {})
        with self.assertRaises(ValueError): MODULE['inventory'](query, {'initramfs-tools':{'version':'foreign','architecture':'all'}})

    def test_unapproved_removal_refuses(self):
        self.unapproved_remove = True; self.assert_preflight_refuses()

    def test_empty_simulation_refuses_before_callback_or_installer(self):
        self.simulation_output = b'Reading package lists...\n'
        callbacks = []
        with self.assertRaisesRegex(ValueError, 'complete approved transition'):
            self.consume(lambda: callbacks.append(True))
        self.assertEqual(callbacks, [])
        self.assertFalse(self.applied)

    def test_partial_simulation_refuses_actual_two_archive_transition(self):
        build = self.folder/'second'; (build/'DEBIAN').mkdir(parents=True)
        (build/'DEBIAN/control').write_text('Package: fixture-second\nVersion: 2\nArchitecture: all\nMaintainer: Fixture <fixture@example.invalid>\nDescription: Partial simulation fixture\n')
        archive = self.folder/'fixture-second_2_all.deb'
        subprocess.run(['/usr/bin/dpkg-deb', '--build', '--root-owner-group', str(build), str(archive)], check=True, capture_output=True)
        self.before['fixture-second'] = {'version':'1','architecture':'all'}
        self.after['fixture-second'] = {'version':'2','architecture':'all'}
        self.state = copy.deepcopy(self.before)
        self.policy['phases']['old']['packages'].append({'name':archive.name,'package':'fixture-second','version':'2','architecture':'all','sha256':hashlib.sha256(archive.read_bytes()).hexdigest()})
        self.save_policy()
        callbacks = []
        with self.assertRaisesRegex(ValueError, 'complete approved transition'):
            self.consume(lambda: callbacks.append(True))
        self.assertEqual(callbacks, [])
        self.assertFalse(self.applied)
        self.assertEqual(sum(argv[0]=='/usr/bin/dpkg-deb' for argv,_ in self.calls), 2)

    def test_duplicate_malformed_or_wrong_identity_mutations_refuse(self):
        valid = b'Inst fixture-package [1] (2 Local [amd64])\n'
        for observation in (valid+valid, b'Inst\n', b'Inst fixture-package [1] (2 Local [all])\n',
                            b'Inst fixture-package:all [1] (2 Local [amd64])\n',
                            b'Inst fixture-package [foreign] (2 Local [amd64])\n',
                            valid+b'Remv\n', valid+b' Inst fixture-package [1] (2 Local [amd64])\n', valid+b'Conf fixture-package (foreign Local [amd64])\n',
                            valid+b'Conf fixture-package (2 Local [amd64])\n'*2):
            with self.subTest(observation=observation):
                self.simulation_output = observation
                callbacks = []
                with self.assertRaises(ValueError): self.consume(lambda: callbacks.append(True))
                self.assertEqual(callbacks, [])
                self.assertFalse(self.applied)

    def test_exact_removal_observation_is_required_and_unique(self):
        self.before['initramfs-tools'] = {'version':'1','architecture':'all'}
        self.state = copy.deepcopy(self.before)
        self.policy['phases']['old']['allowedRemovals'] = ['initramfs-tools']
        self.save_policy()
        valid = b'Inst fixture-package [1] (2 Local [amd64])\n'
        for removal in (b'', b'Remv initramfs-tools [foreign]\n',
                        b'Remv initramfs-tools [1]\n'*2,
                        b'Remv initramfs-tools:amd64 [1]\n'):
            with self.subTest(removal=removal):
                self.simulation_output = valid+removal
                callbacks = []
                with self.assertRaises(ValueError): self.consume(lambda: callbacks.append(True))
                self.assertEqual(callbacks, [])
                self.assertFalse(self.applied)
        self.simulation_output = valid+b'Remv initramfs-tools [1]\n'
        self.consume()
        self.assertTrue(self.applied)

    def test_complete_configuration_observation_is_accepted(self):
        self.simulation_output = b'Inst fixture-package [1] (2 Local [amd64]) []\nConf fixture-package (2 Local [amd64])\n'
        self.consume()
        self.assertTrue(self.applied)

    def test_unchanged_version_dependency_archive_is_checked_but_not_reinstalled(self):
        build = self.folder/'other'; (build/'DEBIAN').mkdir(parents=True)
        (build/'DEBIAN/control').write_text('Package: fixture-agent\nVersion: 1\nArchitecture: amd64\nMaintainer: Fixture <fixture@example.invalid>\nDescription: Unchanged agent fixture\n')
        archive = self.folder/'fixture-agent_1_amd64.deb'
        subprocess.run(['/usr/bin/dpkg-deb', '--build', '--root-owner-group', str(build), str(archive)], check=True, capture_output=True)
        self.before['fixture-agent'] = self.after['fixture-agent'] = {'version':'1','architecture':'amd64'}
        self.state = copy.deepcopy(self.before)
        self.policy['phases']['old']['packages'].append({'name':archive.name,'package':'fixture-agent','version':'1','architecture':'amd64','sha256':hashlib.sha256(archive.read_bytes()).hexdigest()})
        self.save_policy(); self.consume()
        self.assertEqual(sum(argv[0]=='/usr/bin/dpkg-deb' for argv,_ in self.calls), 2)
        install = next(argv for argv,_ in self.calls if argv[0]=='/usr/bin/apt-get' and '--simulate' not in argv)
        self.assertFalse(any('fixture-agent_' in value for value in install))

    def test_inventory_changed_during_package_preflight_refuses(self):
        original = self.run_command
        def change_after_control(argv, **kwargs):
            result = original(argv, **kwargs)
            if argv[0] == '/usr/bin/dpkg-deb': self.state['fixture-package']['version'] = 'foreign'
            return result
        with self.assertRaisesRegex(ValueError, 'inventory changed across'):
            MODULE['consume'](self.folder, 'old', change_after_control)
        self.assertFalse(self.applied)

    def test_unowned_scope_or_policy_binding_refuses(self):
        owner = json.loads((self.folder/'ownership.json').read_text()); owner['scratchId'] = 'b'*32
        (self.folder/'ownership.json').write_text(json.dumps(owner)); self.assert_preflight_refuses()
        self.assertEqual(self.calls, [])

    def test_bad_post_install_inventory_does_not_claim_completion(self):
        self.bad_post_status = True
        with self.assertRaisesRegex(ValueError, 'installed package inventory differs'): self.consume()
        self.assertTrue(self.applied)

    def test_frozen_snapshot_change_after_callback_refuses_actual_install(self):
        def callback():
            path = next(self.folder.glob('offline-bundle-*/*.deb'))
            path.chmod(0o600); path.write_bytes(b'changed after approval')
        with self.assertRaisesRegex(ValueError, 'frozen bundle changed'): self.consume(callback)
        self.assertFalse(self.applied)

    def test_native_output_bound_kills_and_reaps_command(self):
        with self.assertRaisesRegex(ValueError, 'output exceeds bound'):
            MODULE['execute'](['/usr/bin/python3', '-c', "print('x'*400000)"], capture_output=True)

    def test_native_no_progress_status_command_has_deadline(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            MODULE['execute'](['/usr/bin/python3', '-c', 'import time;time.sleep(5)'], timeout=.05, capture_output=True)

    def test_native_failed_status_with_plausible_stdout_raises(self):
        with self.assertRaises(subprocess.CalledProcessError):
            MODULE['execute'](['/usr/bin/python3', '-c', "print('fixture-package\\t1\\tamd64\\tinstalled');raise SystemExit(1)"], capture_output=True)

    def test_owned_descendant_cannot_hold_status_pipe_past_deadline(self):
        pidfile = self.folder/'child.pid'
        code = ('import subprocess,time; p=subprocess.Popen(["/usr/bin/python3","-c","import time;time.sleep(20)"]);'
                'open('+repr(str(pidfile))+',"w").write(str(p.pid));time.sleep(20)')
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            MODULE['execute'](['/usr/bin/python3', '-c', code], timeout=.2, capture_output=True)
        self.assertLess(time.monotonic()-start, 1.5)
        pid = int(pidfile.read_text())
        status = Path('/proc')/str(pid)/'stat'
        # A dead child may await init's reaping; it must no longer execute.
        for _ in range(100):
            if not status.exists() or status.read_text().split(') ')[1].startswith('Z'): break
            time.sleep(.005)
        self.assertTrue(not status.exists() or status.read_text().split(') ')[1].startswith('Z'))


if __name__ == '__main__': unittest.main()
