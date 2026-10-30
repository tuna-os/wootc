#!/usr/bin/env python3
"""Exercise the actual Phase-3 guest health probe and its runner verdict gate."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEALTH = ROOT / "tests/e2e/phase3-health.sh"
RUNNER = ROOT / "tests/e2e/run-e2e.sh"


class GuestHealthProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self._stub(
            "systemctl",
            r'''
case "$*" in
  "show -p Id --value display-manager.service") printf '%s\n' "${HEALTH_DM-gdm.service}" ;;
  "show -p InactiveExitTimestamp --value "*) printf '\n' ;;
  "is-system-running --wait") printf '%s\n' "${HEALTH_SYSTEM_STATE-running}" ;;
  "list-units --state=failed --no-legend --plain")
    [ -z "${HEALTH_FAILED_UNIT:-}" ] || printf '%s loaded failed failed\n' "$HEALTH_FAILED_UNIT" ;;
  "is-active --quiet display-manager.service") [ "${HEALTH_DM_ACTIVE:-yes}" = yes ] ;;
  "is-active --quiet dbus.service") [ "${HEALTH_DBUS_ACTIVE:-yes}" = yes ] ;;
  "is-active --quiet dbus-broker.service") exit 1 ;;
  "is-active --quiet graphical.target") exit 0 ;;
  "get-default") printf '%s\n' "${HEALTH_DEFAULT_TARGET-graphical.target}" ;;
  status*) printf 'stub status for %s\n' "$*" ;;
  *) printf 'unexpected systemctl call: %s\n' "$*" >&2; exit 2 ;;
esac
''',
        )
        self._stub("getenforce", "printf '%s\n' \"${HEALTH_SELINUX-Disabled}\"\n")
        self._stub("getent", "exit 0\n")
        self._stub(
            "journalctl",
            "[ -z \"${HEALTH_DENIAL:-}\" ] || printf '%s\\n' \"$HEALTH_DENIAL\"\n",
        )
        self._stub("ausearch", "exit 0\n")
        self._stub("busctl", "[ \"${HEALTH_BUS_ANSWERS:-yes}\" = yes ]\n")
        self._stub("loginctl", "[ \"${HEALTH_LOGIND_ANSWERS:-yes}\" = yes ]\n")
        self._stub(
            "restorecon",
            "[ -z \"${HEALTH_MISLABEL:-}\" ] || "
            "printf 'Would relabel %s from old_t to expected_t\\n' \"$HEALTH_MISLABEL\"\n",
        )
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
        }

    def tearDown(self):
        self.temp.cleanup()

    def _stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_probe(self, mode, **environment):
        args = ["/bin/sh", str(HEALTH), mode]
        if mode == "check" and hasattr(self, "baseline"):
            args.append(self.baseline)
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=5,
            env={**self.env, **environment},
        )

    def capture_baseline(self, **environment):
        result = self.run_probe("baseline", **environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.baseline = result.stdout.rstrip("\n")

    def test_healthy_native_desktop_passes_every_generic_check(self):
        self.capture_baseline()
        result = self.run_probe("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL:", result.stdout)
        for observation in [
            "boot completed (running)",
            "no unexpected failed units",
            "system D-Bus is active",
            "logind answers over the bus",
            "display manager gdm.service is active",
            "every user and group in the target's sysusers.d resolves",
        ]:
            self.assertIn(observation, result.stdout)

    def test_failed_unit_emits_fail_and_nonzero_after_diagnostics(self):
        self.capture_baseline()
        result = self.run_probe("check", HEALTH_FAILED_UNIT="broken.service")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: unit failed: broken.service", result.stdout)
        self.assertIn("stub status for status", result.stdout)
        self.assertIn("every user and group", result.stdout)

    def test_display_manager_lost_during_graduation_fails(self):
        self.capture_baseline()
        result = self.run_probe("check", HEALTH_DM="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: no display manager is enabled", result.stdout)
        self.assertIn("expected gdm.service from Phase 2", result.stdout)

    def test_missing_pre_graduation_baseline_cannot_pass(self):
        result = self.run_probe("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: the pre-graduation health baseline is unavailable or invalid", result.stdout)

    def test_new_selinux_mislabel_and_unlabeled_denial_fail(self):
        self.capture_baseline(HEALTH_SELINUX="Enforcing")
        result = self.run_probe(
            "check",
            HEALTH_SELINUX="Enforcing",
            HEALTH_MISLABEL="/etc/new-mislabel",
            HEALTH_DENIAL=(
                "avc: denied { read } for pid=7 "
                "tcontext=system_u:object_r:unlabeled_t:s0"
            ),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: SELinux denied access to unlabeled files", result.stdout)
        self.assertIn("FAIL: 1 path(s) under /etc or /var/home", result.stdout)


class RunnerHealthVerdictTests(unittest.TestCase):
    def consumer(self, output="OK: healthy\n", status="0", module=RUNNER):
        source = module.read_text()
        start = source.index("    # Phase 3 generic post-boot health gate.")
        end = source.index("    # The point of it all:", start)
        body = source[start:end]
        prefix = r'''set -Eeuo pipefail
RED=; GREEN=; NC=; YELLOW=
P3_HEALTH_BASELINE='SCHEMA=1'
infra_fail() { echo "INFRA $*"; }
product_fail() { echo "PRODUCT-FAIL $*"; }
product_pass() { echo "PRODUCT-PASS $*"; }
qga_call() { printf '%s' "$HEALTH_OUTPUT"; return "$HEALTH_STATUS"; }
'''
        with tempfile.TemporaryDirectory() as artifact_dir:
            return subprocess.run(
                ["bash", "-c", prefix + body],
                capture_output=True,
                text=True,
                timeout=4,
                env={
                    **os.environ,
                    "HEALTH_OUTPUT": output,
                    "HEALTH_STATUS": status,
                    "SCRIPT_DIR": str(ROOT / "tests/e2e"),
                    "ARTIFACT_DIR": artifact_dir,
                },
            )

    def test_clean_probe_records_required_native_health_assertion(self):
        result = self.consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PRODUCT-PASS native-health", result.stdout)

    def test_fail_line_fails_cell_even_when_guest_command_returns_zero(self):
        result = self.consumer("OK: earlier\nFAIL: display manager stopped\n", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRODUCT-FAIL", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)

    def test_command_failure_without_product_finding_is_infrastructure(self):
        result = self.consumer("QGA: channel unavailable\n", "42")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INFRA", result.stdout)
        self.assertNotIn("PRODUCT-FAIL", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
