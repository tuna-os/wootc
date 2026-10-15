#!/usr/bin/env python3
"""Never miss the MokManager countdown; if it is missed, say so at once.

Run 38755153727 (bazzite:stable, GUI) deployed, queued the MOK enrollment and
rebooted into Phase 2. The harness sighted MokManager after its 10 s countdown
had already run out; MokManager booted GRUB, GRUB refused the Bazzite kernel
("bad shim signature", wrapped across two serial lines) and then sat at its
menu. The driver logged "catching the next cycle" and waited out its whole
budget for a cycle that never came. Run 38776066218 reset from GRUB instead:
MokManager never came back, because it deletes the request when the countdown
runs out. Both runs first looked at the serial ~24 s after the reboot, spent in
the QGA departure wait. The fixture is the first run's serial from the
MokManager marker to the end of the capture.
"""
import os
import re
import subprocess
import unittest
from pathlib import Path

E2E = Path(__file__).resolve().parents[1] / "e2e"
RUNNER = (E2E / "run-e2e.sh").read_text()
MODULE = E2E / "lib" / "mok.sh"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "mok-missed-countdown-38755153727.serial"


def refused(span):
    with open(os.devnull, "w") as null:
        return subprocess.run(
            ["bash", "-c", f"source '{MODULE}'; mok_missed_boot_refused \"$SPAN\""],
            env=dict(os.environ, SPAN=span), stdout=null, stderr=null).returncode == 0


class MissedCountdownPredicateTests(unittest.TestCase):
    def test_the_real_missed_countdown_is_recognised(self):
        span = FIXTURE.read_bytes().decode("utf-8", "replace")
        self.assertIn("Booting in 1 second", span)
        self.assertTrue(refused(span))

    def test_no_refusal_no_reset(self):
        self.assertFalse(refused("Press any key to perform MOK management Booting in 3 seconds"))
        self.assertFalse(refused(""))

    def test_a_kernel_started_after_the_refusal_blocks_the_reset(self):
        span = FIXTURE.read_bytes().decode("utf-8", "replace")
        self.assertFalse(refused(span + "\n[    0.000000] Linux version 6.16.4-bazzite\n"))

    def test_windows_started_after_the_refusal_blocks_the_reset(self):
        span = FIXTURE.read_bytes().decode("utf-8", "replace")
        self.assertFalse(refused(span + '\nBdsDxe: starting Boot0003 "Windows Boot Manager" from HD(1,GPT)\n'))


class RunnerWiringTests(unittest.TestCase):
    def loop(self):
        start = RUNNER.index('step "Waiting for Phase 2 Linux system to boot..."')
        return RUNNER[start:RUNNER.index('[ "$BOOT_SUCCESS" = true ] ||', start)]

    def test_a_missed_sighting_is_remembered(self):
        miss = RUNNER.index("MokManager sighted but its menu was not confirmed")
        self.assertIn("MOK_MISS_BYTE=$CURRENT_BYTE", RUNNER[miss:miss + 300])

    def test_a_confirmed_miss_fails_fast_as_infrastructure(self):
        loop = self.loop()
        gate = loop.index('mok_missed_boot_refused "$(tail -c +"$((MOK_MISS_BYTE + 1))"')
        # Evaluated every pass, before the fresh-output branch: a machine
        # parked at the GRUB menu prints nothing more.
        self.assertLess(gate, loop.index('if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then'))
        block = loop[loop.rindex("if ", 0, gate):loop.index("fi\n", gate)]
        self.assertIn("infra_fail", block)
        self.assertIn("PHASE2_DIAGNOSED=true", block)
        self.assertIn("break", block)
        # The request is gone after a miss: resetting cannot bring it back.
        self.assertNotIn("system_reset", loop)

    def test_pending_enrollment_is_known_before_the_reboot(self):
        reboot = RUNNER.index("""shutdown.exe /r /t 1 /f >NUL 2>&1"' >/dev/null 2>&1 || true\n# MokManager shows""")
        self.assertLess(RUNNER.index("if grep -aq 'MOK enrollment queued' \"$PTY\""), reboot)

    def test_a_pending_enrollment_skips_the_qga_departure_wait(self):
        after = RUNNER[RUNNER.index("# MokManager shows a 10-second countdown"):]
        branch = after[:after.index("\nfi\n") + 4]
        self.assertIn('if [ "$MOK_PENDING" = true ]; then', branch)
        then, other = branch.split("else", 1)
        self.assertNotIn("qga_wait_down", then)
        self.assertIn('qga_wait_down "Phase 2 Linux boot" 300', other)

    def test_the_loop_polls_every_second_until_mokmanager_is_driven(self):
        self.assertIn('if [ "$MOK_PENDING" = true ] && [ "$MOK_SIGHTINGS" -eq 0 ]; then sleep 1; else sleep 5; fi',
                      self.loop())

    def test_every_windows_return_rearm_follows_a_wanted_event(self):
        loop = self.loop()
        rearms = [m.start() for m in re.finditer(r"\n\s+mok_rearm_phase2\n", loop)]
        self.assertEqual(len(rearms), 2)
        for at in rearms:
            self.assertIn('[ "$MOK_REARM_WANTED" = true ]', loop[loop.rindex("if ", 0, at):at])
        self.assertNotIn("MOK_REARMED", RUNNER)
        # Only a driven sequence hands the firmware back and wants a re-arm.
        self.assertEqual(RUNNER.count("MOK_REARM_WANTED=true"), 1)

    def test_a_driven_sequence_still_wants_its_rearm(self):
        loop = self.loop()
        driven = loop.index("if mok_sequence; then")
        self.assertIn("MOK_REARM_WANTED=true", loop[driven:loop.index("else", driven)])


if __name__ == "__main__":
    unittest.main()
