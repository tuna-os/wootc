import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'tests/e2e/lib'


class LayerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        self.ledger = self.folder / 'results.jsonl'
        self.started = self.folder / 'started.json'
        self.state = self.folder / 'state.json'
        now = datetime.datetime.now(datetime.timezone.utc)
        self.earliest = (now - datetime.timedelta(minutes=2)).isoformat()
        self.began = (now - datetime.timedelta(minutes=1)).isoformat()
        self.updated = now.isoformat()
        self.started.write_text(json.dumps({'startedAt': self.began, 'image': 'image-ref', 'version': '0.1.0'}))
        self.state.write_text(json.dumps({'state': 'deployed', 'updatedBy': 'wootc-deployer', 'updatedAt': self.updated}))

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, body, **environment):
        script = '''set -Eeuo pipefail
source "$LIB/results.sh"
source "$LIB/layer-evidence.sh"
wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
''' + body
        return subprocess.run(['bash', '-c', script], env={**os.environ, 'LIB': str(LIB),
            'WOOTC_RESULT_LEDGER': str(self.ledger), 'RUN_ID': 'current-run', 'IMAGE_REF': 'image-ref',
            'RUN_STARTED_AT': self.earliest, 'STARTED': str(self.started), 'STATE': str(self.state),
            **environment}, capture_output=True, text=True, timeout=10)

    def rows(self):
        return [json.loads(line) for line in self.ledger.read_text().splitlines()]

    @staticmethod
    def qga_info():
        return json.dumps({'version': '10.1', 'supported_commands': [
            {'name': name, 'enabled': True} for name in ('guest-info', 'guest-exec', 'guest-exec-status')]})

    def test_source_has_no_guest_request_or_result_mutation(self):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"', 'source', str(LIB / 'layer-evidence.sh')], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'')
        self.assertFalse(self.ledger.exists())

    def test_qga_info_is_only_infrastructure_evidence(self):
        result = self.shell('''qga_call() { [ "$*" = info ] || return 19; printf '%s' "$INFO"; }
wootc_layer_qga
''', INFO=self.qga_info())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[-1]['assertionId'], 'layer-qga-control')
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')
        self.assertEqual(len(self.rows()), 2)

    def test_failed_guest_info_cannot_pass_on_valid_looking_output(self):
        result = self.shell('''qga_call() { printf '%s' "$INFO"; return 42; }
wootc_layer_qga
''', INFO=self.qga_info())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['kind'], 'failure')
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')

    def test_ping_or_disabled_command_inventory_is_not_transport_contract(self):
        result = self.shell('''qga_call() { printf '%s' '{"version":"10","supported_commands":[{"name":"guest-ping","enabled":true}]}'; }
wootc_layer_qga
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['assertionId'], 'layer-qga-control')
        self.assertEqual(self.rows()[-1]['kind'], 'failure')

    def test_stale_oem_marker_never_records_staging(self):
        result = self.shell('wootc_layer_oem old-run\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.rows()), 1)

    def test_current_timestamps_without_reset_and_handoff_are_not_deployment_identity(self):
        result = self.shell('wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')
        self.assertEqual(self.rows()[-1]['kind'], 'failure')

    def test_bound_oem_deployer_observation_never_satisfies_full_cycle(self):
        result = self.shell('''wootc_layer_reset_observed
wootc_layer_oem "$RUN_ID"
wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"
: > "${STATE}.legacy"
wootc_result_finish "$WOOTC_RESULT_LEDGER" "$RUN_ID" "${STATE}.legacy" '' "$IMAGE_REF"
''')
        self.assertNotEqual(result.returncode, 0)
        rows = self.rows()
        self.assertEqual(rows[-2]['assertionId'], 'layer-deployer')
        self.assertEqual(rows[-1]['productVerdict'], 'unknown')
        self.assertIn('deployed', rows[-1]['missingAssertions'])
        self.assertIn('linux-root', rows[-1]['missingAssertions'])

    def test_gui_route_reuses_authenticated_current_result_not_fake_oem(self):
        result = self.shell('''wootc_layer_reset_observed
wootc_result_record "$WOOTC_RESULT_LEDGER" "$RUN_ID" assertion product gui-install '' authenticated-current-receipt
wootc_layer_deployer gui '' "$STARTED" "$STATE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows()[-1]['assertionId'], 'layer-deployer')
        self.assertFalse(any(row.get('assertionId') == 'layer-windows-oem' for row in self.rows()))

    def test_reset_invalidates_older_handoff(self):
        result = self.shell('''wootc_layer_reset_observed
wootc_layer_oem "$RUN_ID"
wootc_layer_reset_observed
wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')

    def test_observed_failed_deployer_is_product_failure_without_raw_error(self):
        self.state.write_text(json.dumps({'state': 'failed', 'updatedBy': 'wootc-deployer',
            'updatedAt': self.updated, 'error': 'password=do-not-publish'}))
        result = self.shell('''wootc_layer_reset_observed
wootc_layer_oem "$RUN_ID"
wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['domain'], 'product')
        self.assertEqual(self.rows()[-1]['kind'], 'failure')
        self.assertEqual(self.rows()[-1]['assertionId'], 'layer-deployer')
        self.assertNotIn('do-not-publish', self.ledger.read_text() + result.stderr)

    def test_wrong_image_refuses_despite_current_oem(self):
        self.started.write_text(json.dumps({'startedAt': self.began, 'image': 'other-image'}))
        result = self.shell('''wootc_layer_reset_observed
wootc_layer_oem "$RUN_ID"
wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')

    def test_stale_future_or_wrong_writer_lifecycle_is_not_current_run_evidence(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        cases = [
            ((now - datetime.timedelta(days=1)).isoformat(), self.updated, 'wootc-deployer'),
            (self.began, (now - datetime.timedelta(days=1)).isoformat(), 'wootc-deployer'),
            (self.began, (now + datetime.timedelta(days=1)).isoformat(), 'wootc-deployer'),
            (self.began, self.updated, 'windows-staging'),
        ]
        for began, updated, writer in cases:
            with self.subTest(began=began, updated=updated, writer=writer):
                self.ledger.unlink(missing_ok=True)
                self.started.write_text(json.dumps({'startedAt': began, 'image': 'image-ref'}))
                self.state.write_text(json.dumps({'state': 'deployed', 'updatedBy': writer, 'updatedAt': updated}))
                result = self.shell('''wootc_layer_reset_observed
wootc_layer_oem "$RUN_ID"
wootc_layer_deployer oem "$RUN_ID" "$STARTED" "$STATE"
''')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.rows()[-1]['domain'], 'infrastructure')


if __name__ == '__main__':
    unittest.main()
