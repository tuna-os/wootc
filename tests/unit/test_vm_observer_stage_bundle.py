"""Actual private bundle packing/readback; no initrd build or target invocation."""
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'payload/vm-observer/stage_bundle.py'))
class BundleBuildControls(unittest.TestCase):
    def test_actual_fixed_source_catalogue_and_native_sha_readback(self):
        with tempfile.TemporaryDirectory(prefix='wootc-observer-stage-') as tmp:
            target=Path(tmp)/'bundle';hashes=MODULE['stage'](target)
            result=subprocess.run(['sha256sum','-c','closure.sha256'],cwd=target,capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            for name,digest in hashes.items():
                self.assertEqual(hashlib.sha256((target/name).read_bytes()).hexdigest(),digest)
                self.assertEqual((target/name).stat().st_mode&0o777,0o444)
            self.assertEqual((target/'wootc_ancestry.py').read_bytes(),(ROOT/'tests/e2e/phase3_ancestry.py').read_bytes())
    def test_actual_build_cli_seals_metadata_from_staged_bytes(self):
        with tempfile.TemporaryDirectory(prefix='wootc-observer-cli-') as tmp:
            target=Path(tmp)/'bundle';metadata=Path(tmp)/'builder-protocol.json'
            result=subprocess.run([sys.executable,'-I','-S','-B',str(ROOT/'payload/vm-observer/stage_bundle.py'),str(target),str(ROOT/'payload/builder/protocol.json'),str(metadata)],capture_output=True,text=True,timeout=3)
            self.assertEqual(result.returncode,0,result.stderr)
            hashes=json.loads(result.stdout)
            value=json.loads(metadata.read_text())
            for name,digest in value['observerInstall']['sourceHashes'].items():
                self.assertEqual(digest,hashes[name])
                self.assertEqual(digest,hashlib.sha256((target/name).read_bytes()).hexdigest())
            retained=metadata.read_bytes()
            result=subprocess.run([sys.executable,'-I','-S','-B',str(ROOT/'payload/vm-observer/stage_bundle.py'),str(target),str(ROOT/'payload/builder/protocol.json'),str(metadata)],capture_output=True,text=True,timeout=3)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(metadata.read_bytes(),retained)

    def test_generated_runtime_metadata_binds_actual_staged_service_bytes(self):
        with tempfile.TemporaryDirectory(prefix='wootc-observer-metadata-') as tmp:
            target=Path(tmp)/'bundle';hashes=MODULE['stage'](target)
            value=json.loads(MODULE['protocol_metadata'](ROOT/'payload/builder/protocol.json',hashes))
            expected=value['observerInstall']['sourceHashes']
            self.assertEqual(set(expected),{'boot_probe.py','wootc_ancestry.py','wootc-observer.service'})
            for name,digest in expected.items():
                self.assertEqual(hashlib.sha256((target/name).read_bytes()).hexdigest(),digest)
            self.assertEqual(value['accountModes'],['image-default','create'])
            self.assertNotIn('sourceHashes',json.loads((ROOT/'payload/builder/protocol.json').read_text())['observerInstall'])

    def test_existing_namespace_preserved_and_changed_staged_source_refuses_native_closure(self):
        with tempfile.TemporaryDirectory(prefix='wootc-observer-stage-') as tmp:
            target=Path(tmp)/'bundle';MODULE['stage'](target)
            with self.assertRaises(ValueError):MODULE['stage'](target)
            (target/'installer_entry.py').chmod(0o600);(target/'installer_entry.py').write_text('foreign')
            result=subprocess.run(['sha256sum','-c','closure.sha256'],cwd=target,capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('installer_entry.py: FAILED',result.stdout)

if __name__=='__main__':unittest.main()
