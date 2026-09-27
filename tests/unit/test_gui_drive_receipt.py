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

    def test_actual_frontend_produces_bound_install_and_refuses_changed_identity(self):
        result = subprocess.run(['node', str(ROOT / 'tests/unit/gui-drive-producer-controls.cjs'),
                                 str(ROOT / 'app/frontend/src/lib/e2e.js')], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = json.loads(result.stdout)
        self.assertEqual(proof['controls'], 7)
        raw = json.dumps(proof['installReceipt'])
        receipt = json.loads(module.validate(raw, 'current', DIRECTIVE, IMAGE))
        self.assertEqual(receipt['screen'], 'done')
        self.assertTrue(receipt['installDriven'])
        with self.assertRaises(ValueError):
            module.validate(json.dumps(proof['thrownClickReceipt']), 'current', DIRECTIVE, IMAGE)
        # The actual old flag ordering turns that thrown click into 'driven'.
        source=(ROOT / 'app/frontend/src/lib/e2e.js').read_text()
        fixed='installButton.click();\n    window.__e2eInstallDriven = true;'
        self.assertIn(fixed,source)
        with tempfile.TemporaryDirectory() as tmp:
            mutant=Path(tmp)/'old-click.js'
            mutant.write_text(source.replace(fixed,'window.__e2eInstallDriven = true;\n    installButton.click();',1))
            result=subprocess.run(['node', str(ROOT/'tests/unit/gui-drive-producer-controls.cjs'), str(mutant)],text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('AssertionError',result.stderr)

    def test_actual_cli_accepts_current_consistent_install(self):
        result = subprocess.run(['python3', str(PARSER), RUN, DIRECTIVE, IMAGE],
                                input=self.receipt(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['screen'], 'done')

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


if __name__ == '__main__':
    unittest.main()
