#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('fixture_receipt', ROOT / 'tests/e2e/fixture-bitlocker-receipt.py')
RECEIPT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIPT)
FINAL = dict(schemaVersion=1, mountPoint='C:', volumeStatus='FullyEncrypted', percentage=100,
             protection='On', tpmPresent=True, tpmReady=True, ready=True,
             protectors=[{'id': '11111111-1111-1111-1111-111111111111', 'type': 'RecoveryPassword'},
                         {'id': '22222222-2222-2222-2222-222222222222', 'type': 'Tpm'}])
BEFORE = {key: value for key, value in FINAL.items() if key != 'ready'}
BEFORE.update(stage='before', protection='Off')


class ActivationRunnerTests(unittest.TestCase):
    def test_native_receipt_requires_actual_safe_protected_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt'
            def write(final):
                path.write_text('bitlocker-fixture-metadata ' + json.dumps(BEFORE) + '\n' + json.dumps(final) + '\n')
            write(FINAL)
            RECEIPT.validate(path)
            mutations = []
            for field, value in [('protection', 'Off'), ('ready', 'True'), ('tpmReady', False),
                                 ('mountPoint', 'F:'), ('percentage', '100'), ('schemaVersion', True)]:
                final = copy.deepcopy(FINAL)
                final[field] = value
                mutations.append(final)
            for protectors in [[], FINAL['protectors'][:1], [FINAL['protectors'][0]] * 2,
                               [dict(FINAL['protectors'][0], recoveryPassword='synthetic-extra'), FINAL['protectors'][1]]]:
                final = copy.deepcopy(FINAL)
                final['protectors'] = protectors
                mutations.append(final)
            for final in mutations:
                write(final)
                with self.assertRaises((ValueError, TypeError)):
                    RECEIPT.validate(path)
            path.write_text(json.dumps(FINAL) + '\n')
            with self.assertRaises(ValueError):
                RECEIPT.validate(path)

    def test_receipt_preserves_initial_identities_and_rejects_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt'
            def write(before, final=FINAL):
                path.write_text('bitlocker-fixture-metadata ' + json.dumps(before) + '\n' + json.dumps(final) + '\n')
            for protectors in [None, [], FINAL['protectors'][:1], FINAL['protectors'][1:]]:
                before = copy.deepcopy(BEFORE)
                before['protectors'] = protectors
                write(before)
                RECEIPT.validate(path)
            for index in [0, 1]:
                final = copy.deepcopy(FINAL)
                final['protectors'][index]['id'] = '33333333-3333-3333-3333-333333333333'
                write(BEFORE, final)
                with self.assertRaises(ValueError):
                    RECEIPT.validate(path)
            for protectors in [[FINAL['protectors'][0]] * 2,
                               [dict(FINAL['protectors'][0], type='Unknown')],
                               [dict(FINAL['protectors'][0], extra='unexpected')],
                               [dict(FINAL['protectors'][0], id='invalid')]]:
                before = copy.deepcopy(BEFORE)
                before['protectors'] = protectors
                write(before)
                with self.assertRaises(ValueError):
                    RECEIPT.validate(path)
            write(BEFORE)
            path.write_text(path.read_text().replace('"ready": true', '"ready": false, "ready": true'))
            with self.assertRaises(ValueError):
                RECEIPT.validate(path)

    def run_case(self, case):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            (p / 'now').write_text('100')
            (p / 'receipt').write_text('bitlocker-fixture-metadata ' + json.dumps(BEFORE) + '\n' + json.dumps(FINAL) + '\n')
            body = r'''set -euo pipefail
SCRIPT_DIR="$1/tests/e2e"; ARTIFACT_DIR="$2"; RUN_ID=current-run; case_name="$3"
source "$SCRIPT_DIR/lib/diagnostics.sh"
source "$SCRIPT_DIR/lib/fixture-bitlocker.sh"
date() { cat "$ARTIFACT_DIR/now"; }
deadline_in() { echo $(( $(date) + $1 )); }
past_deadline() { [ "$(date)" -ge "$1" ]; }
sleep() { echo $(( $(date) + $1 )) > "$ARTIFACT_DIR/now"; }
info() { :; }; pass() { :; }; fail() { :; }; infra_fail() { :; }
qga_windows_probe() { [ "$case_name" != wrong-identity ]; }
fixture_verify_windows_boot_after_detach() {
 [ "$1" -eq 120 ] && [ "$(cat "$ARTIFACT_DIR/reads")" -eq 2 ] || return 1
 printf '%s\n' observed >> "$ARTIFACT_DIR/optical-current-reads"
 case "$case_name" in reinserted-optical|optical-query-failure|optical-wrong-boot|optical-deadline) return 1 ;; esac
}
qga_powershell() {
 remaining=$((120-$(date)))
 [ "$WOOTC_QGA_CALL_TIMEOUT" -le "$remaining" ] || return 90
 printf '%s\n' "$1" >> "$ARTIFACT_DIR/calls"
 if [[ "$1" == *Get-WootcFixtureBitLockerReadiness* ]]; then
   count=$(cat "$ARTIFACT_DIR/reads" 2>/dev/null || echo 0); count=$((count+1)); echo "$count" > "$ARTIFACT_DIR/reads"
   if [ "$case_name" = conversion-late ]; then echo 120 > "$ARTIFACT_DIR/now"; fi
   if [ "$count" -eq 1 ] && [ "$case_name" != conversion-late ]; then
     echo 'bitlocker-fixture status=EncryptionInProgress percentage=94 protection=Off ready=False'
   elif [ ! -e "$ARTIFACT_DIR/activated" ] || [ "$case_name" = final-off ]; then
     echo 'bitlocker-fixture status=FullyEncrypted percentage=100 protection=Off ready=False'
   else echo 'bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=True'; fi
 elif [[ "$1" == *Get-PSDrive* ]]; then
   # Model C: staging plus F: actual disk from the real issued predicate.
   [[ "$1" == *'-PathType Leaf'* && "$1" == *'wootc\disks\root.disk'* ]] || { echo CF; return; }
   if [ "$case_name" = ambiguous-root ]; then echo CF; else echo F; fi
 elif [[ "$1" == *Initialize-WootcFixtureBitLockerProtection* ]]; then
   printf '%s\n' called >> "$ARTIFACT_DIR/activated"
   if [ "$case_name" = activation-timeout ]; then echo 120 > "$ARTIFACT_DIR/now"; return 124; fi
   if [ "$case_name" = activation-failure ]; then return 1; fi
   if [ "$case_name" = missing-receipt ]; then echo 'guest-ping alive'; else cat "$ARTIFACT_DIR/receipt"; fi
 else return 99; fi
}
bitlocker_prepare_fixture 20
echo SCHEDULED
'''
            result = subprocess.run(['bash', '-c', body, 'test', str(ROOT), directory, case], capture_output=True, text=True)
            files = {f.name: f.read_text() for f in p.iterdir()}
            return result, files

    def test_actual_production_preparation_activates_once_then_reads_on(self):
        result, files = self.run_case('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SCHEDULED', result.stdout)
        self.assertEqual(files['activated'].splitlines(), ['called'])
        self.assertEqual(files['reads'].strip(), '3')
        self.assertEqual(files['optical-current-reads'].splitlines(), ['observed'])
        self.assertIn("-RecoveryKeyPath 'F:\\wootc\\install\\bitlocker-key.txt'", files['calls'])
        self.assertEqual(files['bitlocker-activation-run-id.txt'].strip(), 'current-run')

    def test_counterexamples_never_schedule_or_replay_activation(self):
        for case in ['wrong-identity', 'ambiguous-root', 'conversion-late', 'activation-timeout',
                     'activation-failure', 'missing-receipt', 'final-off', 'reinserted-optical', 'optical-query-failure', 'optical-wrong-boot', 'optical-deadline']:
            result, files = self.run_case(case)
            with self.subTest(case=case):
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('SCHEDULED', result.stdout)
                self.assertLessEqual(len(files.get('activated', '').splitlines()), 1)
                if case in ['wrong-identity', 'ambiguous-root', 'conversion-late', 'reinserted-optical', 'optical-query-failure', 'optical-wrong-boot', 'optical-deadline']:
                    self.assertNotIn('activated', files)


if __name__ == '__main__':
    unittest.main()
