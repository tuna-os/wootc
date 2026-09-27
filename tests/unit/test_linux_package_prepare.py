"""Producer source and freeze controls only; this does not build an ISO or start a VM."""
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/prepare.py'))


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)

    def test_actual_freeze_keeps_source_and_exact_readonly_copy(self):
        source=self.root/'source';source.write_bytes(b'public fixture')
        target=self.root/'target';expected=MODULE['sha'](source)
        MODULE['freeze'](source,target,expected)
        self.assertEqual(MODULE['sha'](source),expected);self.assertEqual(MODULE['sha'](target),expected)
        self.assertEqual(target.stat().st_mode&0o777,0o400)

    def test_wrong_source_pin_refuses_without_target(self):
        source=self.root/'source';source.write_bytes(b'foreign');target=self.root/'target'
        with self.assertRaises(ValueError):MODULE['freeze'](source,target,'0'*64)
        self.assertFalse(target.exists())

    def test_source_symlink_refuses_without_target(self):
        source=self.root/'source';source.write_bytes(b'fixture');link=self.root/'link';link.symlink_to(source)
        with self.assertRaises(ValueError):MODULE['freeze'](link,self.root/'target',MODULE['sha'](source))

    def test_incomplete_acquisition_refuses_before_any_producer_write(self):
        inputs=self.root/'inputs';inputs.mkdir();(inputs/'acquisition.json').write_text('{"complete":false}')
        calls=[]
        with self.assertRaisesRegex(ValueError,'complete acquisition'):
            MODULE['prepare'](inputs,self.root/'scratch',lambda *args,**kwargs:calls.append(args))
        self.assertEqual(calls,[]);self.assertFalse((self.root/'scratch').exists())

    def test_changed_dependency_source_refuses_before_any_producer_write(self):
        inputs=self.root/'inputs';inputs.mkdir()
        (inputs/'acquisition.json').write_text(json.dumps({'complete':True,'runtimeExecuted':False,'sourcePlanSha256':'0'*64}))
        calls=[]
        with self.assertRaisesRegex(ValueError,'dependency source'):
            MODULE['prepare'](inputs,self.root/'scratch',lambda *args,**kwargs:calls.append(args))
        self.assertEqual(calls,[]);self.assertFalse((self.root/'scratch').exists())


if __name__=='__main__':unittest.main()
