#!/usr/bin/env python3
"""The signed chain on the Windows ESP is staged once and then goes stale
(#333). This exercises the refresh END TO END against a fake ESP and a fake
deployment payload — grep-only tests would not catch the ordering or the
restore path, which are the two things that decide whether a failed refresh
leaves a bootable machine."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SYNC = REPO / "payload" / "migration" / "wootc-esp-sync"
TRUST = REPO / "payload" / "migration" / "wootc-shim-trust"
FIXTURES = Path(os.environ.get("WOOTC_SHIM_FIXTURES", "/nonexistent"))


class ChainRefresh(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)

        # A fake ESP with a wootc-owned vendor directory.
        self.esp = self.d / "esp"
        self.vendor = self.esp / "EFI" / "fedora"
        self.vendor.mkdir(parents=True)
        (self.vendor / "grub.cfg").write_text("# wootc Phase 2 - boot installed system\n")
        (self.esp / "EFI" / "wootc").mkdir(parents=True)
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            (self.vendor / f).write_bytes(b"OLD-" + f.encode())
        (self.esp / "EFI" / "wootc" / "phase2-vmlinuz").write_bytes(b"k")
        (self.esp / "EFI" / "wootc" / "phase2-initramfs.img").write_bytes(b"i")

        # A fake /boot with one BLS entry so the kernel half is a no-op.
        self.boot = self.d / "boot"
        (self.boot / "loader" / "entries").mkdir(parents=True)
        (self.boot / "vmlinuz-6.1").write_bytes(b"k")
        (self.boot / "initramfs-6.1.img").write_bytes(b"i")
        (self.boot / "loader" / "entries" / "a.conf").write_text(
            "title t\nlinux /vmlinuz-6.1\ninitrd /initramfs-6.1.img\noptions ro\n")

        self.cmdline = self.d / "cmdline"
        self.cmdline.write_text("BOOT_IMAGE=/vmlinuz-6.1 ro loop=/wootc/disks/root.disk wootc.host_uuid=ABCD\n")

        # A stub wootc-shim-trust whose verdict the test controls.
        self.bin = self.d / "bin"
        self.bin.mkdir()
        self.verdict = self.d / "verdict"
        self.verdict.write_text("0")
        (self.bin / "wootc-shim-trust").write_text(
            "#!/bin/sh\n[ \"$1\" = check ] || exit 0\nexit \"$(cat %s)\"\n" % self.verdict)
        (self.bin / "wootc-shim-trust").chmod(0o755)

    def run_sync(self, source: Path):
        env = dict(os.environ)
        env.update({
            "WOOTC_ESP_DIR": str(self.esp),
            "WOOTC_BOOT_DIR": str(self.boot),
            "WOOTC_CMDLINE": str(self.cmdline),
            "PATH": f"{self.bin}:{env['PATH']}",
            "WOOTC_CHAIN_SOURCE": str(source),
        })
        return subprocess.run(["bash", str(SYNC)], capture_output=True, text=True, env=env)

    def make_source(self, name="fedora") -> Path:
        src = self.d / "payload" / "EFI" / name
        src.mkdir(parents=True)
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            (src / f).write_bytes(b"NEW-" + f.encode())
        return src

    def test_refreshes_all_three_when_the_candidate_is_accepted(self):
        src = self.make_source()
        r = self.run_sync(src)
        self.assertEqual(r.returncode, 0, r.stderr)
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            self.assertEqual((self.vendor / f).read_bytes(), b"NEW-" + f.encode(),
                             f"{f} was not refreshed:\n{r.stdout}")

    def test_the_previous_chain_is_archived_before_replacement(self):
        # Without an archive there is nothing to put back, so a failed write
        # would leave the machine unbootable.
        src = self.make_source()
        self.run_sync(src)
        archives = list((self.esp / "EFI" / "wootc" / "archive").glob("*/shimx64.efi"))
        self.assertTrue(archives, "no archived shim")
        self.assertEqual(archives[0].read_bytes(), b"OLD-shimx64.efi")

    def test_a_refused_candidate_leaves_the_working_chain_in_place(self):
        # A shim the firmware will not accept is worse than a stale one: the
        # stale one still boots.
        self.verdict.write_text("1")
        src = self.make_source()
        r = self.run_sync(src)
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            self.assertEqual((self.vendor / f).read_bytes(), b"OLD-" + f.encode())
        self.assertIn("keeping the installed", r.stdout)

    def test_shim_is_written_last(self):
        # A power cut mid-refresh must leave a shim that can still verify the
        # GRUB beside it. New shim over old GRUB is the combination that does
        # not boot.
        src = self.make_source()
        r = self.run_sync(src)
        order = [line for line in r.stdout.splitlines() if "refreshed" in line and ".efi" in line]
        self.assertTrue(order, r.stdout)
        self.assertIn("shimx64.efi", order[-1], f"shim was not last: {order}")

    def test_another_linuxs_vendor_directory_on_the_same_esp_is_never_touched(self):
        # The real hazard: a machine that also has Debian installed. Its
        # EFI/debian holds its own signed chain and a grub.cfg without our
        # marker. Refreshing it would replace another OS's bootloader with
        # ours — the D1 guard the Windows installer applies at install time,
        # applied again on every boot.
        debian = self.esp / "EFI" / "debian"
        debian.mkdir(parents=True)
        (debian / "grub.cfg").write_text("# Debian GRUB configuration\n")
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            (debian / f).write_bytes(b"DEBIAN-" + f.encode())

        src = self.make_source()
        r = self.run_sync(src)
        self.assertEqual(r.returncode, 0, r.stderr)
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            self.assertEqual((debian / f).read_bytes(), b"DEBIAN-" + f.encode(),
                             f"another OS's {f} was overwritten:\n{r.stdout}")
            # ...while ours still gets refreshed.
            self.assertEqual((self.vendor / f).read_bytes(), b"NEW-" + f.encode())

    def test_no_wootc_owned_directory_means_nothing_is_touched(self):
        # Nothing on this ESP carries our marker: an ESP we do not own, or a
        # layout we do not recognise. Do nothing rather than guess.
        esp = self.d / "esp2"
        (esp / "EFI" / "debian").mkdir(parents=True)
        (esp / "EFI" / "debian" / "grub.cfg").write_text("# Debian\n")
        (esp / "EFI" / "debian" / "shimx64.efi").write_bytes(b"DEBIAN-shim")
        env = dict(os.environ)
        env.update({
            "WOOTC_ESP_DIR": str(esp), "WOOTC_BOOT_DIR": str(self.boot),
            "WOOTC_CMDLINE": str(self.cmdline), "PATH": f"{self.bin}:{env['PATH']}",
            "WOOTC_CHAIN_SOURCE": str(self.make_source()),
        })
        r = subprocess.run(["bash", str(SYNC)], capture_output=True, text=True, env=env)
        self.assertEqual((esp / "EFI" / "debian" / "shimx64.efi").read_bytes(), b"DEBIAN-shim")
        # It must decline out loud. Either guard is fine — the earlier
        # "not a Phase-2 layout" one fires first on an ESP with no EFI/wootc —
        # but silence would be indistinguishable from having done the work.
        self.assertTrue(
            "no wootc-owned vendor directory" in r.stdout
            or "not a Phase-2 layout" in r.stdout,
            f"declined without saying why:\n{r.stdout}")

    def test_no_helper_means_the_chain_is_left_alone(self):
        # The pre-#333 behaviour, not a silent unguarded copy.
        (self.bin / "wootc-shim-trust").unlink()
        src = self.make_source()
        r = self.run_sync(src)
        self.assertEqual((self.vendor / "shimx64.efi").read_bytes(), b"OLD-shimx64.efi")
        self.assertIn("leaving the signed chain alone", r.stdout)

    def test_identical_chain_is_a_no_op(self):
        src = self.make_source()
        for f in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
            (self.vendor / f).write_bytes(b"NEW-" + f.encode())
        r = self.run_sync(src)
        self.assertNotIn("refreshed fedora/", r.stdout)
        self.assertFalse((self.esp / "EFI" / "wootc" / "archive").exists(),
                         "an unchanged chain must not be archived")


if __name__ == "__main__":
    unittest.main(verbosity=2)
