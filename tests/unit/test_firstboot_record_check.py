#!/usr/bin/env python3
"""Controls for the E2E first-boot record comparison (tests/e2e/lib/firstboot_record_check.py)."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "firstboot_record_check", ROOT / "tests/e2e/lib/firstboot_record_check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

FOLDERS = ("Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos")


def record(folders=FOLDERS, failed=()):
    bindings = [{"source": f"/run/initramfs/wootc-host/Users/wootc/{f}",
                 "target": f"/home/wootc/{f}", "user": "wootc"} for f in folders]
    return {"bootId": "a5e5", "kernel": "7.2.5", "writtenAt": "t",
            "failedUnits": list(failed),
            "bridge": {"boundFolders": len(bindings), "matchedUsers": 1 if bindings else 0,
                       "bitlockerUnlocked": False, "bindings": bindings}}


def converted(*folders):
    return lambda binding: Path(binding["target"]).name in folders


class FirstbootRecord(unittest.TestCase):
    def test_identical_boot_passes(self):
        check.compare(record(), record(), converted())

    def test_folder_converted_since_first_boot_passes(self):
        # Probe 44889931801: the suite converted ~/Music before the check.
        now = record([f for f in FOLDERS if f != "Music"])
        check.compare(record(), now, converted("Music"))

    def test_lost_binding_without_conversion_fails(self):
        now = record([f for f in FOLDERS if f != "Music"])
        with self.assertRaisesRegex(ValueError, "differs from current boot: bridge"):
            check.compare(record(), now, converted())

    def test_converted_folder_still_bound_fails(self):
        with self.assertRaisesRegex(ValueError, "differs from current boot: bridge"):
            check.compare(record(), record(), converted("Music"))

    def test_other_identity_change_fails(self):
        now = record()
        now["bootId"] = "other"
        with self.assertRaisesRegex(ValueError, "differs from current boot: bootId"):
            check.compare(record(), now, converted())

    def test_measurement_time_and_foreign_failed_units_are_not_identity(self):
        now = record(failed=["mcelog.service"])
        now["writtenAt"] = "later"
        check.compare(record(), now, converted())

    def test_failed_wootc_unit_fails(self):
        with self.assertRaisesRegex(ValueError, "wootc units failed: wootc-host-bind.service"):
            check.compare(record(failed=["wootc-host-bind.service"]), record(), converted())

    def test_first_boot_record_is_not_modified(self):
        persisted = record()
        before = copy.deepcopy(persisted)
        check.compare(persisted, record([f for f in FOLDERS if f != "Music"]), converted("Music"))
        self.assertEqual(persisted, before)


if __name__ == "__main__":
    unittest.main()
