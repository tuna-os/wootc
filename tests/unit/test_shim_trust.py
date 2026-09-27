#!/usr/bin/env python3
"""The public CLI must not authorize legacy certificate-only grading."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
class TrustCLI(unittest.TestCase):
    def run_cli(self,*args,**env):
        return subprocess.run(['python3',str(ROOT/'payload/migration/wootc-shim-trust'),*args],
             env=dict(os.environ,WOOTC_CHAIN_LIBRARY=str(ROOT/'payload/migration/lib'),**env),capture_output=True,text=True)
    def test_single_file_certificate_metadata_cannot_authorize(self):
        for action in ('check','authorities'):
            result=self.run_cli(action,'candidate','current')
            self.assertEqual(result.returncode,2);self.assertIn('cannot authorize',result.stderr)
    def test_missing_complete_trio_refuses(self):
        result=self.run_cli('chain','/nonexistent-current','/nonexistent-new')
        self.assertNotEqual(result.returncode,0)
    def test_unknown_firmware_database_refuses(self):
        result=self.run_cli('db',WOOTC_EFIVARS='/nonexistent-efivars')
        self.assertNotEqual(result.returncode,0)
    def test_non_pe_sbat_refuses(self):
        with tempfile.NamedTemporaryFile() as file:
            file.write(b'issuer=Microsoft UEFI CA; shim,99');file.flush()
            self.assertNotEqual(self.run_cli('sbat',file.name).returncode,0)
if __name__=='__main__':unittest.main()
