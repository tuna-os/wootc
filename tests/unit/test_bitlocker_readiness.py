"""Exercise the actual runner wait with deterministic clock and QGA responses."""
import pathlib
import subprocess
import unittest

RUNNER = pathlib.Path(__file__).parents[1] / 'e2e/run-e2e.sh'
SOURCE = RUNNER.read_text()
FUNCTION = (RUNNER.parent / 'lib/fixture-bitlocker.sh').read_text()


class ReadinessWait(unittest.TestCase):
    def run_wait(self, response, rc=0, delayed=False):
        script = r'''
now=100
calls=0
date() { echo "$now"; }
deadline_in() { echo $((now+$1)); }
past_deadline() { [ "$now" -ge "$1" ]; }
sleep() { now=$((now+$1)); }
info() { :; }
pass() { :; }
fail() { :; }
qga_powershell() {
 [ "$WOOTC_QGA_CALL_TIMEOUT" -le 3 ] || exit 90
 ''' + ('sleep 3\n' if delayed else '') + 'printf "%s\\n" ' + repr(response) + '\nreturn ' + str(rc) + r'''
}
''' + FUNCTION + '\nbitlocker_wait_fixture_ready 3\n'
        return subprocess.run(['bash', '-c', script], capture_output=True).returncode

    def test_only_exact_observable_passes(self):
        self.assertEqual(self.run_wait('bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=True'), 0)
        for response in ['', 'True', 'bitlocker-fixture status=EncryptionInProgress percentage=100 protection=On ready=True',
                         'bitlocker-fixture status=FullyEncrypted percentage=99 protection=On ready=True',
                         'bitlocker-fixture status=FullyEncrypted percentage=100 protection=Off ready=True',
                         'bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=False']:
            with self.subTest(response=response):
                self.assertEqual(self.run_wait(response), 1)

    def test_transport_error_never_passes(self):
        self.assertEqual(self.run_wait('bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=True', 42), 1)

    def test_call_budget_is_remaining_deadline(self):
        self.assertEqual(self.run_wait('unavailable'), 1)

    def test_success_after_deadline_is_refused(self):
        script = r"""
deadline_in() { echo $(( $(date +%s) + $1 )); }
past_deadline() { [ "$(date +%s)" -ge "$1" ]; }
info() { :; }
pass() { :; }
fail() { :; }
qga_powershell() {
    [ "$WOOTC_QGA_CALL_TIMEOUT" = 1 ] || return 90
    sleep 1
    echo 'bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=True'
}
""" + FUNCTION + '\nbitlocker_wait_fixture_ready 1\n'
        self.assertEqual(subprocess.run(['bash', '-c', script], timeout=3).returncode, 1)

    def test_guard_precedes_first_schedule(self):
        self.assertIn('if [[ "$E2E_BITLOCKER" == "on" ]]; then\n    step "Waiting for BitLocker fixture', SOURCE)
        self.assertLess(SOURCE.index('bitlocker_prepare_fixture 1800 || exit 1'), SOURCE.index('step "Scheduling one-shot Phase 2 Linux boot..."'))


if __name__ == '__main__':
    unittest.main()
