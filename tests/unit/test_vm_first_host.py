#!/usr/bin/env python3
"""Actual consumer counterexamples; no VM creation or host configuration changes."""
import copy
import errno
import os
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'e2e/vm-first/qualify-host.py'
spec = importlib.util.spec_from_file_location('qualify_host', SOURCE)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def ready():
    return {'cpus': [{'vendor': 'GenuineIntel', 'flags': ['vmx', 'ept']} for _ in range(4)],
            'nested': 'Y', 'memory': {'MemTotal': 16 * host.GIB, 'MemAvailable': 12 * host.GIB},
            'storage': {'path': '/owned', 'availableBytes': 90 * host.GIB},
            'kvm': {'apiVersion': 12, 'userMemory': 1}}


class Qualification(unittest.TestCase):
    def consume(self, observations=None, cpu='host,+vmx', error=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'receipt.json'
            with mock.patch.object(host, 'collect', return_value=observations, side_effect=error), mock.patch('sys.stdout', new=io.StringIO()):
                rc = host.main(['--storage-path', tmp, '--outer-cpu', cpu, '--receipt', str(path), '--run-id', '123/2'])
            return rc, json.loads(path.read_text())

    def refuse(self, changed, reason, cpu='host,+vmx'):
        rc, receipt = self.consume(changed, cpu)
        self.assertEqual(rc, 1)
        self.assertIn(reason, receipt['refusals'])
        self.assertFalse(receipt['prerequisitesPassed'])
        self.assertFalse(receipt['guestExecutionQualified'])
        self.assertFalse(receipt['desktopQualified'])

    def test_positive_is_only_prerequisite(self):
        rc, r = self.consume(ready())
        self.assertEqual(rc, 0)
        self.assertTrue(r['prerequisitesPassed'])
        self.assertEqual(r['runId'], '123/2')
        self.assertEqual(r['outerCpuProposed'], 'host,+vmx')
        self.assertIsNone(r['outerCpuExpandedObserved'])
        self.assertFalse(r['windowsWhpxQualified'])
        self.assertFalse(r['guestExecutionQualified'])
        self.assertFalse(r['desktopQualified'])

    def test_actual_masked_cpu_argument_refuses(self):
        self.refuse(ready(), 'outer-cpu-extension-not-explicitly-preserved',
                    'host,kvm=on,l3-cache=on,+hypervisor,migratable=no,-vmx,+invtsc')

    def test_conflicting_positive_and_masked_cpu_refuses(self):
        for suffix in ['-vmx', 'vmx=off', 'vmx=false', 'vmx=0', '-ept', 'ept=off', '+vmx']:
            with self.subTest(suffix=suffix):
                self.refuse(ready(), 'outer-cpu-extension-not-explicitly-preserved', 'host,+vmx,' + suffix)

    def test_missing_cpu_extension_on_one_processor(self):
        x = ready(); x['cpus'][-1]['flags'] = ['ept']
        self.refuse(x, 'cpu-virtualization-not-observed')

    def test_missing_second_level_translation(self):
        x = ready(); x['cpus'][0]['flags'] = ['vmx']
        self.refuse(x, 'cpu-virtualization-not-observed')

    def test_nested_disabled_or_unknown(self):
        for token in ['N', '0', '', None, 'enabled']:
            x = ready(); x['nested'] = token
            self.refuse(x, 'host-nesting-not-enabled')

    def test_kvm_wrong_api_and_capability(self):
        for api, cap in [(11, 1), (12, 0), (-1, 1)]:
            x = ready(); x['kvm'] = {'apiVersion': api, 'userMemory': cap}
            self.refuse(x, 'kvm-unusable')

    def test_failed_kvm_query_refuses_without_success_receipt(self):
        with mock.patch.object(host.os, 'open', return_value=77), mock.patch.object(host.os, 'close') as close, mock.patch.object(host.fcntl, 'ioctl', side_effect=OSError('query failed')):
            with self.assertRaises(OSError):
                host.kvm_observation()
            close.assert_called_once_with(77)
        rc, r = self.consume(error=PermissionError('KVM access refused'))
        self.assertEqual(rc, 1)
        self.assertEqual(r['refusals'], ['host-observation-failed'])

    def test_actual_kvm_eacces_retains_independent_linux_observations(self):
        actual_open = os.open
        calls = []
        def refuse_kvm(path, flags, *args, **kwargs):
            calls.append(str(path))
            if str(path) == '/dev/kvm':
                raise PermissionError(errno.EACCES, 'controlled ordinary KVM access refusal', path)
            return actual_open(path, flags, *args, **kwargs)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'receipt.json'
            with mock.patch.object(host.os, 'open', side_effect=refuse_kvm), mock.patch('sys.stdout', new=io.StringIO()):
                rc = host.main(['--storage-path', tmp, '--outer-cpu', 'host,+vmx',
                                '--receipt', str(path), '--run-id', 'actual-linux/1'])
            receipt = json.loads(path.read_text())
            observed = receipt['observations']
            self.assertEqual(rc, 1)
            self.assertIn('/dev/kvm', calls)
            self.assertIsNone(observed['kvm'])
            self.assertEqual(observed['observationErrors']['kvm']['errno'], errno.EACCES)
            self.assertTrue(observed['cpus'])
            self.assertEqual(observed['memory']['MemTotal'], host.memory(Path('/proc/meminfo').read_text())['MemTotal'])
            self.assertGreater(observed['memory']['MemAvailable'], 0)
            self.assertLessEqual(observed['memory']['MemAvailable'], observed['memory']['MemTotal'])
            self.assertEqual(observed['storage']['path'], str(Path(tmp).resolve()))
            self.assertGreater(observed['storage']['availableBytes'], 0)
            self.assertIn('kvm-observation-failed', receipt['refusals'])
            self.assertFalse(receipt['prerequisitesPassed'])
            self.assertFalse(receipt['guestExecutionQualified'])

    def test_each_failed_measurement_preserves_other_actual_collectors(self):
        for failed in ('cpus', 'memory', 'storage', 'nested', 'kvm'):
            def read(path):
                category = 'cpus' if str(path) == '/proc/cpuinfo' else 'memory' if str(path) == '/proc/meminfo' else 'nested'
                if category == failed:
                    raise PermissionError(errno.EACCES, 'controlled read refusal')
                return {'cpus': '\n\n'.join(['vendor_id : GenuineIntel\nflags : vmx ept'] * 4),
                        'memory': 'MemTotal: 16777216 kB\nMemAvailable: 12582912 kB\n', 'nested': 'Y\n'}[category]
            with tempfile.TemporaryDirectory() as tmp:
                storage = str(Path(tmp) / 'absent') if failed == 'storage' else tmp
                with mock.patch.object(Path, 'read_text', read), mock.patch.object(host, 'kvm_observation',
                        return_value=ready()['kvm'], side_effect=PermissionError(errno.EACCES, 'controlled KVM refusal') if failed == 'kvm' else None):
                    observed = host.collect(storage)
                self.assertIsNone(observed[failed])
                self.assertIn(failed, observed['observationErrors'])
                unaffected = set(('cpus', 'memory', 'storage', 'nested', 'kvm')) - {failed}
                if failed == 'cpus':
                    unaffected.remove('nested')
                for key in unaffected:
                    self.assertIsNotNone(observed[key], (failed, key))
                self.assertIn(failed + '-observation-failed', host.assess(observed, 'host,+vmx'))

    def test_capacity_independently_refuses(self):
        for section, field, value, reason in [
            ('memory', 'MemTotal', 8 * host.GIB, 'host-memory-capacity'),
            ('memory', 'MemAvailable', 9 * host.GIB, 'host-memory-capacity'),
            ('storage', 'availableBytes', 84 * host.GIB - 1, 'host-storage-capacity')]:
            x = ready(); x[section][field] = value
            self.refuse(x, reason)
        x = ready(); x['cpus'] = x['cpus'][:3]
        self.refuse(x, 'host-cpu-capacity')

    def test_actual_storage_measurement_is_available_not_total(self):
        with tempfile.TemporaryDirectory() as tmp:
            cpu = '\n\n'.join(['vendor_id : GenuineIntel\nflags : vmx ept'] * 4)
            def read(p):
                if str(p) == '/proc/cpuinfo': return cpu
                if str(p) == '/proc/meminfo': return 'MemTotal: 16777216 kB\nMemAvailable: 12582912 kB\n'
                if str(p).endswith('/nested'): return 'Y\n'
                raise AssertionError(str(p))
            with mock.patch.object(Path, 'read_text', read), mock.patch.object(host, 'kvm_observation', return_value=ready()['kvm']):
                measured = host.collect(tmp)
            fs = host.os.statvfs(tmp)
            self.assertEqual(measured['storage']['availableBytes'], fs.f_bavail * fs.f_frsize)
            self.assertEqual(measured['storage']['path'], str(Path(tmp).resolve()))
            # Demand one byte beyond this actual filesystem's available capacity.
            self.assertIn('host-storage-capacity', host.assess(measured, 'host,+vmx', measured['storage']['availableBytes'] + 1))

    def test_amd_is_explicit_and_mixed_vendor_refuses(self):
        x = ready()
        x['cpus'] = [{'vendor': 'AuthenticAMD', 'flags': ['svm', 'npt']} for _ in range(4)]
        self.assertEqual(self.consume(x, 'host,+svm')[0], 0)
        x['cpus'][0]['vendor'] = 'GenuineIntel'
        self.refuse(x, 'cpu-vendor-unknown', 'host,+svm')

    def test_unknown_observation_cannot_be_clean(self):
        for error in [ValueError('bad CPU row'), OSError('nested observation missing')]:
            rc, r = self.consume(error=error)
            self.assertEqual(rc, 1)
            self.assertFalse(r['prerequisitesPassed'])

    def test_duplicate_or_missing_memory_and_cpu_fields_refuse(self):
        for text in ['MemTotal: 1 kB\n', 'MemTotal: 1 kB\nMemTotal: 2 kB\nMemAvailable: 1 kB']:
            with self.assertRaises(ValueError): host.memory(text)
        with self.assertRaises(ValueError): host.cpu_rows('vendor_id: GenuineIntel\nvendor_id: AuthenticAMD')

    def test_existing_receipt_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'receipt'; p.write_text('retained')
            with mock.patch.object(host, 'collect', return_value=ready()):
                with self.assertRaises(FileExistsError):
                    host.main(['--storage-path', tmp, '--outer-cpu', 'host,+vmx', '--receipt', str(p), '--run-id', '123/2'])
            self.assertEqual(p.read_text(), 'retained')


if __name__ == '__main__':
    unittest.main()
