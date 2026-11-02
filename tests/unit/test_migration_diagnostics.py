#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "payload/deployer/migration-diagnostics.sh"


class MigrationDiagnosticsTests(unittest.TestCase):
    def run_phases(self, body):
        with tempfile.TemporaryDirectory() as folder:
            persistent = Path(folder) / "deployer.log"
            script = '''set -euo pipefail
source "$1"
PERSIST_LOG="$2"
WOOTC_DIAGNOSTIC_ATTEMPT=01234567-89ab-cdef-0123-456789abcdef
clock=1000
wootc_diagnostic_millis() { printf '%s\\n' "$clock"; }
date() { printf '2026-01-01T00:00:00Z\\n'; }
''' + body
            result = subprocess.run(["bash", "-c", script, "diagnostics", str(MODULE), str(persistent)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            events = [json.loads(line) for line in result.stderr.splitlines()]
            persisted = persistent.read_text() if persistent.exists() else ""
            self.assertEqual(persisted, result.stderr)
            return events

    def test_transition_measures_completed_phase_and_final_failure(self):
        events = self.run_phases('''wootc_diagnostic_phase fisherman
clock=4500
wootc_diagnostic_phase verification
clock=5000
wootc_diagnostic_finish 17
wootc_diagnostic_finish 17
''')
        self.assertEqual([(e["phase"], e["event"], e["duration_ms"]) for e in events], [
            ("fisherman", "phase_start", 0),
            ("fisherman", "phase_complete", 3500),
            ("verification", "phase_start", 0),
            ("verification", "phase_error", 500),
        ])
        self.assertEqual(events[-1]["error_code"], "operation_failed")

    def test_reboot_completion_has_no_error(self):
        events = self.run_phases('''wootc_diagnostic_phase reboot
clock=1250
wootc_diagnostic_finish 0
''')
        self.assertEqual(events[-1]["duration_ms"], 250)
        self.assertEqual(events[-1]["event"], "phase_complete")
        self.assertEqual(events[-1]["error_code"], "")

    def test_untrusted_phase_is_never_written(self):
        events = self.run_phases('''wootc_diagnostic_phase 'password=secret"
credential'
wootc_diagnostic_finish 1
''')
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
