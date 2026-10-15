"""Actual acquisition boundary controls; failed tiny fixtures make no network request."""
import io
import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/acquire.py'))


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.stage=self.root/'stage';self.requests=[]

    def opener(self,url,**kwargs):
        self.requests.append(url);return io.BytesIO(b'partial fixture only')

    def test_wrong_reviewed_plan_refuses_before_network_and_preserves_failure(self):
        wrong=self.root/'wrong.json';wrong.write_text('{}')
        with patch.dict(MODULE['acquire'].__globals__,{'PLAN':wrong}):
            with self.assertRaisesRegex(ValueError,'source pins'):MODULE['acquire'](self.stage,self.opener)
        self.assertEqual(self.requests,[])
        record=json.loads((self.stage/'acquisition.json').read_text())
        self.assertFalse(record['complete']);self.assertEqual(record['failureType'],'ValueError')

    def test_actual_free_space_failure_refuses_before_network(self):
        with patch.object(MODULE['shutil'],'disk_usage',return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(ValueError,'free-space'):MODULE['acquire'](self.stage,self.opener)
        self.assertEqual(self.requests,[])

    def test_partial_size_failure_retains_only_owned_partial_and_proof(self):
        with self.assertRaisesRegex(ValueError,'size or published digest'):MODULE['acquire'](self.stage,self.opener)
        self.assertEqual(len(self.requests),1)
        record=json.loads((self.stage/'acquisition.json').read_text())
        self.assertFalse(record['complete']);self.assertEqual(record['files'][0]['bytes'],20)
        self.assertEqual((self.stage/'cloud.qcow2.partial').read_bytes(),b'partial fixture only')
        self.assertFalse((self.stage/'cloud.qcow2').exists())
        self.assertEqual(self.stage.stat().st_mode&0o777,0o700)

    def test_existing_stage_is_never_reused_or_deleted(self):
        self.stage.mkdir();(self.stage/'retained').write_text('retained bytes')
        with self.assertRaises(FileExistsError):MODULE['acquire'](self.stage,self.opener)
        self.assertEqual((self.stage/'retained').read_text(),'retained bytes');self.assertEqual(self.requests,[])


if __name__=='__main__':unittest.main()
