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
            "no failed units outside the known-failure list",
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

    def test_known_failure_is_reported_with_its_issue_not_counted(self):
        self.capture_baseline()
        result = self.run_probe("check", HEALTH_FAILED_UNIT="mcelog.service")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(
            "known-failure list: mcelog.service "
            "(https://github.com/ublue-os/bluefin/issues/5197)",
            result.stdout,
        )
        self.assertIn("no failed units outside the known-failure list", result.stdout)

    def test_known_failure_list_matches_names_exactly(self):
        self.capture_baseline()
        result = self.run_probe("check", HEALTH_FAILED_UNIT="mcelog.service.d")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: unit failed: mcelog.service.d", result.stdout)

    def test_boot_receipt_is_no_longer_excused(self):
        # The fisherman pin includes tuna-os/fisherman#509 (issue #508): the
        # receipt collector waits for bootc-unified-storage.service, so a
        # failed receipt unit is a real failure again.
        self.capture_baseline()
        result = self.run_probe("check", HEALTH_FAILED_UNIT="fisherman-boot-receipt.service")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: unit failed: fisherman-boot-receipt.service", result.stdout)

    def test_tuned_lock_timeout_in_phase2_is_reported_with_its_issue(self):
        # Probe 44878928655: tuned's bootc call waited on the sysroot lock
        # that bluefin:stable's first-boot bootc-unified-storage.service held.
        result = self.run_probe("phase2-units", HEALTH_FAILED_UNIT="tuned.service")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(
            "known-failure list: tuned.service "
            "(https://github.com/ublue-os/bluefin/issues/5201)",
            result.stdout,
        )
        self.assertNotIn("FAIL:", result.stdout)

    def test_phase2_still_booting_asks_to_be_asked_again(self):
        # Probe 44852542894: the QGA client stops a guest command at 60 s and
        # Phase 2 was still booting; exit 3, never a verdict.
        result = self.run_probe("phase2-units", HEALTH_SYSTEM_STATE="starting",
                                HEALTH_FAILED_UNIT="wootc-host-bind.service")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertIn("Phase 2 is still booting (starting)", result.stdout)
        self.assertNotIn("FAIL:", result.stdout)

    def test_phase2_failed_unit_outside_the_list_fails(self):
        result = self.run_probe("phase2-units", HEALTH_FAILED_UNIT="wootc-host-bind.service")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: unit failed: wootc-host-bind.service", result.stdout)
        clean = self.run_probe("phase2-units", HEALTH_FAILED_UNIT="mcelog.service")
        self.assertEqual(clean.returncode, 0, clean.stdout)

    def test_every_known_failure_names_an_issue_and_a_removal_condition(self):
        source = HEALTH.read_text()
        block = source.split("KNOWN_FAILED_UNITS='", 1)[1].split("'", 1)[0]
        entries = [line.split() for line in block.strip().splitlines()]
        self.assertEqual([e[0] for e in entries], ["mcelog.service", "tuned.service"])
        for unit, issue, removal in entries:
            self.assertRegex(issue, r"^https://github\.com/[a-z-]+/[a-z-]+/issues/[0-9]+$")
            self.assertTrue(removal.startswith("remove-when-"), removal)
            # Every exemption expires: the note carries the date to drop it.
            self.assertRegex(removal, r"-on-[0-9]{4}-[0-9]{2}-[0-9]{2}-", removal)

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

    def test_any_selinux_mislabel_and_unlabeled_denial_fail(self):
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
        self.assertIn("FAIL: 1 path(s) under /etc or /var/home have incorrect SELinux labels", result.stdout)

    def test_clean_labels_are_asserted_as_zero(self):
        self.capture_baseline(HEALTH_SELINUX="Enforcing")
        result = self.run_probe("check", HEALTH_SELINUX="Enforcing")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("OK: 0 mislabeled paths under /etc and /var/home", result.stdout)


