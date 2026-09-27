"""Actual local Linux interpreter controls; these are not target guest proof."""
from pathlib import Path
import subprocess
import unittest

SOURCE=(Path(__file__).resolve().parents[2]/'payload/vm-observer/python_environment.py').read_bytes()
PROGRAM=SOURCE+b'\nimport json\nprint(json.dumps(inspect_environment(), sort_keys=True))\n'

class EnvironmentControls(unittest.TestCase):
    def call(self,flags):return subprocess.run(['/usr/bin/python3',*flags,'-'],input=PROGRAM,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
    def test_actual_system_isolated_no_site_interpreter(self):
        r=self.call(['-I','-S','-B']);self.assertEqual(r.returncode,0,r.stderr.decode());self.assertIn(b'"loadedDependencies"',r.stdout);self.assertIn(b'/usr/bin/python',r.stdout)
    def test_actual_site_loading_mode_refuses(self):
        r=self.call(['-I','-B']);self.assertNotEqual(r.returncode,0);self.assertIn(b'requires -I -S -B',r.stderr);self.assertEqual(r.stdout,b'')
    def test_actual_nonisolated_mode_refuses(self):
        r=self.call(['-S','-B']);self.assertNotEqual(r.returncode,0);self.assertIn(b'requires -I -S -B',r.stderr);self.assertEqual(r.stdout,b'')

if __name__=='__main__':unittest.main()
