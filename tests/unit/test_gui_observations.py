#!/usr/bin/env python3
"""Actual GUI handover observation callbacks; no guest or VM fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'tests/e2e/lib/gui-observations.sh'

class HandoverTests(unittest.TestCase):
    def run_shell(self, body, module=MODULE, **env):
        prefix = f'''set -Eeuo pipefail
infra_fail() {{ echo "INFRA $*"; }}
qga_call() {{
 printf '%s\\n' "$*" >> "$CALLS"
 case "$1" in
 powershell) printf '%s' "$WINDOWS"; return "$WINDOWS_RC" ;;
 exec) printf '%s' "$LINUX"; return "$LINUX_RC" ;;
 ping) return "$PING_RC" ;;
 esac
}}
source '{module}'
wootc_gui_observations_configure qga_call
'''
        with tempfile.TemporaryDirectory() as tmp:
            calls = Path(tmp) / 'calls'
            calls.touch()
            defaults = dict(WINDOWS='', WINDOWS_RC='1', LINUX='', LINUX_RC='1', PING_RC='0')
            result = subprocess.run(['bash', '-c', prefix+body], capture_output=True, text=True,
                                    timeout=4, env={**os.environ, **defaults, **env, 'CALLS':str(calls)})
            return result, calls.read_text()

    def test_successful_linux_identity_is_distinct_from_channel_loss(self):
        result, calls = self.run_shell('gui_wait_handover 1; echo "$WOOTC_GUI_HANDOVER_OBSERVATION"',
                                       LINUX='Linux\r\n', LINUX_RC='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'linux')
        self.assertNotIn('ping', calls)
        result, _ = self.run_shell('gui_wait_handover 1; echo "$WOOTC_GUI_HANDOVER_OBSERVATION"', PING_RC='42')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), 'transport-unavailable')
        self.assertNotIn('confirmed', result.stdout)

    def test_failed_or_malformed_identity_with_live_ping_never_proves_handover(self):
        for windows, linux, rc in [('Windows_NT', 'Linux', '7'), ('Windows_NT\nnoise','Linux\nnoise','0'), ('','','0')]:
            result, calls = self.run_shell('gui_wait_handover 1; echo PROVEN', WINDOWS=windows,
                                          WINDOWS_RC=rc, LINUX=linux, LINUX_RC=rc)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PROVEN', result.stdout)
            self.assertIn('unknown', result.stdout)
            self.assertIn('ping', calls)

    def test_removed_status_guard_mutant_accepts_failed_linux_token(self):
        source=MODULE.read_text()
        old="if observed=$(wootc_gui_observation_call exec /bin/sh -c 'uname -s' 2>/dev/null); then"
        self.assertIn(old,source)
        with tempfile.TemporaryDirectory() as tmp:
            mutant=Path(tmp)/'mutant.sh'
            mutant.write_text(source.replace(old,old.replace('2>/dev/null);','2>/dev/null || true);'),1))
            body='gui_wait_handover 1; echo PROVEN'
            fixed,_=self.run_shell(body,LINUX='Linux',LINUX_RC='7')
            broken,_=self.run_shell(body,module=mutant,LINUX='Linux',LINUX_RC='7')
            self.assertNotEqual(fixed.returncode,0)
            self.assertNotIn('PROVEN',fixed.stdout)
            self.assertEqual(broken.returncode,0,broken.stderr)
            self.assertIn('PROVEN',broken.stdout)

    def test_positive_windows_is_not_departure(self):
        result, calls = self.run_shell('gui_wait_handover 1; echo PROVEN', WINDOWS='Windows_NT\r\n', WINDOWS_RC='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('windows', result.stdout)
        self.assertNotIn('exec', calls)
        self.assertNotIn('ping', calls)

    def test_invalid_budget_refuses_before_guest_calls(self):
        for budget in ['0', '-1', 'unknown']:
            result, calls = self.run_shell('gui_wait_handover '+budget+'; echo PROVEN')
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, '')

    def test_real_blocking_transport_obeys_whole_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = Path(tmp)/'runtime'
            runtime.write_text('#!/bin/bash\nsleep 20\necho Linux\n')
            runtime.chmod(0o755)
            script = f'''set -Eeuo pipefail
source '{ROOT}/tests/e2e/lib/qga-transport.sh'
source '{MODULE}'
wootc_qga_configure '{runtime}' owned /owned/qga.py
wootc_gui_observations_configure qga_call
infra_fail() {{ echo "$*"; }}
gui_wait_handover 1
echo PROVEN
'''
            result = subprocess.run(['bash','-c',script], capture_output=True, text=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('PROVEN', result.stdout)

    def test_real_infrastructure_ledger_on_unknown_handover(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp)/'results.jsonl'
            result, _ = self.run_shell(f'''source '{ROOT}/tests/e2e/lib/results.sh'
source '{ROOT}/tests/e2e/lib/result-runner.sh'
RED= NC= GREEN= YELLOW= BLUE=
RUN_ID=controlled-handover
WOOTC_FAILURE_LEDGER='{tmp}/failures.log'
WOOTC_RESULT_LEDGER='{ledger}'
wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
gui_wait_handover 1
''')
            self.assertNotEqual(result.returncode, 0)
            rows = [json.loads(line) for line in ledger.read_text().splitlines()]
            failures = [row for row in rows if row['kind']=='failure']
            self.assertEqual(len(failures),1)
            self.assertEqual(failures[0]['domain'],'infrastructure')
            self.assertFalse(any(row['kind']=='assertion' for row in rows))

    def test_actual_runner_handover_consumer_refuses_unknown_and_labels_loss_only(self):
        source = (ROOT/'tests/e2e/run-e2e.sh').read_text()
        tail = source.split('step "Waiting for Windows to reboot after GUI install..."',1)[1]
        tail = tail.split('\n}\n\nif [ "$GUI_INSTALL" = true ]; then',1)[0]
        body = 'step() { :; }; info() { echo "$*"; }; capture_vm_diagnostics() { echo DIAGNOSTICS; };'+tail.replace('gui_wait_handover 180','gui_wait_handover 1')
        unknown, _ = self.run_shell(body)
        self.assertNotEqual(unknown.returncode,0)
        self.assertIn('DIAGNOSTICS',unknown.stdout)
        loss, _ = self.run_shell(body,PING_RC='42')
        self.assertEqual(loss.returncode,0,loss.stderr)
        self.assertIn('transport unavailable',loss.stdout)
        self.assertNotIn('confirmed',loss.stdout)
        linux, _ = self.run_shell(body,LINUX='Linux',LINUX_RC='0')
        self.assertEqual(linux.returncode,0,linux.stderr)
        self.assertIn('Positive Linux identity',linux.stdout)

    def test_actual_runner_does_not_claim_reboot_from_unknown_windows(self):
        source = (ROOT/'tests/e2e/run-e2e.sh').read_text()
        gui = source.split('gui_install_arm() {',1)[1].split('\nif [ "$GUI_INSTALL" = true ]; then',1)[0]
        self.assertIn('gui_wait_handover 180 || { capture_vm_diagnostics; exit 1; }',gui)
        self.assertNotIn('if ! qga_windows_probe',gui)
        self.assertNotIn('Windows reboot confirmed',gui)
        self.assertIn('deployer monitor must establish the actual boot',gui)

if __name__=='__main__':
    unittest.main()
