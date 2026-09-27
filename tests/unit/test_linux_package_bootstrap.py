"""Execute guest producer with explicit package/environment fixtures; no installation."""
import copy
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/bootstrap.py'))
BOOT='12345678-1234-1234-1234-123456789abc'


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.seed=self.root/'seed';self.seed.mkdir()
        self.workspace=self.root/'work';self.events=[];self.operations=[]
        self.before={'fixture':{'version':'1','architecture':'all'}}
        self.old={'fixture':{'version':'2','architecture':'all'}}
        self.new={'fixture':{'version':'3','architecture':'all'}}
        self.state=copy.deepcopy(self.before)
        self.policy={'scratchId':'a'*32,'phases':{phase:dict(beforeInventory=before,afterInventory=after,packages=[],allowedRemovals=[])
                     for phase,before,after in [('old',self.before,self.old),('new',self.old,self.new)]}}
        (self.seed/'packages.json').write_text(json.dumps(self.policy))
        (self.seed/'bootstrap.py').write_bytes((ROOT/'tests/e2e/package-runtime/bootstrap.py').read_bytes())
        (self.seed/'package-consumer.py').write_text('fixture-only source')
        (self.seed/'readback.py').write_text('fixture-only source')
        self.manifest={'schemaVersion':1,'scratchId':'a'*32,'challenge':'b'*64,'vmUuid':BOOT,
                       'baselineSha256':MODULE['canonical_inventory'](self.before),
                       'helperHashes':{name:MODULE['sha'](self.seed/name) for name in ('bootstrap.py','package-consumer.py','packages.json','readback.py')}}
        self.save()
        self.consume_error=False;self.false_result=False
        def inventory(*args):return copy.deepcopy(self.state)
        def consume(workspace,phase):
            self.operations.append(phase)
            if self.consume_error:raise ValueError('actual consumer fixture failed')
            self.state=copy.deepcopy(self.policy['phases'][phase]['afterInventory'])
            return {'installedPhase':'foreign' if self.false_result else phase,'scratchId':'a'*32}
        self.consumer={'inventory':inventory,'consume':consume,'execute':object()}

    def save(self):(self.seed/'manifest.json').write_text(json.dumps(self.manifest))

    def run_producer(self,boot=lambda:BOOT):
        return MODULE['run'](self.seed,self.workspace,self.events.append,boot,
                            lambda path:self.consumer,lambda *args:{'seedSha256':'c'*64})

    def test_actual_producer_reports_complete_same_boot_sequence(self):
        result=self.run_producer()
        self.assertEqual([event['stage'] for event in self.events],['baseline-observed','old-installed','new-installed','complete'])
        self.assertEqual(self.operations,['old','new'])
        self.assertEqual(json.loads((self.workspace/'result.json').read_text()),result)
        self.assertEqual(result['inventory'],self.new)

    def test_wrong_baseline_refuses_before_consumer_or_serial_success(self):
        self.state['fixture']['version']='foreign'
        with self.assertRaisesRegex(ValueError,'baseline'):self.run_producer()
        self.assertEqual(self.operations,[]);self.assertEqual(self.events,[])

    def test_wrong_or_incomplete_source_closure_refuses_before_inventory(self):
        (self.seed/'package-consumer.py').write_text('changed')
        with self.assertRaisesRegex(ValueError,'source differs'):self.run_producer()
        self.assertEqual(self.operations,[]);self.assertEqual(self.events,[])

    def test_cached_workspace_is_not_success_authority(self):
        self.workspace.mkdir();(self.workspace/'result.json').write_text('{"stage":"complete"}')
        with self.assertRaisesRegex(ValueError,'exclusive'):self.run_producer()
        self.assertEqual(self.operations,[]);self.assertEqual(self.events,[])

    def test_consumer_failure_never_publishes_install_or_complete(self):
        self.consume_error=True
        with self.assertRaisesRegex(ValueError,'fixture failed'):self.run_producer()
        self.assertEqual([event['stage'] for event in self.events],['baseline-observed'])
        self.assertFalse((self.workspace/'result.json').exists())

    def test_false_consumer_result_never_publishes_install(self):
        self.false_result=True
        with self.assertRaisesRegex(ValueError,'actual phase'):self.run_producer()
        self.assertEqual([event['stage'] for event in self.events],['baseline-observed'])
        self.assertFalse((self.workspace/'result.json').exists())

    def test_boot_change_refuses_before_consumer(self):
        values=iter([BOOT,'ffffffff-1234-1234-1234-123456789abc'])
        with self.assertRaisesRegex(ValueError,'boot changed'):self.run_producer(lambda:next(values))
        self.assertEqual(self.operations,[]);self.assertEqual(self.events,[])

    def test_boot_change_after_install_never_publishes_success(self):
        values=iter([BOOT,BOOT,BOOT,'ffffffff-1234-1234-1234-123456789abc'])
        with self.assertRaisesRegex(ValueError,'boot changed'):self.run_producer(lambda:next(values))
        self.assertEqual(self.operations,['old'])
        self.assertEqual([event['stage'] for event in self.events],['baseline-observed'])
        self.assertFalse((self.workspace/'result.json').exists())


if __name__=='__main__':unittest.main()
