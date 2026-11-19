"""Synthetic unit inputs test rejection logic, never GUI acceptance evidence."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('native_proof', ROOT / 'tests/e2e/native-proof.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def fixture(directory):
    identity = {'artifactSha256': 'b' * 64, 'shellTreeSha256': 'c' * 64, 'transportTreeSha256': 'd' * 64}
    context = dict(runId=42, runAttempt=2, sourceSha='a' * 40, identity=identity,
                   startedAt='2026-09-20T07:00:00Z', packagePath='C:\\Program Files\\test\\Wootc.Shell.exe')
    native.save(directory / 'context.json', context)
    boot_id = '12345678-1234-1234-1234-123456789abc'
    facts = dict(runId=42, runAttempt=2, sourceSha=context['sourceSha'], observer='linux-qga', uname='Linux',
                 capturedAt='2026-09-20T07:20:00Z', bootId=boot_id, liveBootId=boot_id,
                 kernel='6.12', sourceImage='registry.example/image:stable',
                 bridge='boundFolders=2;matchedUsers=1;bitlockerUnlocked=false')
    native.save(directory / 'installed-boot-observation.json', facts)
    values = {'InstalledBootSource': facts['sourceImage'], 'InstalledBootKernel': facts['kernel'],
              'InstalledBootBridge': facts['bridge'], 'InstalledBootId': facts['bootId']}
    for journey, minute in [('install-confirmation', '10'), ('installed-boot-summary', '30'), ('windows-return', '40')]:
        stamp = '2026-09-20T07:' + minute + ':00Z'
        controls = [dict(automationId=key, visible=True, enabled=True, **{prop: literal if literal is not None else values[key]})
                    for key, (prop, literal) in native.ledger.REQUIRED[journey].items()]
        native.save(directory / (journey + '.uia.json'), dict(runId=42, runAttempt=2, sourceSha=context['sourceSha'],
            processName='Wootc.Shell.exe', processPath=context['packagePath'], processImageSha256=identity['artifactSha256'],
            capturedAt=stamp, controls=controls))
        frame = b'\x89PNG\r\n\x1a\nsynthetic-unit-input-not-a-capture'
        (directory / (journey + '.png')).write_bytes(frame)
        native.save(directory / (journey + '.observation.json'), dict(journey=journey, capturedAt=stamp,
            uiaFile=journey + '.uia.json', framebufferFile=journey + '.png', framebufferSha256=native.ledger.digest(frame)))
    native.save(directory / 'windows-current-observation.json', dict(runId=42, runAttempt=2, sourceSha=context['sourceSha'],
        observer='windows-cim', version='10.0', bootTime='2026-09-20T07:25:00Z', capturedAt='2026-09-20T07:39:00Z'))


class NativeProducerTests(unittest.TestCase):
    def test_package_build_must_match_source_before_identity_is_emitted(self):
        source_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        other_sha = 'a' * 40 if source_sha != 'a' * 40 else 'b' * 40
        with tempfile.TemporaryDirectory() as name:
            package = Path(name)
            for filename in native.native_package.REQUIRED:
                path = package / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'synthetic-unit-package-file')
            native.native_package.write(package, source_sha, 'wootc', package / 'Branding/brand.json')
            with mock.patch.dict(os.environ, {'GITHUB_SHA': source_sha, 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '1'}):
                result = native.identity(package)
            self.assertEqual(result['sourceSha'], source_sha)
            self.assertEqual(result['identity']['artifactSha256'], native.ledger.digest((package / 'Wootc.Shell.exe').read_bytes()))
            with mock.patch.dict(os.environ, {'GITHUB_SHA': other_sha, 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '1'}):
                with self.assertRaisesRegex(ValueError, 'buildId differs'):
                    native.identity(package)
            (package / 'Wootc.Shell.exe').write_bytes(b'tampered-unit-package')
            with self.assertRaises(native.native_package.PackageError):
                native.require_package_source(package, source_sha)

    def test_assembler_uses_ledger_and_rejects_unbound_observations(self):
        mutations = ['valid', 'wrong-uia-attempt', 'wrong-process', 'wrong-summary', 'wrong-boot-id',
                     'old-windows', 'missing-frame', 'path-traversal', 'hidden-summary', 'source-mismatch']
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                fixture(directory)
                if mutation == 'missing-frame':
                    (directory / 'install-confirmation.png').unlink()
                elif mutation == 'old-windows':
                    path = directory / 'windows-current-observation.json'
                    data = native.load(path)
                    data['bootTime'] = '2026-09-20T07:01:00Z'
                    native.save(path, data)
                elif mutation == 'path-traversal':
                    path = directory / 'install-confirmation.observation.json'
                    data = native.load(path)
                    data['uiaFile'] = '../other.json'
                    native.save(path, data)
                elif mutation != 'valid':
                    path = directory / 'installed-boot-summary.uia.json'
                    data = native.load(path)
                    if mutation == 'wrong-uia-attempt': data['runAttempt'] = 1
                    elif mutation == 'wrong-process': data['processPath'] = 'C:\\other\\Wootc.Shell.exe'
                    elif mutation == 'wrong-summary': data['controls'][0]['value'] = 'other:image'
                    elif mutation == 'wrong-boot-id':
                        next(control for control in data['controls'] if control['automationId'] == 'InstalledBootId')['value'] = '87654321-1234-1234-1234-123456789abc'
                    elif mutation == 'hidden-summary': data['controls'][0]['visible'] = False
                    elif mutation == 'source-mismatch': data['sourceSha'] = 'f' * 40
                    native.save(path, data)
                if mutation == 'valid':
                    with contextlib.redirect_stdout(io.StringIO()):
                        native.assemble(directory)
                    proof = native.load(directory / 'native-gui-proof.json')
                    self.assertEqual(proof['runAttempt'], 2)
                    bridge_check = next(check for observation in proof['observations'] for check in observation['checks'] if check['automationId'] == 'InstalledBootBridge')
                    self.assertEqual(bridge_check['expected'], 'boundFolders=2;matchedUsers=1;bitlockerUnlocked=false')
                else:
                    with self.assertRaises((ValueError, KeyError, FileNotFoundError)):
                        native.assemble(directory)

    def test_native_nonsoak_summary_uses_same_real_controls_without_github_identity(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            fixture(directory)
            facts = native.load(directory / 'installed-boot-observation.json')
            record = dict(current=dict(kernel=facts['kernel'], bootId=facts['bootId'],
                image={'sourceRef': facts['sourceImage']}, writtenAt=facts['capturedAt'],
                bridge=dict(boundFolders=2, matchedUsers=1, bitlockerUnlocked=False)))
            record_path = directory / 'live-record.json'
            native.save(record_path, record)
            with contextlib.redirect_stdout(io.StringIO()):
                native.validate_summary(directory, record_path)
            record['current']['bridge']['matchedUsers'] = 2
            native.save(record_path, record)
            with self.assertRaises(ValueError):
                native.validate_summary(directory, record_path)


if __name__ == '__main__':
    unittest.main()
