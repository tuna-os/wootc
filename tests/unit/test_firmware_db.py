#!/usr/bin/env python3
"""The firmware db axis grades what the guest read, against real Microsoft certs (#322).

The fixtures in app/testdata/uefi-db are db variables built by
tests/e2e/firmware-db.py from virt-firmware's Microsoft certificates, one per
cell. The Go preflight parses the same files (secureboot_test.go), so the
harness and the product agree on what each cell is.
"""
import base64
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tests/e2e/firmware-db.py'
FIXTURES = ROOT / 'app/testdata/uefi-db'
spec = importlib.util.spec_from_file_location('firmware_db', TOOL)
fdb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fdb)
CELLS = ('2011', '2023', 'both', 'none')


def fixture(cell):
    return base64.b64decode((FIXTURES / f'db-{cell}.b64').read_text().strip())


class FirmwareDbTests(unittest.TestCase):
    def test_each_cell_grades_green_only_against_itself(self):
        for built in CELLS:
            for wanted in CELLS:
                with self.subTest(built=built, wanted=wanted):
                    problems = fdb.grade(wanted, fixture(built))
                    self.assertEqual(problems == [], built == wanted, problems)

    def test_every_cell_keeps_windows_bootable(self):
        # A db without Windows' own CAs would fail at Windows Setup, long
        # before the installer under test ran, and look like an infra red.
        for cell in CELLS:
            subjects = fdb.db_subjects(fixture(cell))
            for rx in fdb.WINDOWS:
                self.assertTrue(any(rx.search(s) for s in subjects), (cell, rx.pattern))

    def test_option_rom_ca_is_not_mistaken_for_the_uefi_ca(self):
        # "Microsoft Option ROM UEFI CA 2023" rides along in the 2023 cell. It
        # cannot launch shim, so it must not count as the third-party CA.
        subjects = fdb.db_subjects(fixture('2023'))
        self.assertTrue(any('Option ROM' in s for s in subjects))
        self.assertEqual(fdb.grade('2023', fixture('2023')), [])
        rom_only = [s for s in subjects if 'Option ROM' in s]
        self.assertFalse(any(rx.search(s) for s in rom_only for rx, _ in fdb.THIRD_PARTY))

    def test_cli_grades_stdin_and_fails_on_garbage(self):
        good = (FIXTURES / 'db-none.b64').read_text()
        ok = subprocess.run([sys.executable, str(TOOL), 'grade', '--cell', 'none'],
                            input=good, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        wrong = subprocess.run([sys.executable, str(TOOL), 'grade', '--cell', 'both'],
                               input=good, capture_output=True, text=True)
        self.assertEqual(wrong.returncode, 1)
        self.assertIn('third-party CAs none', wrong.stdout)
        for junk in ('', 'not base64!', base64.b64encode(b'\x00' * 40).decode()):
            bad = subprocess.run([sys.executable, str(TOOL), 'grade', '--cell', 'none'],
                                 input=junk, capture_output=True, text=True)
            self.assertEqual(bad.returncode, 1, (junk, bad.stdout))


if __name__ == '__main__':
    unittest.main()
