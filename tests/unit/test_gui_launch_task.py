#!/usr/bin/env python3
"""The GUI launch task must be provably gone before the install directive.

`gui_install_arm` starts wootc.exe with `schtasks /Create /SC ONCE /ST <now+1m>`
plus `/Run`; `/Run` leaves the ONCE trigger armed (agent-lessons 32). The
harness then deleted the task with

    cmd.exe /d /c "schtasks.exe /Delete /TN \\"wootc-gui-e2e\\" /F >NUL 2>&1"

PowerShell has no backslash escape, so `\\"` closed the string: cmd.exe got two
arguments, schtasks was asked to delete a task named `"`, the error went to
NUL, and the trigger stayed armed. Once launch confirmation became fast, the
trigger fired after the instance count and a second wootc.exe drove the same
directive; its pipeline found the first one's root.disk ("Making room for
Linux: root.disk already exists", runs 36450824541 and 38735109866).
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

E2E = Path(__file__).resolve().parents[1] / "e2e"
RUNNER = E2E / "run-e2e.sh"
SOURCE = RUNNER.read_text()
MODULE = E2E / "lib" / "gui-session.sh"
PWSH = shutil.which("pwsh")


def single_instance_payload():
    """The PowerShell the harness sends for the delete + count probe."""
    start = SOURCE.index("single_out=$(qga_powershell '")
    start = SOURCE.index("'", start) + 1
    end = SOURCE.index("' 2>&1) || true", start)
    return SOURCE[start:end]


def single_quoted_payloads(text):
    """Every single-quoted bash argument handed to qga_powershell."""
    for match in re.finditer(r"qga_powershell '", text):
        start = match.end()
        end = text.index("'", start)
        yield text[start:end]


class LaunchTaskDeleteTests(unittest.TestCase):
    def test_no_powershell_payload_escapes_a_quote_with_backslash(self):
        # Inside a bash single-quoted string `\"` reaches PowerShell verbatim,
        # where it ends a double-quoted string instead of escaping the quote.
        # (`"^.*\\"` is a string ending in an escaped regex backslash: fine.)
        offenders = [p.splitlines()[0][:120] for p in single_quoted_payloads(SOURCE)
                     if re.search(r'(?<!\\)\\"', p)]
        self.assertEqual(offenders, [], "PowerShell has no backslash escape")

    def test_the_launch_task_delete_names_the_task_unquoted(self):
        payload = single_instance_payload()
        self.assertIn('cmd.exe /d /c "schtasks.exe /Delete /TN wootc-gui-e2e /F >NUL 2>&1"', payload)

    def test_task_absence_is_read_from_a_successful_listing(self):
        payload = single_instance_payload()
        self.assertIn("schtasks.exe /Query /FO CSV /NH", payload)
        self.assertIn("TASK-STATE-UNKNOWN", payload)
        self.assertIn('Write-Output "task-absent: wootc-gui-e2e"', payload)

    def test_the_directive_is_written_only_after_the_single_instance_verdict(self):
        verdict = SOURCE.index('if ! gui_single_instance_proven "$single_out" "$GUI_PROCESS.exe"; then')
        directive = SOURCE.index('step "Driving the REAL install through the live form')
        self.assertLess(verdict, directive)
        block = SOURCE[verdict:SOURCE.index("fi\n", verdict)]
        self.assertIn("return 1", block)
        # The native shell's package-path proof also gates the directive.
        native = SOURCE.index('! gui_native_shell_path_proven "$single_out"; then')
        self.assertLess(native, directive)
        self.assertIn("return 1", SOURCE[native:SOURCE.index("fi\n", native)])

    @unittest.skipUnless(PWSH, "pwsh not installed")
    def test_powershell_hands_cmd_exactly_one_command_string(self):
        line = next(l for l in single_instance_payload().splitlines()
                    if "schtasks.exe /Delete" in l)
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "line.txt"
            src.write_text(line)
            script = Path(tmp) / "parse.ps1"
            script.write_text(
                "$src = Get-Content -Raw -LiteralPath $args[0]\n"
                "$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)\n"
                "$cmd = $ast.EndBlock.Statements[0].PipelineElements[0]\n"
                "foreach ($e in $cmd.CommandElements) { Write-Output ('<' + $e.SafeGetValue() + '>') }\n")
            out = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(script), str(src)],
                                 capture_output=True, text=True, check=True).stdout.split("\n")
        args = [a.strip()[1:-1] for a in out if a.strip()]
        self.assertEqual(args, ["cmd.exe", "/d", "/c",
                                "schtasks.exe /Delete /TN wootc-gui-e2e /F >NUL 2>&1"])


class SingleInstanceVerdictTests(unittest.TestCase):
    def verdict(self, output, exe=None):
        env = dict(os.environ, OUT=output, EXE=exe or "")
        call = 'gui_single_instance_proven "$OUT" "$EXE"' if exe else 'gui_single_instance_proven "$OUT"'
        return subprocess.run(
            ["bash", "-c", f"source '{MODULE}'; {call}"],
            env=env, capture_output=True, text=True).returncode

    GOOD = "task-absent: wootc-gui-e2e\r\nround 1: instances=1\r\nsingle-instance: 1 wootc.exe\r\n"

    def test_positive_evidence_passes(self):
        self.assertEqual(self.verdict(self.GOOD), 0)

    def test_a_surviving_task_is_refused(self):
        out = self.GOOD.replace("task-absent: wootc-gui-e2e",
                                "TASK-STILL-PRESENT: wootc-gui-e2e survived its delete")
        self.assertNotEqual(self.verdict(out), 0)

    def test_an_unknown_task_state_is_refused(self):
        out = self.GOOD.replace("task-absent: wootc-gui-e2e", "TASK-STATE-UNKNOWN: schtasks /Query rc=1")
        self.assertNotEqual(self.verdict(out), 0)

    def test_an_empty_answer_is_refused(self):
        # A lost QGA channel returns nothing; silence is not a single instance.
        self.assertNotEqual(self.verdict(""), 0)

    def test_two_instances_are_refused(self):
        out = "task-absent: wootc-gui-e2e\nround 2: instances=2\nSINGLE-INSTANCE-UNPROVEN: 2 wootc.exe running\n"
        self.assertNotEqual(self.verdict(out), 0)

    NATIVE = ("task-absent: wootc-gui-e2e\r\nround 1: instances=1\r\nsingle-instance: 1 Wootc.Shell.exe\r\n"
              "native-shell-path: C:\\Program Files\\wootc Native Preview\\bluefin\\bundle\\Wootc.Shell.exe\r\n")

    def test_the_native_shell_passes_only_when_it_is_the_expected_frontend(self):
        self.assertEqual(self.verdict(self.NATIVE, "Wootc.Shell.exe"), 0)
        # A native run where the Wails app answered is not a native run.
        self.assertNotEqual(self.verdict(self.GOOD, "Wootc.Shell.exe"), 0)
        # ...and a Wails run is never satisfied by the native shell.
        self.assertNotEqual(self.verdict(self.NATIVE), 0)

    def test_the_other_frontend_running_is_refused(self):
        out = self.NATIVE + "OTHER-FRONTEND: 1 wootc.exe running beside the frontend under test\n"
        self.assertNotEqual(self.verdict(out, "Wootc.Shell.exe"), 0)

    def test_the_probe_counts_the_frontend_under_test(self):
        payload = single_instance_payload()
        self.assertIn("Get-Process -Name $gui", payload)
        self.assertIn("OTHER-FRONTEND", payload)
        self.assertNotIn("Get-Process wootc ", payload)
        self.assertIn('gui_single_instance_proven "$single_out" "$GUI_PROCESS.exe"', SOURCE)

    def test_the_count_alone_does_not_prove_the_trigger_is_gone(self):
        # Exactly the old run's evidence: one instance, no word on the task.
        self.assertNotEqual(self.verdict("round 1: instances=1\nsingle-instance: 1 wootc.exe\n"), 0)


if __name__ == "__main__":
    unittest.main()
