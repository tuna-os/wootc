"""Execute the real comparator; typed serial alone never accepts package installation."""
import copy
import json
from pathlib import Path
import runpy
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/serial-proof.py'))
BOOT='12345678-1234-1234-1234-123456789abc'


class SerialTests(unittest.TestCase):
    def setUp(self):
        before={'fixture':{'version':'1','architecture':'all'}}
        old={'fixture':{'version':'2','architecture':'all'}}
        new={'fixture':{'version':'3','architecture':'all'}}
        self.plan={'scratchId':'a'*32,'challenge':'b'*64,'seedSha256':'c'*64,
                   'helperHashes':{'bootstrap.py':'d'*64,'package-consumer.py':'d'*64,'packages.json':'e'*64,'readback.py':'f'*64},'policySha256':'e'*64,
                   'readbackChallenge':'9'*64,'qgaReadbackSourceSha256':'f'*64,'policy':{'phases':{'old':{'beforeInventory':before,'afterInventory':old},'new':{'afterInventory':new}}}}
        self.records=[]
        for stage,inventory in zip(MODULE['STAGES'],[before,old,new,new]):
            self.records.append(dict(schemaVersion=1,exitStatus=0,bootId=BOOT,stage=stage,inventory=inventory,
                inventorySha256=MODULE['inventory_digest'](inventory),**{k:self.plan[k] for k in ('scratchId','challenge','seedSha256','helperHashes','policySha256')}))
        self.qga={'os':'Linux','bootId':BOOT,'challenge':self.plan['readbackChallenge'],'currentInventory':new,
                  'result':copy.deepcopy(self.records[-1]),'sourceSha256':'f'*64,'exitStatus':0}

    def serial(self):return '\n'.join(MODULE['PREFIX']+json.dumps(value) for value in self.records)

    def test_serial_only_is_not_runtime_acceptance(self):
        self.assertFalse(MODULE['validate'](self.serial(),self.plan)['packageInstallationAccepted'])

    def test_positive_exact_stages_and_independent_qga_accept_package_scope(self):
        result=MODULE['validate'](self.serial(),self.plan,self.qga)
        self.assertTrue(result['packageInstallationAccepted']);self.assertFalse(result['firmwareAcceptance'])

    def test_cloudinit_message_without_producer_stages_refuses(self):
        with self.assertRaises(ValueError):MODULE['validate']('cloud-init done: packages installed',self.plan,self.qga)

    def test_missing_duplicate_and_out_of_order_stages_refuse(self):
        original=copy.deepcopy(self.records)
        for records in (original[:-1],original+[original[-1]],list(reversed(original))):
            self.records=records
            with self.assertRaises(ValueError):MODULE['validate'](self.serial(),self.plan,self.qga)

    def test_wrong_seed_boot_challenge_status_and_inventory_refuse(self):
        original=copy.deepcopy(self.records)
        for name,value in (('seedSha256','0'*64),('challenge','0'*64),('bootId','ffffffff-1234-1234-1234-123456789abc'),('exitStatus',1),('exitStatus',False),('inventory',{}),('inventorySha256','0'*64)):
            self.records=copy.deepcopy(original);self.records[1][name]=value
            with self.subTest(name=name):
                with self.assertRaises(ValueError):MODULE['validate'](self.serial(),self.plan,self.qga)

    def test_cached_or_failed_qga_refuses(self):
        for name,value in (('bootId','ffffffff-1234-1234-1234-123456789abc'),('challenge','0'*64),('exitStatus',1),('exitStatus',False),('os','Windows_NT'),('currentInventory',{}),('sourceSha256','0'*64),('result',{})):
            observed=copy.deepcopy(self.qga);observed[name]=value
            with self.subTest(name=name):
                with self.assertRaises(ValueError):MODULE['validate'](self.serial(),self.plan,observed)

    def test_truncated_and_oversized_serial_refuse(self):
        with self.assertRaises(ValueError):MODULE['validate'](self.serial()[:-4],self.plan,self.qga)
        with self.assertRaises(ValueError):MODULE['validate']('x'*262145,self.plan,self.qga)


if __name__=='__main__':unittest.main()
