#!/usr/bin/env python3
"""wootc-shim-trust decides whether a candidate boot binary may replace one
that currently works (#333). Getting that wrong in the permissive direction
leaves a machine that cannot boot Linux, so these tests drive the real parser
against real signed binaries when they are available, and against synthesized
ones always."""

import importlib.machinery
import importlib.util
import os
import struct
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader(
    "shim_trust", str(REPO / "payload" / "migration" / "wootc-shim-trust"))
spec = importlib.util.spec_from_loader("shim_trust", loader)
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

# Real Fedora shims, when the fixture directory is present (set by the
# developer who downloaded them). Absent in CI: the synthesized cases below
# carry the contract either way.
FIXTURES = Path(os.environ.get("WOOTC_SHIM_FIXTURES", "/nonexistent"))


class ParserSafety(unittest.TestCase):
    def test_a_non_pe_file_raises_rather_than_guessing(self):
        with tempfile.NamedTemporaryFile(suffix=".efi") as f:
            f.write(b"not a PE at all")
            f.flush()
            with self.assertRaises(ValueError):
                st.authorities(Path(f.name))

    def test_an_unsigned_pe_reports_no_authorities(self):
        # A PE with an empty certificate table is not "trusted by default".
        data = bytearray(b"MZ" + b"\x00" * 0x3E)
        struct.pack_into("<I", data, 0x3C, 0x40)
        data += b"PE\0\0" + b"\x00" * 20
        struct.pack_into("<H", data, 0x40 + 20, 240)  # optional header size
        data += b"\x0b\x02" + b"\x00" * 238           # PE32+ optional header
        data += b"\x00" * 256                          # data directories
        with tempfile.NamedTemporaryFile(suffix=".efi", delete=False) as f:
            f.write(bytes(data))
            path = Path(f.name)
        self.addCleanup(path.unlink)
        self.assertEqual(st.pkcs7_blobs(bytes(data)), [])
        self.assertEqual(st.authorities(path), [])

    def test_no_efivarfs_means_unknown_not_untrusted(self):
        old = st.EFIVARS
        st.EFIVARS = Path("/nonexistent-efivars")
        try:
            self.assertEqual(st.firmware_db(), [])
            self.assertIsNone(st.secure_boot_on())
        finally:
            st.EFIVARS = old


class Decision(unittest.TestCase):
    def _fake(self, name, cas, sbat):
        """Stub the two expensive readers so the DECISION is what is tested."""
        st.authorities = lambda p, _c=cas: list(_c)
        st.sbat_generation = lambda p, _s=sbat: _s
        return Path(name)

    def setUp(self):
        self._auth, self._sbat, self._sb, self._db = (
            st.authorities, st.sbat_generation, st.secure_boot_on, st.firmware_db)

    def tearDown(self):
        st.authorities, st.sbat_generation = self._auth, self._sbat
        st.secure_boot_on, st.firmware_db = self._sb, self._db

    def test_refuses_a_candidate_with_no_microsoft_signature(self):
        st.authorities = lambda p: []
        st.sbat_generation = lambda p: 4
        st.secure_boot_on = lambda: False
        self.assertEqual(st.check(Path("cand.efi"), None), 1)

    def test_refuses_when_secure_boot_is_on_and_the_db_is_unreadable(self):
        # We cannot tell whether the firmware would launch it, and the chain
        # that boots today is the safer bet.
        st.authorities = lambda p: ["2023"]
        st.sbat_generation = lambda p: 4
        st.secure_boot_on = lambda: True
        st.firmware_db = lambda: []
        self.assertEqual(st.check(Path("cand.efi"), None), 1)

    def test_refuses_a_candidate_the_firmware_does_not_trust(self):
        st.authorities = lambda p: ["2023"]
        st.sbat_generation = lambda p: 4
        st.secure_boot_on = lambda: True
        st.firmware_db = lambda: ["2011"]
        self.assertEqual(st.check(Path("cand.efi"), None), 1)

    def test_accepts_when_the_authorities_intersect(self):
        st.authorities = lambda p: ["2011", "2023"]
        st.sbat_generation = lambda p: 4
        st.secure_boot_on = lambda: True
        st.firmware_db = lambda: ["2011"]
        self.assertEqual(st.check(Path("cand.efi"), None), 0)

    def test_secure_boot_off_skips_the_trust_check_but_not_sbat(self):
        st.authorities = lambda p: ["2011"]
        st.secure_boot_on = lambda: False
        st.firmware_db = lambda: []
        gens = {"cand.efi": 3, "cur.efi": 7}
        st.sbat_generation = lambda p: gens[Path(p).name]

        class FakePath(type(Path("."))):
            def exists(self):
                return True
        self.assertEqual(st.check(Path("cand.efi"), FakePath("cur.efi")), 1)


class RealBinaries(unittest.TestCase):
    @unittest.skipUnless(FIXTURES.is_dir(), "no real shim fixtures available")
    def test_reads_a_dual_signed_shim_as_dual_signed(self):
        got = st.authorities(FIXTURES / "rawhide-shimx64.efi")
        self.assertEqual(got, ["2011", "2023"])

    @unittest.skipUnless(FIXTURES.is_dir(), "no real shim fixtures available")
    def test_reads_the_sbat_generation_from_the_sbat_section(self):
        # Not from the first occurrence of the string anywhere in the file:
        # shim embeds its SBAT revocation policy elsewhere too.
        self.assertEqual(st.sbat_generation(FIXTURES / "rawhide-shimx64.efi"), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
