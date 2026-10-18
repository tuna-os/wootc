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
import re
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

    def test_a_windows_checkout_brand_with_crlf_is_the_same_brand(self):
        # windows-latest checks out brand.json with CRLF (run 38843668488).
        crlf = self.brand.read_bytes().replace(b'\n', b'\r\n')
        self.assertNotEqual(crlf, self.brand.read_bytes())
        (self.dir / 'Branding/brand.json').write_bytes(crlf)
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(package('check', str(self.dir)).returncode, 0)

    def test_a_different_brand_content_is_still_refused(self):
        (self.dir / 'Branding/brand.json').write_bytes((ROOT / 'app/branding/bazzite/brand.json').read_bytes())
        self.assertIn('differs from the selected source brand', self.write().stderr)

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
        'install-method: inno',
        'inno-uninstall-entry: wootc-native-preview-bluefin_is1 C:\\Program Files\\wootc Native Preview\\bluefin\\',
        'inno-uninstallers: 1',
        'machine-env: WOOTC_E2E_DRIVE=1 WOOTC_PRELOAD=0',
        'uac: ConsentPromptBehaviorAdmin=0',
        'uac-lua: EnableLUA=1',
        'native-package-installed', ''])
    # What a robocopy leaves: no uninstall entry, no uninstaller.
    COPIED = (INSTALLED.replace('install-method: inno', 'install-method: robocopy')
              .replace('inno-uninstall-entry: wootc-native-preview-bluefin_is1 C:\\Program Files\\wootc Native Preview\\bluefin\\\r\n', '')
              .replace('inno-uninstallers: 1', 'inno-uninstallers: 0'))

    def installed(self, out, method='inno'):
        return shell('gui_native_installed_proven "$OUT"', OUT=out, NATIVE_BRAND='bluefin',
                     NATIVE_INSTALLER=method).returncode

    def test_a_whole_provisioned_package_passes(self):
        self.assertEqual(self.installed(self.INSTALLED), 0)
        self.assertEqual(self.installed(self.COPIED, 'robocopy'), 0)

    def test_an_inno_run_needs_what_only_the_installer_writes(self):
        # A copied package is never accepted as an installed one.
        self.assertNotEqual(self.installed(self.COPIED, 'inno'), 0)
        self.assertNotEqual(self.installed(self.INSTALLED.replace('inno-uninstallers: 1', 'inno-uninstallers: 2')), 0)
        self.assertNotEqual(self.installed(self.INSTALLED.replace('preview-bluefin_is1', 'preview-bazzite_is1')), 0)
        self.assertNotEqual(self.installed(self.INSTALLED.replace('install-method: inno', 'install-method: robocopy')), 0)
        # A robocopy run states its method; an unknown method passes nothing.
        self.assertNotEqual(self.installed(self.INSTALLED, 'robocopy'), 0)
        self.assertNotEqual(self.installed(self.INSTALLED, ''), 0)

    def test_installer_exit_codes(self):
        for raw, want in (('rc=0', 'ok'), ('rc=0\r\n', 'ok'), ('rc=1', 'failed'), ('rc=2', 'failed'), ('rc=7', 'failed'),
                          ('rc=8', 'failed'), ('rc=1223', 'failed'), ('rc=-1', 'failed'), ('rc=0x1', 'pending'), ('pending', 'pending'), ('', 'pending'), ('rc=', 'pending')):
            self.assertEqual(shell('gui_native_exit_verdict "$RAW"', RAW=raw).stdout.strip(), want, raw)

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


