"""Exercise the helper contract and refusal paths without block-device writes."""
import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / 'payload/builder/wootc-builder.sh'


class HelperContract(unittest.TestCase):
    def run_helper(self, body, input_data=None):
        return subprocess.run(['bash', '-eu', '-c',
                               '. "$1"\nfailed() { echo "REFUSED:$1"; exit 91; }\n' + body,
                               'helper-test', str(LIB)], text=True, capture_output=True, input=input_data)

    def test_pid1_restores_administrator_tool_path(self):
        # Ubuntu keeps chroot in /usr/sbin, like Yellowfin's useradd. Stop at
        # the first mount so this exercises PID 1 setup without mount writes.
        result = self.run_helper('''
mount() { command -v chroot; trap - EXIT; exit 0; }
PATH=/usr/bin:/bin
builder_main
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().endswith('/sbin/chroot'), result.stdout)

    def test_pinned_image_and_ids(self):
        base = 'RUN_ID=run_123456 INSTALL_ID=install_123456; '
        result = self.run_helper(base + 'IMAGE=ghcr.io/example/os@sha256:' + 'a' * 64 + '; validate_contract')
        self.assertEqual(result.returncode, 0, result.stderr)
        for image in ('ghcr.io/example/os:latest', 'evil;command', 'ghcr.io/example/os@sha256:123'):
            result = self.run_helper(base + f'IMAGE="{image}"; validate_contract')
            self.assertEqual(result.returncode, 91)
            self.assertIn('pinned', result.stdout)

    def test_missing_identity_refused(self):
        result = self.run_helper('IMAGE=ghcr.io/example/os@sha256:' + 'a' * 64 +
                                 '; RUN_ID=""; INSTALL_ID=install_123456; validate_contract')
        self.assertEqual(result.returncode, 91)
        self.assertIn('identity', result.stdout)

    def test_disk_refusals_happen_before_format(self):
        # Mock observations, not the guard. Every scenario executes prepare_storage.
        common = r'''
function [() { if test "$1" = -b; then return 0; fi; builtin [ "$@"; }
cat() { if [[ $1 == */vda/serial ]]; then echo "${ROOT_SERIAL:-wootc-root}"; else echo wootc-scratch; fi; }
lsblk() { if [[ $1 == -dn ]]; then echo disk; else echo "${@: -1}"; fi; }
blockdev() { echo "${CAPACITY:-34359738368}"; }
wipefs() { if [[ ${@: -1} == /dev/vdb && ${DIRTY:-0} == 1 ]]; then echo '{"signatures":[{}]}'; else echo '{"signatures":[]}'; fi; }
findmnt() { return 1; }
mkfs.ext4() { echo FORMATTED; exit 92; }
'''
        for setup, reason in [('ROOT_SERIAL=untrusted', 'identity'),
                              ('DIRTY=1', 'contains data'),
                              ('CAPACITY=1024', '32 GiB')]:
            result = self.run_helper(common + setup + '\nprepare_storage')
            self.assertEqual(result.returncode, 91, result.stderr)
            self.assertIn(reason, result.stdout)
            self.assertNotIn('FORMATTED', result.stdout)

    def test_private_account_contract_and_no_secret_output(self):
        config = {'schemaVersion': 1, 'runId': 'run_123456', 'installId': 'install_123456',
                  'username': 'alice', 'passwordHash': '$6$salt$' + 'a' * 86}
        script = 'RUN_ID=run_123456 INSTALL_ID=install_123456; validate_account "$(cat)"'
        result = self.run_helper(script, json.dumps(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(config['passwordHash'], result.stdout + result.stderr)
        for key, value in [('runId', 'stale_run'), ('username', 'root'),
                           ('username', 'alice\nroot'), ('passwordHash', 'plaintext'),
                           ('passwordHash', config['passwordHash'] + '\nroot:injected')]:
            changed = dict(config, **{key: value})
            result = self.run_helper(script, json.dumps(changed))
            self.assertEqual(result.returncode, 91, (key, result.stderr))
            self.assertNotIn(changed['passwordHash'], result.stdout + result.stderr)

    def test_no_deployment_cannot_be_verified(self):
        result = self.run_helper('''
partprobe() { :; }; mdev() { :; }; mkdir() { :; }
verify_disk
''')
        self.assertEqual(result.returncode, 91)
        self.assertIn('no fallback EFI loader', result.stdout)
        self.assertNotIn('STATUS=SUCCESS', result.stdout)


if __name__ == '__main__':
    unittest.main()
