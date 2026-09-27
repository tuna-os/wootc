#!/usr/bin/env python3
"""Exercise GUI startup gates without launching a VM (#399).

The Sept 26 timelapse shows the cached fixture account at an expired-password
prompt. QGA and schtasks both succeeded while no interactive desktop existed.
"""
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "e2e" / "run-e2e.sh"
SOURCE = RUNNER.read_text()
MODULE = RUNNER.parent / 'lib/gui-session.sh'


class GuiSessionTests(unittest.TestCase):
    def shell(self, body, module=None, **env):
        with tempfile.TemporaryDirectory() as tmp:
            script = """
set -Eeuo pipefail
pass() { echo "PASS $*"; }
info() { echo "INFO $*"; }
fail() { echo "FAIL $*"; }
infra_fail() { fail "$@"; }
qga_windows_probe() { return "${IDENTITY_RC:-0}"; }
qga_restart_windows() { echo RESTART-WINDOWS >> "$CALLS"; return "${RESTART_RC:-0}"; }
deadline_in() { echo "$(( $(date +%s) + $1 ))"; }
past_deadline() { [ "$(cat "$TICKS")" -ge 2 ]; }
sleep() { echo "$(( $(cat "$TICKS") + 1 ))" > "$TICKS"; }
qga_powershell() {
    printf '%s\n' "$1" >> "$CALLS"
    if [[ "$1" == *ConvertTo-Json* ]] && [ "${SERVICING_REPLY+x}" = x ]; then
        count=$(cat "$PROBE_COUNT")
        printf '%s' "$((count + 1))" > "$PROBE_COUNT"
        if [ "$count" -gt 0 ] && [ "${SERVICING_AFTER+x}" = x ]; then
            printf '%s' "$SERVICING_AFTER"
        else
            printf '%s' "$SERVICING_REPLY"
        fi
        return "${SERVICING_RC:-0}"
    fi
    if [[ "$1" == *interactive-user=* ]] && [ "${SESSION_REPLY+x}" = x ]; then
        printf '%s' "$SESSION_REPLY"
        return 0
    fi
    printf '%s' "${REPLY:-}"
    return "${REPLY_RC:-0}"
}
""" + f"source '{module or MODULE}'\nwootc_gui_configure '{RUNNER.parent}' qga_powershell qga_windows_probe qga_restart_windows\n" + body
            ticks, calls = Path(tmp) / "ticks", Path(tmp) / "calls"
            ticks.write_text("0")
            probe_count = Path(tmp) / "probe-count"
            probe_count.write_text("0")
            calls.touch()
            result = subprocess.run(["bash", "-c", script], text=True,
                                    capture_output=True, timeout=5,
                                    env={**os.environ, "TICKS": str(ticks),
                                         "CALLS": str(calls), "PROBE_COUNT":str(probe_count), **env})
            return result, calls.read_text()

    def test_expired_fixture_requests_restart(self):
        result, script = self.shell('gui_prepare_account; echo "RESTART=$GUI_ACCOUNT_RESTART"',
                                   REPLY="autologon-account-ready restart=1\r\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESTART=true", result.stdout)
        self.assertIn('Set-LocalUser -Name $name -PasswordNeverExpires $true', script)
        self.assertNotIn("-Password ", script)  # preserve credentials
        self.assertNotIn("net accounts", script)  # no machine-wide relaxation
        self.assertIn("C:\\OEM\\wootc-e2e.log", script)

    def test_unexpired_fixture_does_not_request_restart(self):
        result, _ = self.shell('gui_prepare_account; echo "RESTART=$GUI_ACCOUNT_RESTART"',
                               REPLY="autologon-account-ready restart=0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESTART=false", result.stdout)

    def test_provisioning_failure_stops_launch(self):
        for reply, rc in [("", "0"), ("autologon-account-ready restart=0", "42")]:
            with self.subTest(reply=reply, rc=rc):
                result, _ = self.shell('gui_prepare_account; echo SCHEDULED', REPLY=reply, REPLY_RC=rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SCHEDULED", result.stdout)
                self.assertIn("autologon-provisioning", result.stdout)

    def test_observed_interactive_user_allows_launch(self):
        result, _ = self.shell('gui_wait_interactive_session; echo SCHEDULED',
                               REPLY="interactive-user=DESKTOP\\wootc\r\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SCHEDULED", result.stdout)

    def test_missing_or_failed_session_blocks_launch(self):
        for reply, rc in [("", "0"), ("a PowerShell error", "0"), ("interactive-user=DESKTOP\\wootc\nextra", "0"),
                          ("interactive-user=DESKTOP\\", "0"),
                          ("interactive-user=DESKTOP\\wootc", "42")]:
            with self.subTest(reply=reply, rc=rc):
                result, calls = self.shell('gui_wait_interactive_session; echo SCHEDULED',
                                            REPLY=reply, REPLY_RC=rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SCHEDULED", result.stdout)
                self.assertIn("autologon-no-session", result.stdout)
                self.assertIn("Win32_ComputerSystem", calls)
                self.assertNotIn("schtasks", calls)

    def test_wrong_os_refuses_before_account_or_session_guest_call(self):
        for method in ['gui_prepare_account', 'gui_wait_interactive_session', 'gui_settle_pending_servicing']:
            result, calls = self.shell(method + '; echo SCHEDULED', IDENTITY_RC='1')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, '')
            self.assertNotIn('SCHEDULED', result.stdout)

    def test_actual_clean_servicing_observation_allows_launch(self):
        reply = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=[]))
        result, calls = self.shell('gui_settle_pending_servicing; echo SCHEDULED', SERVICING_REPLY=reply)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SCHEDULED', result.stdout)
        self.assertNotIn('shutdown.exe /r', calls)
        self.assertIn('Test-Path', calls)
        self.assertIn('$ErrorActionPreference = "Stop"', calls)

    def test_failed_empty_or_malformed_servicing_probe_never_means_clean(self):
        clean = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=[]))
        bad = ['', 'null', '{}', 'clean', clean + '\nnoise',
               '{"schemaVersion":1,"os":"Windows_NT","pending":[],"pending":[]}',
               '{"schemaVersion":true,"os":"Windows_NT","pending":[]}',
               '{"schemaVersion":1,"os":"Linux","pending":[]}',
               '{"schemaVersion":1,"os":"Windows_NT","pending":null}',
               '{"schemaVersion":1,"os":"Windows_NT","pending":["unknown"]}',
               '{"schemaVersion":1,"os":"Windows_NT","pending":["servicing","servicing"]}']
        for reply, rc in [(value, '0') for value in bad] + [(clean, '7')]:
            result, calls = self.shell('gui_settle_pending_servicing; echo SCHEDULED',
                                       SERVICING_REPLY=reply, SERVICING_RC=rc)
            self.assertNotEqual(result.returncode, 0, (reply, result.stdout))
            self.assertNotIn('SCHEDULED', result.stdout)
            self.assertNotIn('shutdown.exe /r', calls)
            self.assertIn('unknown', result.stdout)

    def test_restart_requires_actual_clean_post_restart_readback(self):
        pending = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=['servicing']))
        clean = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=[]))
        for after, status in [(clean, 0), (pending, 1), ('', 1), ('{}', 1)]:
            result, calls = self.shell('gui_settle_pending_servicing; echo SCHEDULED',
                                       SERVICING_REPLY=pending, SERVICING_AFTER=after,
                                       SESSION_REPLY='interactive-user=DESKTOP\\wootc')
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertIn('RESTART-WINDOWS', calls)
            self.assertEqual(calls.count('RESTART-WINDOWS'), 1)
            self.assertEqual('SCHEDULED' in result.stdout, status == 0)

    def test_failed_restart_callback_stops_before_readback_or_launch(self):
        pending=json.dumps(dict(schemaVersion=1,os='Windows_NT',pending=['servicing']))
        result,calls=self.shell('gui_settle_pending_servicing; echo LAUNCHED',SERVICING_REPLY=pending,RESTART_RC='1')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('LAUNCHED',result.stdout)
        self.assertEqual(calls.count('RESTART-WINDOWS'),1)
        self.assertEqual(calls.count('ConvertTo-Json'),1)
        self.assertNotIn('interactive-user=',calls)

    def test_wrong_os_account_gate_records_actual_infrastructure_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / 'results.jsonl'
            result, calls = self.shell(f"""
source '{RUNNER.parent}/lib/results.sh'
source '{RUNNER.parent}/lib/result-runner.sh'
RED= NC= GREEN= YELLOW= BLUE=
RUN_ID=controlled-gui
WOOTC_FAILURE_LEDGER='{tmp}/failures.log'
WOOTC_RESULT_LEDGER='{ledger}'
wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
gui_prepare_account
""", IDENTITY_RC='1')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, '')
            failures = [json.loads(line) for line in ledger.read_text().splitlines() if json.loads(line)['kind'] == 'failure']
            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0]['domain'], 'infrastructure')
            self.assertIn('Windows identity', failures[0]['message'])

    def test_actual_blocking_qga_is_bounded_by_short_session_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = Path(tmp) / 'runtime'
            calls = Path(tmp) / 'calls'
            runtime.write_text('#!/bin/bash\nprintf call >> "$CALLS"\nsleep 20\necho interactive-user=DESKTOP\\\\wootc\n')
            runtime.chmod(0o755)
            script = f"""set -Eeuo pipefail
source '{RUNNER.parent}/lib/qga-transport.sh'
source '{MODULE}'
wootc_qga_configure '{runtime}' owned-vm /private/qga.py
qga_windows_probe() {{ return 0; }}
qga_wait_reboot() {{ return 0; }}
infra_fail() {{ echo "$*" >&2; }}
pass() {{ echo "$*"; }}
deadline_in() {{ echo "$(( $(date +%s) + $1 ))"; }}
past_deadline() {{ [ "$(date +%s)" -ge "$1" ]; }}
wootc_gui_configure '{RUNNER.parent}' qga_powershell qga_windows_probe qga_restart_windows
gui_wait_interactive_session 1
echo SCHEDULED
"""
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                    env={**os.environ, 'CALLS':str(calls)}, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SCHEDULED', result.stdout)
            self.assertEqual(calls.read_text(), 'call')
            self.assertIn('autologon-no-session', result.stderr)

    def test_actual_windows_identity_is_inside_short_session_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = Path(tmp) / 'runtime'
            calls = Path(tmp) / 'calls'
            runtime.write_text('#!/bin/bash\nprintf call >> "$CALLS"\nsleep 20\necho Windows_NT\n')
            runtime.chmod(0o755)
            script = f"""set -Eeuo pipefail
source '{RUNNER.parent}/lib/qga-transport.sh'
source '{MODULE}'
wootc_qga_configure '{runtime}' owned-vm /private/qga.py
qga_wait_reboot() {{ return 0; }}
infra_fail() {{ echo "$*" >&2; }}
pass() {{ echo "$*"; }}
deadline_in() {{ echo "$(( $(date +%s) + $1 ))"; }}
past_deadline() {{ [ "$(date +%s)" -ge "$1" ]; }}
wootc_gui_configure '{RUNNER.parent}' qga_powershell qga_windows_probe qga_restart_windows
gui_wait_interactive_session 1
echo SCHEDULED
"""
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                    env={**os.environ, 'CALLS':str(calls)}, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SCHEDULED', result.stdout)
            self.assertEqual(calls.read_text(), 'call')
            self.assertIn('positive Windows identity', result.stderr)

    def test_removed_transport_status_guard_allows_false_clean_counterexample(self):
        source = MODULE.read_text()
        original = "' 2>/dev/null) || return 1\n    printf '%s' \"$result\""
        self.assertEqual(source.count(original), 1)
        mutant_source = source.replace(original, "' 2>/dev/null)\n    printf '%s' \"$result\"")
        with tempfile.TemporaryDirectory() as tmp:
            mutant = Path(tmp) / 'gui-session.sh'
            mutant.write_text(mutant_source)
            clean = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=[]))
            result, _ = self.shell('gui_settle_pending_servicing; echo SCHEDULED',
                                   module=mutant, SERVICING_REPLY=clean, SERVICING_RC='7')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('SCHEDULED', result.stdout)

    def test_actual_install_callsite_stops_after_servicing_failure(self):
        line = next(line for line in SOURCE.splitlines() if 'gui_settle_pending_servicing ||' in line)
        clean = json.dumps(dict(schemaVersion=1, os='Windows_NT', pending=[]))
        body = 'capture_vm_diagnostics() { echo CAPTURED; };\n' + line + '\necho SCHEDULED'
        result, _ = self.shell(body, SERVICING_REPLY=clean, SERVICING_RC='7')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CAPTURED', result.stdout)
        self.assertNotIn('SCHEDULED', result.stdout)

    def test_gui_and_snapshot_paths_use_account_provisioning(self):
        prime = (Path(__file__).resolve().parents[2] / 'tests/e2e/lib/snapshot-prime.sh').read_text()
        self.assertLess(prime.index('gui_prepare_account ||'), prime.index("Stop-Computer"))
        gui = SOURCE.split('gui_install_arm() {', 1)[1]
        self.assertLess(gui.index('gui_prepare_account ||'), gui.index('gui_wait_interactive_session ||'))
        self.assertLess(gui.index('gui_wait_interactive_session ||'), gui.index('schtasks /Create'))
        self.assertNotIn('if (-not $who) { $who = "wootc" }', gui)


if __name__ == "__main__":
    unittest.main()
