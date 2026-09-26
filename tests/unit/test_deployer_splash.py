"""Execute the production splash without mounting disks or starting deployment."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'payload/deployer/deploy.sh').read_text()
SPLASH = SOURCE[SOURCE.index('# ── Stage display'):SOURCE.index('# Cap dirty page')]


class DeployerSplash(unittest.TestCase):
    def run_splash(self, script):
        with tempfile.TemporaryDirectory() as tmp:
            tty = pathlib.Path(tmp) / 'screen'
            tty.touch()
            state = pathlib.Path(tmp) / 'state'
            subprocess.run(['bash', '-eu', '-c', SPLASH + '\n' +
                            'SPLASH_TTY="$1"; SPLASH_STATE="$2"\n' + script,
                            'splash-test', str(tty), str(state)], check=True)
            return tty.read_text()

    def test_elapsed_time_never_implies_completion(self):
        for seconds in (0, 900, 7200):
            output = self.run_splash(
                f'splash_set "Installing your Linux system..."\n'
                f'splash_paint "$(cat "$SPLASH_STATE")" "|" {seconds}')
            self.assertIn('Installing your Linux system...', output)
            self.assertIn(f'{seconds // 60} min 00 sec', output)
            for claim in ('%', 'All set', 'GB done', 'files are safe', 'perfect'):
                self.assertNotIn(claim, output)

    def test_missing_state_does_not_claim_success(self):
        # Run the real loop once with a vanished state, as during a failed writer.
        output = self.run_splash('''
setterm() { :; }
splash_set() { rm -f "$SPLASH_STATE"; }
sleep() { exit 0; }
splash_start
wait "$SPLASH_PID"
''')
        self.assertIn('Waiting for setup status...', output)
        self.assertNotIn('All set', output)
        self.assertNotIn('%', output)

    def test_stage_writer_publishes_latest_message(self):
        output = self.run_splash('''
splash_set 'Installing your Linux system...'
splash_set 'Checking your Linux system...'
splash_paint "$(cat "$SPLASH_STATE")" / 123
''')
        self.assertIn('Checking your Linux system...', output)
        self.assertNotIn('Installing your Linux system...', output)

    def test_debug_mode_does_not_write_screen(self):
        self.assertEqual(self.run_splash('DEBUG=1; splash_start'), '')


if __name__ == '__main__':
    unittest.main()
