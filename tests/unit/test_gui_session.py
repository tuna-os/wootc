#!/usr/bin/env python3
"""Exercise GUI startup gates without launching a VM (#399).

The Sept 26 timelapse shows the cached fixture account at an expired-password
prompt. QGA and schtasks both succeeded while no interactive desktop existed.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "e2e" / "run-e2e.sh"
SOURCE = RUNNER.read_text()
HELPERS = SOURCE.split("gui_prepare_account() {", 1)[1].split("# Which drive holds", 1)[0]
HELPERS = "gui_prepare_account() {" + HELPERS


class GuiSessionTests(unittest.TestCase):
    def shell(self, body, **env):
        with tempfile.TemporaryDirectory() as tmp:
            script = """
set -Eeuo pipefail
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; }
deadline_in() { echo 120; }
past_deadline() { [ "$(cat "$TICKS")" -ge 2 ]; }
sleep() { echo "$(( $(cat "$TICKS") + 1 ))" > "$TICKS"; }
qga_powershell() {
    printf '%s\n' "$1" >> "$CALLS"
    printf '%s' "${REPLY:-}"
    return "${REPLY_RC:-0}"
}
""" + HELPERS + body
            ticks, calls = Path(tmp) / "ticks", Path(tmp) / "calls"
            ticks.write_text("0")
            calls.touch()
            result = subprocess.run(["bash", "-c", script], text=True,
                                    capture_output=True, timeout=5,
                                    env={**os.environ, "TICKS": str(ticks),
                                         "CALLS": str(calls), **env})
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
        for reply, rc in [("", "0"), ("a PowerShell error", "0"),
                          ("interactive-user=DESKTOP\\wootc", "42")]:
            with self.subTest(reply=reply, rc=rc):
                result, calls = self.shell('gui_wait_interactive_session; echo SCHEDULED',
                                            REPLY=reply, REPLY_RC=rc)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SCHEDULED", result.stdout)
                self.assertIn("autologon-no-session", result.stdout)
                self.assertIn("GUI launch blocked", calls)

    def test_gui_and_snapshot_paths_use_account_provisioning(self):
        prime = SOURCE.split('if [ -n "$SNAPSHOT_OUT" ]; then', 1)[1].split('# ALWAYS reset', 1)[0]
        self.assertLess(prime.index('gui_prepare_account ||'), prime.index("Stop-Computer"))
        gui = SOURCE.split('gui_install_arm() {', 1)[1]
        self.assertLess(gui.index('gui_prepare_account ||'), gui.index('gui_wait_interactive_session ||'))
        self.assertLess(gui.index('gui_wait_interactive_session ||'), gui.index('schtasks /Create'))
        self.assertNotIn('if (-not $who) { $who = "wootc" }', gui)


if __name__ == "__main__":
    unittest.main()