class RunnerHealthVerdictTests(unittest.TestCase):
    BOOT = "c49ec976-2f51-420f-a1a7-2cda006e6053"

    def export(self, output="OK: healthy", status="0", boot=BOOT):
        return f"HEALTH_SCHEMA=1\nHEALTH_BOOT_ID={boot}\nHEALTH_STATUS={status}\n{output}\n"

    def consumer(self, export=None, cat_status="0", module=RUNNER):
        if export is None:
            export = self.export()
        source = module.read_text()
        start = source.index("    # Phase 3 generic post-boot health gate.")
        end = source.index("    # The point of it all:", start)
        body = source[start:end]
        # The agent answers the export read with HEALTH_EXPORT; any other
        # request (the agent's own view) gets a stand-in. The wait ends at
        # once: the deadline is already past.
        prefix = r'''set -Eeuo pipefail
RED=; GREEN=; NC=; YELLOW=
P3_NATIVE_BOOT_ID=c49ec976-2f51-420f-a1a7-2cda006e6053
infra_fail() { echo "INFRA $*"; }
product_fail() { echo "PRODUCT-FAIL $*"; }
product_pass() { echo "PRODUCT-PASS $*"; }
deadline_in() { echo 0; }
past_deadline() { return 0; }
sleep() { :; }
# The guest's `cat ... && echo HEALTH_READ=complete`: the trailer only
# when the read succeeded.
qga_call() {
    case "$*" in
        *wootc-e2e-native-health*)
            printf '%s' "$HEALTH_EXPORT"
            [ "$HEALTH_CAT_STATUS" != 0 ] || echo HEALTH_READ=complete
            return "$HEALTH_CAT_STATUS" ;;
        *) echo "context: system_u:system_r:virt_qemu_ga_t:s0" ;;
    esac
}
'''
        with tempfile.TemporaryDirectory() as artifact_dir:
            return subprocess.run(
                ["bash", "-c", prefix + body],
                capture_output=True,
                text=True,
                timeout=4,
                env={
                    **os.environ,
                    "HEALTH_EXPORT": export,
                    "HEALTH_CAT_STATUS": cat_status,
                    "SCRIPT_DIR": str(ROOT / "tests/e2e"),
                    "ARTIFACT_DIR": artifact_dir,
                },
            )

    def test_clean_export_records_required_native_health_assertion(self):
        result = self.consumer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PRODUCT-PASS native-health", result.stdout)
        self.assertIn("agent view: context: system_u:system_r:virt_qemu_ga_t:s0", result.stdout)

    def test_fail_line_fails_cell_even_when_check_returns_zero(self):
        result = self.consumer(self.export("OK: earlier\nFAIL: display manager stopped", "0"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRODUCT-FAIL", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)

    def test_check_failure_without_product_finding_is_infrastructure(self):
        result = self.consumer(self.export("no health check at /etc/wootc/e2e-phase3-health.sh", "127"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INFRA", result.stdout)
        self.assertNotIn("PRODUCT-FAIL", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)

    def test_export_from_another_boot_cannot_pass(self):
        result = self.consumer(self.export(boot="00000000-0000-0000-0000-000000000000"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INFRA Phase 3 health export is absent, malformed or not from this boot", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)

    def test_absent_export_is_infrastructure_after_the_wait(self):
        result = self.consumer("", cat_status="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INFRA Phase 3 health export is absent", result.stdout)
        self.assertNotIn("PRODUCT", result.stdout)

    def test_failed_read_of_a_clean_export_cannot_pass(self):
        # The transport failed after a clean-looking body: without the
        # trailer, nothing proves the body is whole.
        result = self.consumer(self.export(), cat_status="42")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("INFRA Phase 3 health export is absent", result.stdout)
        self.assertNotIn("PRODUCT-PASS", result.stdout)

    def test_check_is_staged_where_go_native_copies_it_from(self):
        runner = RUNNER.read_text()
        go_native = (ROOT / "payload/migration/wootc-go-native").read_text()
        for staged in ("e2e-phase3-health.sh", "e2e-phase3-health.baseline"):
            self.assertIn(f"/run/wootc-{staged}", runner)
            self.assertIn(staged, go_native)
        self.assertIn('"/run/wootc-$staged"', go_native)
        self.assertIn("/run/wootc-e2e-native-health", go_native)


if __name__ == "__main__":
    unittest.main()
