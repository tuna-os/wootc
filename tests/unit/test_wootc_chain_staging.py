#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.verifier=self.root/'verifier';self.verifier.mkdir()
        self.helpers=self.root/'helpers';self.helpers.mkdir()
        for n in ('sbverify','sbpehash','ld-linux-x86-64.so.2','libcrypto.so.3','libc.so.6'):
            p=self.verifier/n;p.write_bytes(b'ELF staging fixture');p.chmod(0o755)
        for n in ('wootc_pe','wootc_chain_verify','wootc_chain_source','wootc_boot_identity','wootc_esp_transaction'):
            p=self.helpers/(n+'.py');p.write_text('# Python data fixture\n');p.chmod(0o755)
        self.initdir=self.root/'init';self.initdir.mkdir()

    def tearDown(self):self.temp.cleanup()

    def stage(self,fail=False):
        script='''set -e
source "$1"
initdir="$2"
inst_simple() {
 mkdir -p "$initdir${2%/*}"
 cp "$1" "$initdir$2"
}
# Use an explicit copy-failure stub independently from fixture permissions.
if [[ "$5" == fail ]]; then inst_simple() { return 18; }; fi
stage_signed_chain_payloads "$3" "$4"
'''
        return subprocess.run(['bash','-c',script,'stage',str(ROOT/'payload/deployer/module-setup.sh'),
                               str(self.initdir),str(self.verifier),str(self.helpers),'fail' if fail else 'ok'],capture_output=True)

    def test_foreign_elf_closure_and_python_are_readable_data_not_initramfs_executables(self):
        result=self.stage();self.assertEqual(result.returncode,0,result.stderr.decode())
        staged=list(self.initdir.rglob('*'));files=[p for p in staged if p.is_file()]
        self.assertEqual(len(files),10)
        for p in files:self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o644)
        self.assertEqual((self.initdir/'usr/lib/wootc/sbverify/sbverify').read_bytes(),b'ELF staging fixture')

    def test_missing_closure_component_fails_before_staging(self):
        (self.verifier/'libcrypto.so.3').unlink()
        self.assertNotEqual(self.stage().returncode,0)
        self.assertEqual(list(self.initdir.rglob('*')),[])

    def test_missing_python_helper_fails_before_staging(self):
        (self.helpers/'wootc_boot_identity.py').unlink()
        self.assertNotEqual(self.stage().returncode,0)
        self.assertEqual(list(self.initdir.rglob('*')),[])

    def test_copy_failure_is_not_swallowed_by_function(self):
        self.assertNotEqual(self.stage(fail=True).returncode,0)


if __name__=='__main__':unittest.main()
