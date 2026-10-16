"""Execute guest readback/advance sources with explicit OS-observation fixtures."""
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
BOOT='12345678-1234-1234-1234-123456789abc'


class ReadbackTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.seed=Path(self.temp.name)/'seed';self.seed.mkdir()
        self.work=Path(self.temp.name)/'work';self.work.mkdir()
        self.inventory={'fixture':{'version':'2','architecture':'all'}}
        self.result=dict(stage='old-installed',scratchId='a'*32,challenge='b'*64,bootId=BOOT,seedSha256='c'*64)
        (self.work/'phase-result.json').write_text(json.dumps(self.result))
        for name in ('readback.py','advance.py'):
            (self.seed/name).write_bytes((ROOT/'tests/e2e/package-runtime'/name).read_bytes())
        # These are observation fixtures, not a guest OS or installation proof.
        (self.seed/'bootstrap.py').write_text("import json\nfrom pathlib import Path\ndef actual_environment(*args):return {'seedSha256':'d'*64}\ndef boot_id():return "+repr(BOOT)+"\ndef atomic_result(work,name,value):(Path(work)/name).write_text(json.dumps(value))\n")
        (self.seed/'package-consumer.py').write_text('execute=None\ndef inventory(*args):return '+repr(self.inventory)+'\n')
        (self.seed/'packages.json').write_text(json.dumps({'phases':{'old':{'beforeInventory':{},'afterInventory':self.inventory,'allowedRemovals':[]}}}))
        names=('bootstrap.py','package-consumer.py','packages.json','readback.py','advance.py')
        manifest={'challenge':'b'*64,'helperHashes':{name:hashlib.sha256((self.seed/name).read_bytes()).hexdigest() for name in names}}
        (self.seed/'manifest.json').write_text(json.dumps(manifest))
        self.probe=runpy.run_path(str(self.seed/'readback.py'))['probe']
        self.advance=runpy.run_path(str(self.seed/'advance.py'))['advance']

    def approved(self):
        observed=self.probe(self.seed,self.work,'e'*64,'old')
        return hashlib.sha256(json.dumps(observed,sort_keys=True,separators=(',',':')).encode()).hexdigest()

    def test_actual_probe_exports_fresh_seed_not_cached_result(self):
        observed=self.probe(self.seed,self.work,'e'*64,'old')
        self.assertEqual(observed['seedSha256'],'d'*64)
        self.assertEqual(observed['result']['seedSha256'],'c'*64)

    def test_actual_advance_requires_exact_independently_approved_readback(self):
        result=self.advance(self.seed,self.work,'e'*64,self.approved())
        self.assertEqual(result['validatedPhase'],'old')
        self.assertTrue((self.work/'advance-old.json').exists())
        with self.assertRaisesRegex(ValueError,'already exists'):self.advance(self.seed,self.work,'e'*64,self.approved())

    def test_changed_old_result_after_approval_never_writes_ack(self):
        approved=self.approved();self.result['bootId']='foreign'
        (self.work/'phase-result.json').write_text(json.dumps(self.result))
        with self.assertRaisesRegex(ValueError,'changed'):self.advance(self.seed,self.work,'e'*64,approved)
        self.assertFalse((self.work/'advance-old.json').exists())

    def test_wrong_approved_digest_never_writes_ack(self):
        with self.assertRaisesRegex(ValueError,'changed'):self.advance(self.seed,self.work,'e'*64,'0'*64)
        self.assertFalse((self.work/'advance-old.json').exists())


if __name__=='__main__':unittest.main()