class OptionTests(unittest.TestCase):
    def test_the_options_and_their_defaults(self):
        for installer, unelevated, ok in (('inno', '1', True), ('robocopy', '0', True), ('', '1', False),
                                          ('msi', '1', False), ('inno', '', False), ('inno', 'yes', False)):
            result = shell('gui_native_options_valid', NATIVE_INSTALLER=installer, NATIVE_UNELEVATED=unelevated)
            self.assertEqual(result.returncode == 0, ok, (installer, unelevated))
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        self.assertIn('NATIVE_INSTALLER="${WOOTC_E2E_NATIVE_INSTALLER:-inno}"', runner)
        self.assertIn('NATIVE_UNELEVATED="${WOOTC_E2E_NATIVE_UNELEVATED:-1}"', runner)

    def test_only_an_unelevated_native_run_drops_the_task_run_level(self):
        for frontend, unelevated, want in (('native', '1', 'LIMITED'), ('native', '0', 'HIGHEST'),
                                           ('wails', '1', 'HIGHEST'), ('wails', '', 'HIGHEST')):
            result = shell('gui_task_runlevel', GUI_FRONTEND=frontend, NATIVE_UNELEVATED=unelevated)
            self.assertEqual(result.stdout.strip(), want, (frontend, unelevated))

    def test_an_unelevated_launcher_is_readable_without_administrators(self):
        # Run 38888315334: the /RL LIMITED task could not read
        # C:\\wootc\\launch-gui.cmd (SYSTEM and Administrators only, and a
        # limited token holds Administrators deny-only), so it exited 1 and
        # the shell never started.
        state = (ROOT / 'tests/e2e/state-trust.ps1').read_text()
        self.assertIn("'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'", state)
        limited = shell('gui_launcher_path', GUI_FRONTEND='native', NATIVE_UNELEVATED='1').stdout.strip()
        self.assertFalse(limited.lower().startswith('c:\\wootc\\'), limited)
        ps = shell('gui_launcher_ps', GUI_FRONTEND='native', NATIVE_UNELEVATED='1').stdout
        self.assertIn(f"$launcher = '{limited}'", ps)
        self.assertIn('(A;OICI;0x1200a9;;;BU)', ps)   # Users: read and execute only
        self.assertNotIn(';;;BU)(', ps.replace('(A;OICI;0x1200a9;;;BU)', ''))
        # The elevated launches keep their launcher where it was.
        for frontend, unelevated in (('native', '0'), ('wails', '1')):
            self.assertEqual(shell('gui_launcher_path', GUI_FRONTEND=frontend, NATIVE_UNELEVATED=unelevated).stdout.strip(),
                             'C:\\wootc\\launch-gui.cmd')
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        self.assertIn('"@ | Set-Content -Path $launcher -Encoding ascii', runner)
        self.assertIn('/TR $launcher /RU $who /IT /RL $rl /F', runner)
        self.assertNotIn('/TR C:\\wootc\\launch-gui.cmd', runner)

    def test_the_launcher_sets_drive_mode_to_exactly_1(self):
        # cmd.exe keeps trailing spaces: "set WOOTC_E2E_DRIVE=1 && start ..."
        # stores "1 ", and MainWindow compares the value with "1". The
        # launcher must set each switch on its own line with nothing after it.
        # (The launch post-mortem joins the file's lines with " && " only
        # for display.)
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        start = runner.index('Write-Output ("launcher: " + $launcher)\n@"\n')
        body = runner[start:runner.index('"@ | Set-Content -Path $launcher -Encoding ascii', start)].split('\n')[2:]
        self.assertEqual(body[:2], ['set WOOTC_E2E_DRIVE=1', 'set WOOTC_PRELOAD=0'])
        self.assertTrue(body[2].startswith('start '), body)
        self.assertFalse(any(line != line.rstrip() or '&&' in line for line in body), body)
        main = (ROOT / 'shell/Wootc.Shell/MainWindow.xaml.cs').read_text()
        self.assertIn('Environment.GetEnvironmentVariable("WOOTC_E2E_DRIVE") == "1"', main)

    def test_the_installer_is_the_one_for_this_build_and_brand(self):
        with tempfile.TemporaryDirectory() as tmp:
            call = 'gui_native_installer_file "$DIR" bluefin ' + BUILD
            self.assertNotEqual(shell(call, DIR=tmp).returncode, 0)
            want = Path(tmp) / f'bluefin-native-preview-{BUILD}.exe'
            want.write_bytes(b'MZ')
            result = shell(call, DIR=tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(want))
            # Another brand's or build's installer is not this run's.
            self.assertNotEqual(shell('gui_native_installer_file "$DIR" bazzite ' + BUILD, DIR=tmp).returncode, 0)
            self.assertNotEqual(shell('gui_native_installer_file "$DIR" bluefin ' + '1' * 40, DIR=tmp).returncode, 0)
            # Two candidates are ambiguous; an empty file is no installer.
            (Path(tmp) / 'other.exe').write_bytes(b'MZ')
            self.assertNotEqual(shell(call, DIR=tmp).returncode, 0)
            (Path(tmp) / 'other.exe').unlink()
            want.write_bytes(b'')
            self.assertNotEqual(shell(call, DIR=tmp).returncode, 0)

    def test_the_installer_name_matches_preview_iss(self):
        iss = (ROOT / 'shell/packaging/preview.iss').read_text()
        self.assertIn('OutputBaseFilename={#BrandId}-native-preview-{#BuildId}', iss)
        self.assertIn('AppId=wootc-native-preview-{#BrandId}', iss)


