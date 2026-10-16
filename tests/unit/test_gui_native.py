#!/usr/bin/env python3
"""The native shell E2E: its protected package and the guest staging verdicts.

WOOTC_E2E_GUI_FRONTEND=native installs a package (shell + engine +
native-package.json) and drives it. Each check here is a counterexample the
harness must refuse: a gallery build, a package that differs from its
manifest, a copy that did not finish, a guest that was not provisioned, or a
shell running from somewhere other than the installed package.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'tests/e2e/native-package.py'
MODULE = ROOT / 'tests/e2e/lib/gui-native.sh'
BRAND_SCRIPT = ROOT / 'tests/e2e/e2e-brand.sh'
WORKFLOW = (ROOT / '.github/workflows/e2e-hosted.yml').read_text()
BUILD = '0123456789abcdef0123456789abcdef01234567'


def package(*args):
    return subprocess.run(['python3', str(PACKAGE), *args], text=True, capture_output=True)


def shell(call, **env):
    return subprocess.run(['bash', '-c', f"source '{MODULE}'; {call}"],
                          env=dict(os.environ, **env), text=True, capture_output=True)


class NativePackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / 'pkg'
        for name in ('wootc-engine.exe', 'Wootc.Shell.exe', 'Wootc.Shell.dll', 'Wootc.Shell.pri', 'Microsoft.UI.Xaml.dll'):
            (self.dir / name).parent.mkdir(parents=True, exist_ok=True)
            (self.dir / name).write_bytes(name.encode())
        (self.dir / 'Branding').mkdir()
        self.brand = ROOT / 'app/branding/bluefin/brand.json'
        (self.dir / 'Branding/brand.json').write_bytes(self.brand.read_bytes())

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        return package('write', str(self.dir), BUILD, 'bluefin', str(self.brand))

    def test_write_then_check_round_trips_the_identity(self):
        self.assertEqual(self.write().returncode, 0)
        manifest = json.loads((self.dir / 'native-package.json').read_text())
        self.assertEqual(set(manifest), {'schemaVersion', 'protocolVersion', 'buildId', 'brandId', 'files'})
        self.assertEqual(manifest['files']['Branding/brand.json'], manifest['files']['Branding/brand.json'].lower())
        self.assertNotIn('native-package.json', manifest['files'])
        result = package('check', str(self.dir))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f'buildId={BUILD} brandId=bluefin files=6')

    def test_the_gallery_build_is_refused(self):
        (self.dir / 'Wootc.Shell.Gallery.dll').write_bytes(b'g')
        result = self.write()
        self.assertEqual(result.returncode, 1)
        self.assertIn('screen gallery', result.stderr)
        (self.dir / 'Wootc.Shell.Gallery.dll').unlink()
        (self.dir / 'Fixtures/install-progress').mkdir(parents=True)
        (self.dir / 'Fixtures/install-progress/success.ndjson').write_bytes(b'{}')
        self.assertIn('screen gallery', self.write().stderr)

    def test_a_changed_or_added_file_fails_the_check(self):
        self.assertEqual(self.write().returncode, 0)
        (self.dir / 'wootc-engine.exe').write_bytes(b'replaced')
        result = package('check', str(self.dir))
        self.assertEqual(result.returncode, 1)
        self.assertIn('wootc-engine.exe', result.stderr)
        (self.dir / 'wootc-engine.exe').write_bytes(b'wootc-engine.exe')
        self.assertEqual(package('check', str(self.dir)).returncode, 0)
        (self.dir / 'extra.dll').write_bytes(b'x')
        self.assertIn('extra.dll', package('check', str(self.dir)).stderr)

    def test_a_missing_engine_or_wrong_brand_is_refused(self):
        self.assertEqual(package('write', str(self.dir), BUILD, 'bazzite', str(ROOT / 'app/branding/bazzite/brand.json')).returncode, 1)
        (self.dir / 'wootc-engine.exe').unlink()
        self.assertIn('wootc-engine.exe', self.write().stderr)

    def test_identity_must_be_a_commit_and_a_known_brand(self):
        self.assertEqual(package('write', str(self.dir), BUILD.upper(), 'bluefin', str(self.brand)).returncode, 1)
        self.assertEqual(package('write', str(self.dir), BUILD, 'gtk', str(self.brand)).returncode, 1)

    def test_an_existing_manifest_is_never_overwritten(self):
        self.assertEqual(self.write().returncode, 0)
        self.assertIn('refusing to overwrite', self.write().stderr)

    def test_no_manifest_fails_the_check(self):
        self.assertIn('no manifest', package('check', str(self.dir)).stderr)


class GuestVerdictTests(unittest.TestCase):
    INSTALLED = '\r\n'.join([
        'package-files: recorded=212 present=212',
        'package-digests: Wootc.Shell.exe wootc-engine.exe',
        'package-brand: bluefin',
        'package-build: ' + BUILD,
        'machine-env: WOOTC_E2E_DRIVE=1 WOOTC_PRELOAD=0',
        'uac: ConsentPromptBehaviorAdmin=0',
        'uac-lua: EnableLUA=1',
        'native-package-installed', ''])

    def installed(self, out):
        return shell('gui_native_installed_proven "$OUT"', OUT=out, NATIVE_BRAND='bluefin').returncode

    def test_a_whole_provisioned_package_passes(self):
        self.assertEqual(self.installed(self.INSTALLED), 0)

    def test_each_missing_proof_is_refused(self):
        for line in ('native-package-installed', 'machine-env: WOOTC_E2E_DRIVE=1 WOOTC_PRELOAD=0',
                     'uac: ConsentPromptBehaviorAdmin=0', 'package-brand: bluefin',
                     'package-digests: Wootc.Shell.exe wootc-engine.exe'):
            self.assertNotEqual(self.installed(self.INSTALLED.replace(line + '\r\n', '')), 0, line)
        self.assertNotEqual(self.installed(''), 0)

    def test_a_partial_copy_or_digest_mismatch_is_refused(self):
        self.assertNotEqual(self.installed(self.INSTALLED.replace('present=212', 'present=211')), 0)
        self.assertNotEqual(self.installed(self.INSTALLED.replace('recorded=212 present=212', 'recorded=0 present=0')), 0)
        self.assertNotEqual(self.installed(self.INSTALLED + 'PACKAGE-DIGEST-MISMATCH: wootc-engine.exe\r\n'), 0)
        self.assertNotEqual(self.installed(self.INSTALLED.replace('ConsentPromptBehaviorAdmin=0', 'ConsentPromptBehaviorAdmin=5')), 0)

    def test_robocopy_exit_codes(self):
        for raw, want in (('rc=0', 'ok'), ('rc=1\r\n', 'ok'), ('rc=7', 'ok'), ('rc=8', 'failed'),
                          ('rc=16', 'failed'), ('pending', 'pending'), ('', 'pending'), ('rc=', 'pending')):
            self.assertEqual(shell('gui_native_copy_verdict "$RAW"', RAW=raw).stdout.strip(), want, raw)

    def test_the_running_shell_must_be_the_installed_package(self):
        good = 'single-instance: 1 Wootc.Shell.exe\r\nnative-shell-path: C:\\Program Files\\wootc Native Preview\\bluefin\\bundle\\Wootc.Shell.exe\r\n'
        call = 'gui_native_shell_path_proven "$OUT"'
        self.assertEqual(shell(call, OUT=good, NATIVE_BRAND='bluefin').returncode, 0)
        for bad in (good.replace('bluefin', 'bazzite'), good.replace('Program Files', 'Users\\wootc\\Downloads'),
                    good.replace('native-shell-path: ', 'native-shell-path: '), 'single-instance: 1 Wootc.Shell.exe'):
            if bad == good:
                continue
            self.assertNotEqual(shell(call, OUT=bad, NATIVE_BRAND='bluefin').returncode, 0, bad)

    def test_the_bundle_path_is_where_the_preview_installer_puts_it(self):
        result = shell('gui_native_bundle_ps', NATIVE_BRAND='bluefin')
        self.assertEqual(result.returncode, 0)
        self.assertIn('$env:ProgramW6432', result.stdout)
        self.assertIn('$bundle = Join-Path $pf "wootc Native Preview\\bluefin\\bundle"', result.stdout)
        iss = (ROOT / 'shell/packaging/preview.iss').read_text()
        self.assertIn('DefaultDirName={autopf}\\wootc Native Preview\\{#BrandId}', iss)
        self.assertIn('DestDir: "{app}\\bundle"', iss)
        self.assertNotEqual(shell('gui_native_bundle_ps', NATIVE_BRAND='blue fin').returncode, 0)


class ResultLedgerTests(unittest.TestCase):
    def test_a_native_run_requires_the_native_shell_assertion(self):
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        self.assertIn('if [ "$GUI_FRONTEND" = native ]; then RESULT_REQUIRED=gui-install,native-shell; fi', runner)
        self.assertIn('product_pass native-shell ', runner)
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / 'ledger.jsonl'
            result = subprocess.run(['python3', str(ROOT / 'tests/e2e/lib/results.py'), 'init', str(ledger), 'run-1',
                                     '--scenario', 'full-cycle', '--required', 'gui-install,native-shell'],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            started = json.loads(ledger.read_text().splitlines()[0])
            self.assertIn('native-shell', started['requiredAssertions'])


class WorkflowTests(unittest.TestCase):
    def test_the_e2e_never_publishes_the_gallery(self):
        publishes = [line for line in WORKFLOW.splitlines() if 'dotnet publish' in line]
        self.assertEqual(len(publishes), 1)
        self.assertNotIn('NativeGallery', publishes[0])
        self.assertIn('-p:NativeBuildId=${{ github.sha }}', WORKFLOW)
        self.assertIn('-X main.nativeBuildID=${{ github.sha }}', WORKFLOW)

    def test_the_engine_carries_the_runs_manifest_key(self):
        self.assertIn('-X main.artifactPublicKey=$public', WORKFLOW)
        self.assertIn('native-package.py write', WORKFLOW)

    def test_brands_match_the_workflow_choice(self):
        for image, brand in (('ghcr.io/projectbluefin/bluefin:lts', 'bluefin'),
                             ('ghcr.io/projectbluefin/dakota:latest', 'bluefin'),
                             ('ghcr.io/example/unclaimed:latest', 'wootc')):
            result = subprocess.run(['bash', str(BRAND_SCRIPT), image], text=True, capture_output=True)
            self.assertEqual(result.stdout.strip(), brand, result.stderr)


if __name__ == '__main__':
    unittest.main()
