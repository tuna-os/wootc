#!/usr/bin/env python3
"""Run the actual native proof acceptance consumer with controlled QGA results."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOT = '12345678-1234-1234-1234-123456789abc'
PROOF = f'SCHEMA=1\nUNAME=Linux\nCMDLINE=root=UUID=native ro\nTARGET=/dev/sdb\nBOOT_ID={BOOT}\n'


class Phase3Tests(unittest.TestCase):
    def consumer(self, module=None, **overrides):
        source = (module or ROOT/'tests/e2e/run-e2e.sh').read_text()
        start = source.index('    # A failed guest command cannot establish facts even with plausible stdout.')
        body = source[start:source.index('\nelse\n    step "Rebooting Phase 2 Linux', start)]
        prefix = '''set -Eeuo pipefail
P3_TARGET=/dev/sdb; RUN_ID=current-run
step() { :; }; fail() { echo "FAIL $*"; }
infra_fail() { echo "INFRA $*"; }
product_fail() { echo "PRODUCT-FAIL $*"; }
product_pass() { echo "PRODUCT-PASS $*"; }
qga_call() {
 if [[ "$*" == *UNAME=* ]]; then printf '%s' "$PROOF"; return "$PROOF_RC"; fi
 printf '%s' "$DATA"; return "$DATA_RC"
}
'''
        env = dict(PROOF=PROOF, PROOF_RC='0', DATA='SRC=/dev/sdb3\nwootc-e2e-userdata current-run\n',
                   DATA_RC='0', SCRIPT_DIR=str(ROOT/'tests/e2e'))
        return subprocess.run(['bash', '-c', prefix+body], text=True, capture_output=True,
                              timeout=4, env={**os.environ, **env, **overrides})

    def test_successful_native_and_current_data_pass(self):
        r = self.consumer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('PRODUCT-PASS native-boot', r.stdout)
        self.assertIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_failed_native_command_with_plausible_stdout_refuses(self):
        for code in ['7', '42', '124']:
            r = self.consumer(PROOF_RC=code)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('INFRA', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_failed_data_command_cannot_assert_persistence(self):
        r = self.consumer(DATA_RC='7')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('PRODUCT-PASS native-boot', r.stdout)
        self.assertIn('INFRA', r.stdout)
        self.assertNotIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_invalid_protocol_is_infrastructure_unknown(self):
        for proof in ['', 'noise\n'+PROOF, PROOF+'UNAME=Linux\n', PROOF.replace('BOOT_ID='+BOOT, 'BOOT_ID=no'),
                      PROOF.replace('CMDLINE=root=UUID=native ro', 'CMDLINE='), PROOF.replace('SCHEMA=1', 'SCHEMA=2')]:
            r = self.consumer(PROOF=proof)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('INFRA', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_successful_wrong_native_facts_are_product_failures(self):
        for proof in [PROOF.replace('UNAME=Linux', 'UNAME=Windows_NT'),
                      PROOF.replace('TARGET=/dev/sdb', 'TARGET=/dev/sdc'),
                      PROOF.replace('root=UUID=native ro', 'loop=/wootc/disks/root.disk ro'),
                      PROOF.replace('root=UUID=native ro', 'ro wootc.rootdisk=/wootc/disks/root.disk')]:
            r = self.consumer(PROOF=proof)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('PRODUCT-FAIL', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_current_run_seed_requires_exact_literal_line(self):
        for data in ['SRC=/dev/sdb3\nwootc-e2e-userdata old-run\n',
                     'SRC=/dev/sdb3\nwootc-e2e-userdata current-run-extra\n',
                     'SRC=/dev/sdb3\nprefix wootc-e2e-userdata current-run\n']:
            r = self.consumer(DATA=data)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_removed_native_status_guard_counterexample(self):
        source = (ROOT/'tests/e2e/run-e2e.sh').read_text()
        source = source.replace('if ! P3_NATIVE_PROOF=$(', 'if P3_NATIVE_PROOF=$(', 1)
        source = source.replace('infra_fail "Phase 3 native boot observation command failed"\n        exit 1', ':', 1)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'mutant.sh'; p.write_text(source)
            r = self.consumer(p, PROOF_RC='7')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('PRODUCT-PASS native-boot', r.stdout)


if __name__ == '__main__':
    unittest.main()
