import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parents[2]
BACKEND = ROOT / 'tests/e2e/lib/results.py'


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        self.ledger = self.dir / 'results.jsonl'
        self.legacy = self.dir / 'failures.txt'
        self.legacy.write_text('')
        self.marker = self.dir / 'video/.passed'
        self.run = 'test-run'
        self.assertEqual(self.call('init', '--scenario', 'full-cycle').returncode, 0)

    def tearDown(self):
        self.temp.cleanup()

    def call(self, operation, *args, path=None, run=None):
        return subprocess.run(['python3', str(BACKEND), operation, str(path or self.ledger), run or self.run,
                               *args], capture_output=True, text=True)

    def finish(self):
        return self.call('finish', '--legacy', str(self.legacy), '--marker', str(self.marker), '--image', 'test:image')

    def rows(self):
        return [json.loads(line) for line in self.ledger.read_text().splitlines()]

    def assertions(self):
        for identity in ['deployed', 'linux-root', 'linux-proof', 'user-data', 'windows-return', 'healthy']:
            self.assertEqual(self.call('record', '--kind', 'assertion', '--domain', 'product',
                                      '--assertion', identity, '--message', 'observed fixture value').returncode, 0)

    def shell(self, body):
        script = f'''set -Eeuo pipefail
source "{ROOT}/tests/e2e/lib/results.sh"
source "{ROOT}/tests/e2e/lib/result-runner.sh"
RUN_ID=test-run
WOOTC_RESULT_LEDGER="{self.ledger}"
WOOTC_FAILURE_LEDGER="{self.legacy}"
RED=; GREEN=; NC=; YELLOW=
''' + body
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True)

    def test_empty_human_log_and_liveness_cannot_supply_missing_assertions(self):
        self.call('record', '--kind', 'assertion', '--domain', 'infrastructure', '--assertion', 'guest-ping')
        result = self.finish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        terminal = self.rows()[-1]
        self.assertEqual(terminal['productVerdict'], 'unknown')
        self.assertIn('user-data', terminal['missingAssertions'])

    def test_actual_adapter_assertions_commit_terminal_before_marker(self):
        body = '\n'.join('product_pass ' + name + ' "actual adapter observation"' for name in
                         ['deployed', 'linux-root', 'linux-proof', 'user-data', 'windows-return', 'healthy'])
        body += f'\nwootc_result_finish "$WOOTC_RESULT_LEDGER" "$RUN_ID" "$WOOTC_FAILURE_LEDGER" "{self.marker}" test:image'
        result = self.shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[-1]['verdict'], 'passed')
        self.assertEqual(self.marker.read_text(), 'test-run image=test:image\n')
        self.assertNotEqual(self.call('record', '--message', 'mutation after terminal').returncode, 0)

    def test_subshell_infrastructure_failure_remains_unknown_product(self):
        result = self.shell('output=$(infra_fail "channel lost"; echo body); [ "$output" = body ]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')
        self.assertions()
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertEqual(self.rows()[-1]['productVerdict'], 'unknown')
        self.assertFalse(self.marker.exists())

    def test_observed_product_failure_is_distinct_from_runner_failure(self):
        result = self.shell('product_fail "actual file bytes differ"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertions()
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertEqual(self.rows()[-1]['productVerdict'], 'failed')

    def test_actual_err_trap_cannot_lose_abort_with_empty_human_log(self):
        self.assertions()
        body = '''trap 'rc=$?; wootc_result_abort "$WOOTC_RESULT_LEDGER" "$RUN_ID" "$rc"' EXIT
trap 'wootc_report_abort "$?" "$BASH_COMMAND"' ERR
false
'''
        result = self.shell(body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.legacy.read_text(), '')
        self.assertEqual(self.rows()[-2]['kind'], 'failure')
        self.assertEqual(self.rows()[-2]['domain'], 'runner')
        self.assertEqual(self.rows()[-1]['verdict'], 'inconclusive')
        self.assertFalse(self.marker.exists())

    def test_real_init_refuses_devnull_symlink_and_existing_evidence(self):
        self.assertNotEqual(self.call('init', path='/dev/null').returncode, 0)
        self.assertNotEqual(self.call('init').returncode, 0)
        link = self.dir / 'link'
        link.symlink_to('/dev/null')
        self.assertNotEqual(self.call('init', path=link).returncode, 0)

    def test_real_read_refuses_missing_torn_foreign_and_malformed_terminal(self):
        original = self.ledger.read_text()
        for mutation in ['', original[:-1], original.replace('test-run', 'old-run'),
                         original + json.dumps({'kind': 'terminal', 'runId': self.run, 'sequence': 1, 'schemaVersion': 1}) + '\n']:
            self.ledger.write_text(mutation)
            with self.subTest(mutation=mutation):
                self.assertNotEqual(self.finish().returncode, 0)
                self.assertFalse(self.marker.exists())
        self.ledger.unlink()
        self.assertNotEqual(self.finish().returncode, 0)

    def test_real_write_error_cannot_be_suppressed_into_a_pass(self):
        self.assertions()
        self.ledger.chmod(0o400)
        try:
            result = self.shell('if fail "write channel failed"; then exit 99; fi')
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            self.ledger.chmod(0o600)
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertTrue(self.rows()[-1]['humanFailureRecorded'])
        self.assertFalse(self.marker.exists())

    def test_unknown_domain_phase_and_empty_assertion_are_rejected(self):
        for args in [('--domain', 'invented'), ('--kind', 'assertion', '--domain', 'product'),
                     ('--domain', 'product', '--phase', 'healthy')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.call('record', *args).returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_gui_scenario_cannot_skip_actual_done_observation(self):
        self.ledger.unlink()
        self.assertEqual(self.call('init', '--required', 'gui-install').returncode, 0)
        self.assertions()
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertIn('gui-install', self.rows()[-1]['missingAssertions'])
        self.assertFalse(self.marker.exists())

    def test_native_mode_cannot_substitute_windows_return_for_native_boot(self):
        self.ledger.unlink()
        self.assertEqual(self.call('init', '--scenario', 'native-cycle').returncode, 0)
        self.assertions()
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertEqual(self.rows()[-1]['missingAssertions'], ['native-boot', 'native-user-data'])
        self.assertFalse(self.marker.exists())

    def test_recovery_mode_commits_only_after_recovery_assertions(self):
        self.ledger.unlink()
        self.assertEqual(self.call('init', '--scenario', 'recovery').returncode, 0)
        for name in ['recovery-interrupted', 'recovery-retry', 'recovery-uninstall', 'recovery-windows']:
            self.assertEqual(self.call('record', '--kind', 'assertion', '--domain', 'product', '--assertion', name).returncode, 0)
        self.assertEqual(self.call('finish', '--legacy', str(self.legacy)).returncode, 0)
        self.assertEqual(self.rows()[-1]['verdict'], 'passed')
        self.assertFalse(self.marker.exists())

    def test_existing_marker_cannot_be_adopted_as_current_proof(self):
        self.assertions()
        self.marker.parent.mkdir()
        self.marker.write_text('old-run image=old:image\n')
        self.assertNotEqual(self.finish().returncode, 0)
        self.assertEqual(self.marker.read_text(), 'old-run image=old:image\n')
        self.assertNotEqual(self.rows()[-1]['kind'], 'terminal')

    def test_zero_exit_without_committed_completion_is_not_success(self):
        self.assertions()
        self.assertNotEqual(self.call('abort', '--code', '0').returncode, 0)
        self.assertEqual(self.rows()[-1]['verdict'], 'inconclusive')
        self.assertFalse(self.marker.exists())

    def test_actual_entrypoint_missing_cli_fails_before_any_vm_command(self):
        tree = self.dir / 'repo/tests/e2e'
        tree.mkdir(parents=True)
        for name in ['run-e2e.sh', 'steps.sh', 'phase-ledger.sh']:
            shutil.copyfile(ROOT / 'tests/e2e' / name, tree / name)
        shutil.copytree(ROOT / 'tests/e2e/lib', tree / 'lib', ignore=shutil.ignore_patterns('__pycache__'))
        result = subprocess.run(['bash', str(tree / 'run-e2e.sh')], env={**os.environ, 'TMPDIR': str(self.dir),
                                'WOOTC_E2E_RUN_ID': 'entrypoint-run'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Required status CLI missing', result.stderr)
        evidence = list(self.dir.glob('wootc-e2e-results.*.jsonl'))
        self.assertEqual(len(evidence), 1)
        records = [json.loads(line) for line in evidence[0].read_text().splitlines()]
        self.assertTrue(all(r['runId'] == 'entrypoint-run' for r in records))
        self.assertEqual(records[-1]['verdict'], 'inconclusive')
        self.assertFalse((tree / 'storage').exists())


if __name__ == '__main__':
    unittest.main()
