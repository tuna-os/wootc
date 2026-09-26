"""Exercise the helper contract and refusal paths without block-device writes."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / 'payload/builder/wootc-builder.sh'


class HelperContract(unittest.TestCase):
    def run_helper(self, body):
        return subprocess.run(['bash', '-eu', '-c',
                               '. "$1"\nfailed() { echo "REFUSED:$1"; exit 91; }\n' + body,
                               'helper-test', str(LIB)], text=True, capture_output=True)

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