class IntegrityTests(unittest.TestCase):
    SID = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    BUNDLE = 'C:\\Program Files\\wootc Native Preview\\bluefin\\bundle\\'
    GOOD = '\r\n'.join([
        f'native-integrity: role=shell pid=4100 rid=0x2000 elevated=0 sid={SID} path={BUNDLE}Wootc.Shell.exe',
        f'native-integrity: role=engine-config pid=4200 rid=0x3000 elevated=1 sid={SID} path={BUNDLE}wootc-engine.exe',
        f'native-integrity: role=engine-install pid=4300 rid=0x3000 elevated=1 sid={SID} path={BUNDLE}wootc-engine.exe',
        'native-integrity-done', ''])

    def proven(self, fn, out):
        return shell(f'{fn} "$OUT"', OUT=out, NATIVE_BRAND='bluefin').returncode

    def test_the_split_passes(self):
        self.assertEqual(self.proven('gui_native_shell_unelevated_proven', self.GOOD), 0)
        self.assertEqual(self.proven('gui_native_engine_elevated_proven', self.GOOD), 0)

    def test_an_elevated_shell_is_not_unelevated(self):
        # Exactly what the /RL HIGHEST launch of run 38857241312 would print.
        out = self.GOOD.replace('pid=4100 rid=0x2000 elevated=0', 'pid=4100 rid=0x3000 elevated=1')
        self.assertNotEqual(self.proven('gui_native_shell_unelevated_proven', out), 0)
        out = self.GOOD.replace('pid=4100 rid=0x2000 elevated=0', 'pid=4100 rid=0x2000 elevated=1')
        self.assertNotEqual(self.proven('gui_native_shell_unelevated_proven', out), 0)

    def test_the_engine_must_be_the_install_session_elevated_for_the_same_user(self):
        no_install = '\r\n'.join(l for l in self.GOOD.split('\r\n') if 'engine-install' not in l)
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', no_install), 0)
        medium = self.GOOD.replace('pid=4300 rid=0x3000 elevated=1', 'pid=4300 rid=0x2000 elevated=0')
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', medium), 0)
        other = self.GOOD.replace(f'pid=4300 rid=0x3000 elevated=1 sid={self.SID}',
                                  'pid=4300 rid=0x3000 elevated=1 sid=S-1-5-21-9-9-9-500')
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', other), 0)
        system = self.GOOD.replace('pid=4300 rid=0x3000', 'pid=4300 rid=0x4000')
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', system), 0)
        stray = self.GOOD.replace(f'pid=4300 rid=0x3000 elevated=1 sid={self.SID} path={self.BUNDLE}',
                                  f'pid=4300 rid=0x3000 elevated=1 sid={self.SID} path=C:\\Users\\wootc\\')
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', stray), 0)

    def test_silence_or_an_unreadable_token_proves_nothing(self):
        for fn in ('gui_native_shell_unelevated_proven', 'gui_native_engine_elevated_proven'):
            self.assertNotEqual(self.proven(fn, ''), 0)
            self.assertNotEqual(self.proven(fn, self.GOOD.replace('native-integrity-done', '')), 0)
            unreadable = self.GOOD.replace(f'rid=0x2000 elevated=0 sid={self.SID} path=', 'error=token-5 path=')
            self.assertNotEqual(self.proven(fn, unreadable), 0)

    def test_two_shells_are_refused(self):
        two = self.GOOD.replace('native-integrity-done', self.GOOD.split('\r\n')[0].replace('4100', '4101') + '\r\nnative-integrity-done')
        self.assertNotEqual(self.proven('gui_native_shell_unelevated_proven', two), 0)
        self.assertNotEqual(self.proven('gui_native_engine_elevated_proven', two), 0)

    def test_the_probe_reads_the_mandatory_label_and_the_install_purpose(self):
        probe = shell('gui_native_integrity_ps').stdout
        self.assertIn('Query(token, 25)', probe)          # TokenIntegrityLevel
        self.assertIn('Query(token, 20)', probe)          # TokenElevation
        self.assertIn('--purpose\\s+install', probe)
        self.assertIn('native-integrity-done', probe)
        self.assertNotIn("'@\n}", probe.replace("'@\n}\nforeach", ''))  # one here-string, closed at column 0
        runas = (ROOT / 'shell/Wootc.Shell.Native/RunasLaunch.cs').read_text()
        self.assertIn('start.ArgumentList.Add("--purpose"); start.ArgumentList.Add("install");', runas)

    def test_an_unelevated_run_requires_both_assertions(self):
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        self.assertIn('RESULT_REQUIRED="$RESULT_REQUIRED,native-shell-unelevated,native-engine-elevated"', runner)
        module = MODULE.read_text()
        self.assertIn('product_pass native-shell-unelevated ', module)
        self.assertIn('product_pass native-engine-elevated ', module)


