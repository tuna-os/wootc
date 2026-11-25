#!/usr/bin/env python3
"""Exercise stale and contradictory reports against the actual host parser."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PARSER = ROOT / 'tests/e2e/gui-drive-receipt.py'
spec = importlib.util.spec_from_file_location('drive_receipt', PARSER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
RUN = '20260927-test'
DIRECTIVE = '1234567890abcdef1234567890abcdef'
IMAGE = 'ghcr.io/tuna-os/yellowfin:gnome'


class GuiDriveReceiptTests(unittest.TestCase):
    def receipt(self, **changes):
        value = dict(schemaVersion=1, runId=RUN, directiveId=DIRECTIVE,
                     action='install', screen='done', installDriven=True,
                     installBtnDisabled=None, hint='', progressStep='armed',
                     error=None, selectedRef=IMAGE, imageMismatch=False)
        value.update(changes)
        return json.dumps(value, separators=(',', ':'))

    def test_actual_runner_read_gate_refuses_failed_or_stale_replies(self):
        source = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        start = source.index("            if drive_raw=$(qga_read 'C:")
        end = source.index('            fi', start) + len('            fi')
        body = source[start:end]
        def run(reply, status, code=body):
            script = '\n'.join(['qga_read() { printf \'%s\' "$CASE_REPLY"; return "$CASE_STATUS"; }', 'drive_state=""', code, 'printf \'%s\' "$drive_state"'])
            env = dict(os.environ, CASE_REPLY=reply, CASE_STATUS=str(status),
                       SCRIPT_DIR=str(PARSER.parent), RUN_ID=RUN, drive_directive_id=DIRECTIVE, IMAGE_REF=IMAGE)
            result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout
        self.assertEqual(json.loads(run(self.receipt(), 0))['screen'], 'done')
        self.assertEqual(run(self.receipt(), 1), '')
        self.assertEqual(run(self.receipt(runId='stale'), 0), '')
        self.assertEqual(run('{"screen":"done"}', 0), '')
        condition = body.splitlines()[0]
        mutation = body.replace(condition, condition.replace('if drive_raw=', 'drive_raw=').replace('; then', ' || true; if true; then'), 1)
        self.assertEqual(json.loads(run(self.receipt(), 1, mutation))['screen'], 'done')

    def test_actual_cli_accepts_current_consistent_install(self):
        result = subprocess.run(['python3', str(PARSER), RUN, DIRECTIVE, IMAGE],
                                input=self.receipt(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['screen'], 'done')

    def test_actual_cli_rejection_names_the_reason_on_stderr(self):
        # The harness keeps validator stderr as the rejection diagnosis (run
        # 36399679919 burned 30m with ~112 unread reads and no reason). A
        # rejection that stays silent here is unobservable there.
        result = subprocess.run(['python3', str(PARSER), RUN, DIRECTIVE, IMAGE],
                                input=self.receipt(runId='stale'), text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('stale or unrelated', result.stderr)

    def test_stale_other_run_directive_action_are_unknown(self):
        for changes in ({'runId': 'old'}, {'directiveId': '0'*32}, {'action': 'reboot'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module.validate(self.receipt(**changes), RUN, DIRECTIVE, IMAGE)

    def test_done_without_click_or_with_error_or_wrong_image_refused(self):
        for changes in ({'installDriven': False}, {'error': 'failed'},
                        {'selectedRef': 'other'}, {'imageMismatch': True}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                module.validate(self.receipt(**changes), RUN, DIRECTIVE, IMAGE)

    def test_actual_old_done_gate_counterexamples_all_refused(self):
        proof = json.loads((ROOT / 'docs/experiments/evidence/2026-09-27-drive-receipt/old-consumer-counterexamples.json').read_text())
        for case in proof['cases']:
            self.assertTrue(case['acceptedByCurrentDoneGate'])
            with self.subTest(case=case['case']), self.assertRaises(ValueError):
                module.validate(case['publicSyntheticInput'], RUN, DIRECTIVE, IMAGE)

    def test_duplicate_fields_refused_even_when_values_match(self):
        for raw in (self.receipt().replace('"screen":"done"', '"screen":"progress","screen":"done"'),
                    self.receipt().replace('"runId":', '"runId":"'+RUN+'","runId":')):
            with self.assertRaises(ValueError):
                module.validate(raw, RUN, DIRECTIVE, IMAGE)

    def test_unknown_missing_wrong_types_refused(self):
        invalid = [self.receipt(schemaVersion=True), self.receipt(installDriven=1),
                   self.receipt(installBtnDisabled=0), self.receipt(error=''),
                   self.receipt(screen='mystery'), self.receipt(hint={}),
                   self.receipt(extra='ignored')]
        value = json.loads(self.receipt()); del value['directiveId']; invalid.append(json.dumps(value))
        for raw in invalid:
            with self.subTest(raw=raw), self.assertRaises((ValueError, TypeError)):
                module.validate(raw, RUN, DIRECTIVE, IMAGE)

    def test_pending_and_explicit_refusal_remain_observations(self):
        for changes in ({'screen': 'progress'}, {'screen': 'launchpad', 'installDriven': False,
                        'imageMismatch': True, 'selectedRef': 'other', 'installBtnDisabled': True}):
            value = json.loads(module.validate(self.receipt(**changes), RUN, DIRECTIVE, IMAGE))
            self.assertNotEqual(value['screen'], 'done')

    def test_actual_cli_rejects_large_invalid_utf8_and_multiple_reports(self):
        for raw in (b'x'*16385, b'\xff', (self.receipt()+self.receipt()).encode()):
            result = subprocess.run(['python3', str(PARSER), RUN, DIRECTIVE, IMAGE], input=raw, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b'')
            self.assertNotIn(raw[:20], result.stderr)

    def test_native_shell_goldens_pass_the_host_parser(self):
        # shell/Wootc.Shell.Tests/E2EDriveTests.cs builds these bytes.
        fixtures = ROOT / 'tests/unit/fixtures/e2e-drive'
        directive = json.loads((fixtures / 'directive-install.json').read_text())
        # The native shell refuses an install directive without a target volume.
        self.assertEqual(directive['storageId'], 'C:')
        for name in ('report-install-ready.json', 'report-install-checking.json', 'report-install-mismatch.json',
                     'report-install-done.json', 'report-install-unknown-target.json'):
            raw = (fixtures / name).read_text()
            module.validate(raw, directive['runId'], directive['directiveId'], directive['image'])

    def test_a_plan_check_in_flight_is_neither_offered_nor_refused(self):
        # Native runs 38923119161 and 38931058878 spent about two minutes in
        # the plan check. The shell reports through it; the harness must read
        # those reports as pending, never as a disabled Install (a refusal).
        fixtures = ROOT / 'tests/unit/fixtures/e2e-drive'
        directive = json.loads((fixtures / 'directive-install.json').read_text())
        raw = (fixtures / 'report-install-checking.json').read_text()
        state = json.loads(module.validate(raw, directive['runId'], directive['directiveId'], directive['image']))
        self.assertIsNone(state['installBtnDisabled'])
        self.assertIsNone(state['error'])
        self.assertFalse(state['installDriven'])
        self.assertTrue(state['hint'].startswith('Checking this plan with the engine ('))

    def test_native_target_refusal_reaches_the_harness_as_an_error(self):
        # The harness fails fast on a non-null error; a refused target must not
        # read as an image mismatch or a silent wait.
        fixtures = ROOT / 'tests/unit/fixtures/e2e-drive'
        directive = json.loads((fixtures / 'directive-install.json').read_text())
        raw = (fixtures / 'report-install-unknown-target.json').read_text()
        state = json.loads(module.validate(raw, directive['runId'], directive['directiveId'], directive['image']))
        self.assertIn('target volume C:', state['error'])
        self.assertFalse(state['imageMismatch'])
        self.assertFalse(state['installDriven'])


if __name__ == '__main__':
    unittest.main()
