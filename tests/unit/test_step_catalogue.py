import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('generate_steps', ROOT / 'packaging/generate-steps.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'payload').mkdir()
        shutil.copyfile(ROOT / 'payload/steps.tsv', self.root / 'payload/steps.tsv')

    def tearDown(self):
        self.temp.cleanup()

    def generate(self, check=False):
        return subprocess.run(['python3', str(ROOT / 'packaging/generate-steps.py'), '--root', str(self.root)] +
                              (['--check'] if check else []), capture_output=True, text=True)

    def test_exact_generation_and_each_stale_output_fails_read_only(self):
        self.assertEqual(self.generate().returncode, 0)
        self.assertEqual(self.generate(True).returncode, 0)
        rows = generator.read_catalogue(self.root / 'payload/steps.tsv')
        for name in generator.outputs(rows):
            path = self.root / name
            original = path.read_text()
            path.write_text(original + '\n# stale mutation\n')
            with self.subTest(name=name):
                result = self.generate(True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertEqual(path.read_text(), original + '\n# stale mutation\n')
            path.write_text(original)

    def test_changed_catalogue_labels_invalidate_all_label_consumers(self):
        self.assertEqual(self.generate().returncode, 0)
        path = self.root / 'payload/steps.tsv'
        original = path.read_text()
        path.write_text(original.replace('Checking your PC\tinstaller\tChecking your PC',
                                         'Checking your PC\tinstaller\tA different installer label')
                       .replace('fisherman\tdeployer\tInstalling your Linux system...',
                                'fisherman\tdeployer\tA different deployer label'))
        result = self.generate(True)
        self.assertNotEqual(result.returncode, 0)
        for name in ['app/steps_gen.go', 'payload/steps.sh', 'tests/e2e/steps.sh', 'tests/gui/step-catalogue-gen.js']:
            self.assertIn(name, result.stderr)
        self.assertEqual(self.generate().returncode, 0)
        command = '. "$1"; wootc_step_label fisherman; wootc_step_label "Checking your PC"'
        for name in ['payload/steps.sh', 'tests/e2e/steps.sh']:
            output = subprocess.check_output(['bash', '-c', command, 'label-consumer', str(self.root / name)], text=True)
            self.assertEqual(output.splitlines(), ['A different deployer label', 'A different installer label'])

    def test_schema_rejects_duplicate_missing_label_bad_owner_and_missing_firstboot(self):
        path = self.root / 'payload/steps.tsv'
        original = path.read_text()
        for content in [original + 'fisherman\tdeployer\tDuplicate\n',
                        original + 'extra\tdeployer\t\n', original + 'extra\twrong\tLabel\n',
                        '\n'.join(line for line in original.splitlines() if '\tfirstboot\t' not in line)]:
            path.write_text(content)
            with self.subTest(content=content[-80:]), self.assertRaises(ValueError):
                generator.read_catalogue(path)

    def test_harness_ledger_rejects_unknown_and_uses_real_observed_generated_label(self):
        path = self.root / 'payload/steps.tsv'
        path.write_text(path.read_text().replace('fisherman\tdeployer\tInstalling your Linux system...',
                                                'fisherman\tdeployer\tChanged harness label'))
        self.assertEqual(self.generate().returncode, 0)
        ledger = self.root / 'phase-ledger.jsonl'
        script = '''source "$1"; source "$2"
WOOTC_PHASE_LEDGER="$3"; RUN_ID=test-run
wootc_phase_observe_output $'guest-ping is alive; phase: fisherman-extra\\n' || exit 1
[ ! -e "$WOOTC_PHASE_LEDGER" ] || exit 2
wootc_phase_observe_output $'[wootc] phase: fisherman\\n' || exit 3
wootc_phase_record failed "$WOOTC_CURRENT_PHASE_ID" 'test failure' || exit 4
if wootc_phase_record failed invented 'wrong'; then exit 5; fi
if wootc_phase_record passed fisherman 'proxy completion'; then exit 6; fi
'''
        subprocess.run(['bash', '-c', script, 'ledger-consumer', str(self.root / 'tests/e2e/steps.sh'),
                        str(ROOT / 'tests/e2e/phase-ledger.sh'), str(ledger)], check=True)
        import json
        records = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual([record['kind'] for record in records], ['observed', 'failed'])
        for record in records:
            self.assertEqual(record['phaseId'], 'fisherman')
            self.assertEqual(record['label'], 'Changed harness label')
            self.assertEqual(record['owner'], 'deployer')
            self.assertEqual(record['runId'], 'test-run')

    def test_chunked_marker_and_boot_boundaries_cannot_reuse_stale_phase(self):
        self.assertEqual(self.generate().returncode, 0)
        ledger = self.root / 'chunk-ledger.jsonl'
        runner = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        probe = 'source "' + str(ROOT / 'tests/e2e/lib/qga-transport.sh') + '"\n'
        script = r'''source "$1"; source "$2"
WOOTC_PHASE_LEDGER="$3"; RUN_ID=test-run
wootc_phase_observe_output $'[wootc] phase: fisherman\n' || exit 1
[ "$WOOTC_CURRENT_PHASE_ID" = fisherman ] || exit 2
wootc_phase_observe_output '[wootc] phase: verifi' || exit 3
[ -z "$WOOTC_CURRENT_PHASE_ID" ] || exit 4
wootc_phase_observe_output $'cation\n' || exit 5
[ "$WOOTC_CURRENT_PHASE_ID" = verification ] || exit 6
wootc_phase_observe_output 'phase: stale-fragment' || exit 7
wootc_phase_boundary
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY" ] || exit 8
wootc_phase_observe_output $'phase: firstboot-evidence\n' || exit 9
[ "$WOOTC_CURRENT_PHASE_ID" = firstboot-evidence ] || exit 10
''' + probe + r'''
qga_powershell() { printf '%s\n' Windows_NT; }
qga_windows_probe || exit 11
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY" ] || exit 12
wootc_phase_observe_output "$(printf '%4097s' x)" && exit 13
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY" ] || exit 14
exit 0
'''
        subprocess.run(['bash', '-c', script, 'chunk-consumer', str(self.root / 'tests/e2e/steps.sh'),
                        str(ROOT / 'tests/e2e/phase-ledger.sh'), str(ledger)], check=True)
        import json
        ids = [json.loads(line)['phaseId'] for line in ledger.read_text().splitlines()]
        self.assertEqual(ids, ['fisherman', 'verification', 'firstboot-evidence'])
        boundary = runner.index('wootc_phase_boundary\nstep "Scheduling one-shot Phase 2 Linux boot..."')
        firstboot_failure = runner.index('fail "User data NOT visible in Phase 2')
        self.assertLess(boundary, firstboot_failure)

    def test_actual_deployer_consumer_uses_regenerated_labels(self):
        path = self.root / 'payload/steps.tsv'
        path.write_text(path.read_text().replace('fisherman\tdeployer\tInstalling your Linux system...',
                                                'fisherman\tdeployer\tChanged actual splash words'))
        self.assertEqual(self.generate().returncode, 0)
        deploy = (ROOT / 'payload/deployer/deploy.sh').read_text()
        start = deploy.index('phase() {')
        end = deploy.index('\n}', start) + 2
        phase = deploy[start:end].replace('/run/wootc-phase', str(self.root / 'actual-phase'))
        script = 'source "$1"; log() { :; }; splash_set() { printf "%s\\n" "$1"; };\n' + phase + '\nphase fisherman'
        result = subprocess.run(['bash', '-c', script, 'actual-splash', str(self.root / 'payload/steps.sh')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'Changed actual splash words')


    def test_actual_firstboot_consumer_preserves_state_and_records_generated_phase(self):
        path = self.root / 'payload/steps.tsv'
        path.write_text(path.read_text().replace('firstboot-evidence\tfirstboot\tVerifying your installed Linux boot...',
                                                'firstboot-evidence\tfirstboot\tChanged firstboot label'))
        self.assertEqual(self.generate().returncode, 0)
        host = self.root / 'host'
        host.mkdir()
        fakebin = self.root / 'bin'
        fakebin.mkdir()
        (fakebin / 'mountpoint').write_text('#!/bin/sh\nexit 0\n')
        writer = fakebin / 'wootc-ntfs-state-write'
        writer.write_text('#!/usr/bin/env python3\nimport pathlib,sys\npathlib.Path(sys.argv[2]).write_text(sys.stdin.read())\n')
        for fake in fakebin.iterdir():
            fake.chmod(0o755)
        import os,json
        env = {**os.environ, 'WOOTC_STEPS_FILE': str(self.root / 'payload/steps.sh'),
               'WOOTC_FIRSTBOOT_HOST': str(host), 'PATH': str(fakebin) + ':' + os.environ['PATH']}
        result = subprocess.run(['bash', str(ROOT / 'payload/migration/wootc-firstboot-evidence')],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('phase: firstboot-evidence', result.stdout)
        self.assertIn('Changed firstboot label', result.stdout)
        state = json.loads((host / 'wootc/state.json').read_text())
        evidence = json.loads((host / 'wootc/install/installed-linux-boot.json').read_text())
        self.assertEqual(state['state'], 'healthy')
        self.assertNotIn('phaseId', state)
        self.assertEqual(evidence['phaseId'], 'firstboot-evidence')
        self.assertEqual(evidence['state'], 'healthy')
        env['WOOTC_STEPS_FILE'] = str(self.root / 'missing-catalogue')
        missing = subprocess.run(['bash', str(ROOT / 'payload/migration/wootc-firstboot-evidence')],
                                 env=env, capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotIn('phase: firstboot-evidence', missing.stdout)


    def test_actual_serial_reader_preserves_partial_lines_and_rejects_read_failure(self):
        self.assertEqual(self.generate().returncode, 0)
        serial = self.root / 'serial.log'
        serial.write_text('[wootc] phase: verification\n')
        ledger = self.root / 'serial-ledger.jsonl'
        script = r'''source "$1"; source "$2"
WOOTC_PHASE_LEDGER="$3"; RUN_ID=test-run
wootc_phase_read_serial_chunk "$4" 0 22 || exit 1
[ -z "$WOOTC_CURRENT_PHASE_ID" ] || exit 2
[ -n "$WOOTC_PHASE_CARRY" ] || exit 3
wootc_phase_read_serial_chunk "$4" 22 28 || exit 4
[ "$WOOTC_CURRENT_PHASE_ID" = verification ] || exit 5
[[ "$NEW_OUTPUT" == *$'\n' ]] || exit 6
wootc_phase_read_serial_chunk "$4-missing" 0 22 && exit 7
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY$NEW_OUTPUT" ] || exit 8
wootc_phase_read_serial_chunk "$4" 28 0 && exit 9
wootc_phase_read_serial_chunk "$4" 0 29 && exit 10
# Simulate truncation after stat: successful dd returns fewer bytes.
WOOTC_CURRENT_PHASE_ID=verification
dd() { printf 'short'; }
wootc_phase_read_serial_chunk "$4" 0 28 && exit 11
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY$NEW_OUTPUT" ] || exit 12
# Also ensure a dd failure cannot be hidden by the newline sentinel.
dd() { return 1; }
wootc_phase_read_serial_chunk "$4" 0 28 && exit 13
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY$NEW_OUTPUT" ] || exit 14
exit 0
'''
        subprocess.run(['bash', '-c', script, 'serial-reader', str(self.root / 'tests/e2e/steps.sh'),
                        str(ROOT / 'tests/e2e/phase-ledger.sh'), str(ledger), str(serial)], check=True)
        import json
        records = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['phaseId'], 'verification')



if __name__ == '__main__':
    unittest.main()