class WaitArtifactTests(unittest.TestCase):
    SCRIPT = ROOT / '.github/scripts/wait-run-artifact.sh'

    def run_with(self, answers, *names, budget='0'):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / 'gh'
            # Answers the artifact count per name from $ANSWERS (name=count;...).
            fake.write_text('#!/usr/bin/env bash\n'
                            'for a in "$@"; do case "$a" in name=*) n=${a#name=} ;; esac; done\n'
                            'v=$(printf "%s" "$ANSWERS" | tr ";" "\\n" | sed -n "s/^$n=//p")\n'
                            '[ "$v" = error ] && exit 1\n'
                            'echo "${v:-0}"\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f'{tmp}:{os.environ["PATH"]}', ANSWERS=answers,
                       GITHUB_REPOSITORY='o/r', GITHUB_RUN_ID='1', WAIT_RUN_ARTIFACT_INTERVAL='0')
            return subprocess.run(['bash', str(self.SCRIPT), budget, *names], env=env, text=True, capture_output=True)

    def test_the_first_present_name_is_printed(self):
        result = self.run_with('a=0;b=1', 'a', 'b')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'b')

    def test_absence_and_api_errors_time_out(self):
        result = self.run_with('a=0', 'a')
        self.assertEqual(result.returncode, 1)
        result = self.run_with('a=error', 'a')
        self.assertEqual(result.returncode, 1)
        self.assertIn('listing artifacts failed', result.stderr)

    def test_bad_arguments(self):
        self.assertEqual(self.run_with('', 'a', budget='soon').returncode, 2)
        self.assertEqual(self.run_with('').returncode, 2)


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


class ResultContractTests(unittest.TestCase):
    def test_every_optional_assertion_the_runner_requires_is_a_known_contract(self):
        # run 38884385205 refused at startup: results.py rejected
        # native-shell-unelevated as an unknown optional assertion.
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        names = set()
        for value in re.findall(r'RESULT_REQUIRED="?([^"\s;]+)"?', runner):
            names.update(n for n in value.split(',') if n and not n.startswith('$'))
        self.assertTrue({'gui-install', 'native-shell', 'native-shell-unelevated', 'native-engine-elevated'} <= names, names)
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['python3', str(ROOT / 'tests/e2e/lib/results.py'), 'init', str(Path(tmp) / 'l.jsonl'),
                                     'run-1', '--scenario', 'full-cycle', '--required', ','.join(sorted(names))],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class WorkflowTests(unittest.TestCase):
    def job(self, name):
        start = WORKFLOW.index(f'\n  {name}:\n')
        end = re.search(r'\n  [\w-]+:\n', WORKFLOW[start + 1:])
        return WORKFLOW[start:start + 1 + end.start()] if end else WORKFLOW[start:]

    def test_the_installer_is_compiled_on_windows_around_the_e2e_engine(self):
        native = self.job('native-shell')
        self.assertIn('runs-on: windows-latest', native)
        self.assertIn('wait-run-artifact.sh 14400 "$NATIVE_ENGINE_ARTIFACT"', native)
        self.assertIn('python tests/e2e/native-package.py check out/native-shell', native)
        self.assertIn('./shell/packaging/compile-preview.ps1 -BrandId $env:BRAND', native)
        # Only an unavailable compiler may fall back, and it says so.
        self.assertIn("-notlike 'INNO-UNAVAILABLE:*') { throw }", native)
        self.assertIn('::warning::', native)
        # The signing seed never leaves the e2e job.
        self.assertNotIn('signmanifest', native)
        self.assertNotIn('MANIFEST_KEY', native)

    def test_the_e2e_job_hands_over_only_the_engine_and_manifest(self):
        e2e = self.job('e2e')
        self.assertNotIn('\n    needs:', e2e)
        upload = e2e[e2e.index('cp "$pkg/wootc-engine.exe" "$pkg/native-package.json" "$RUNNER_TEMP/native-engine/"'):]
        self.assertNotIn('seed', upload[:upload.index('- id: native_engine')])
        self.assertIn('echo "WOOTC_E2E_NATIVE_INSTALLER=inno" >> "$GITHUB_ENV"', e2e)
        self.assertIn('echo "WOOTC_E2E_NATIVE_INSTALLER=robocopy" >> "$GITHUB_ENV"', e2e)
        self.assertIn('::error::the native-shell job did not produce the preview installer', e2e)
        self.assertIn("WOOTC_E2E_NATIVE_UNELEVATED: ${{ inputs.native_unelevated && '1' || '0' }}", e2e)

    def test_callers_grant_artifact_listing(self):
        for name in ('e2e-nightly.yml', 'e2e-gui.yml', 'e2e-matrix.yml', 'release.yml'):
            text = (ROOT / '.github/workflows' / name).read_text()
            top = text[text.index('\npermissions:'):text.index('\njobs:')]
            self.assertIn('actions: read', top, name)

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
