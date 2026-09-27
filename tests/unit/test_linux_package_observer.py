"""Execute the production live observer with an actual owned fixture socket/process."""
import copy
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[2]
LAUNCH=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/launch.py'))
SERIAL=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/serial-proof.py'))


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.folder=Path(self.temp.name)
        fixture=runpy.run_path(str(ROOT/'tests/unit/test_linux_package_serial.py'))['SerialTests']
        case=fixture('test_serial_only_is_not_runtime_acceptance');case.setUp()
        self.plan=copy.deepcopy(case.plan);self.plan['actualVirtualBytes']=3221225472
        self.records=copy.deepcopy(case.records);self.calls=[];self.acks=[];self.wrong_seed=False
        self.child=subprocess.Popen(['/usr/bin/python3','-c',
            'import socket,sys,time;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen();time.sleep(10)',
            str(self.folder/'qga.sock')],start_new_session=True)
        self.addCleanup(self.stop)
        deadline=time.monotonic()+2
        while not (self.folder/'qga.sock').exists() and self.child.poll() is None and time.monotonic()<deadline:time.sleep(.01)
        self.assertTrue((self.folder/'qga.sock').exists())
        self.observe=LAUNCH['make_observer'](self.folder,self.plan,self.readback,self.acknowledge)

    def stop(self):
        if self.child.poll() is None:self.child.terminate()
        self.child.wait(timeout=2)

    def text(self,count):
        return ''.join(SERIAL['PREFIX']+json.dumps(value)+'\n' for value in self.records[:count])

    def readback(self,folder,record,remaining,phase):
        self.calls.append(phase);self.assertGreater(remaining,0)
        packet=copy.deepcopy(self.records[1 if phase=='old' else 3])
        return {'os':'Linux','bootId':packet['bootId'],'challenge':record['readbackChallenge'],
                'currentInventory':packet['inventory'],'result':packet,'exitStatus':0,
                'sourceSha256':record['qgaReadbackSourceSha256'],
                'seedSha256':'0'*64 if self.wrong_seed else record['seedSha256']}

    def acknowledge(self,folder,record,approved,remaining):
        self.acks.append(approved);self.assertGreater(remaining,0)
        packet=self.records[1]
        result={name:packet[name] for name in ('scratchId','challenge','bootId','seedSha256')}
        result.update(validatedPhase='old',readbackChallenge=record['readbackChallenge'],approvedReadbackSha256=approved)
        return result

    def old_observed(self):
        (self.folder/'serial.log').write_text(self.text(2))
        self.assertIsNone(self.observe(self.child,1))
        self.assertEqual(self.calls,['old']);self.assertEqual(len(self.acks),1)

    def test_old_readback_cannot_start_ack_after_shared_deadline(self):
        original=self.readback
        def slow(*args):
            value=original(*args);time.sleep(.03);return value
        self.observe=LAUNCH['make_observer'](self.folder,self.plan,slow,self.acknowledge)
        (self.folder/'serial.log').write_text(self.text(2))
        with self.assertRaises(TimeoutError):self.observe(self.child,.01)
        self.assertEqual(self.acks,[])

    def test_partial_fourth_live_line_waits_then_actual_completion_accepts(self):
        self.old_observed()
        final=SERIAL['PREFIX']+json.dumps(self.records[3])
        half=len(final)//2
        (self.folder/'serial.log').write_text(self.text(3)+final[:half])
        self.assertIsNone(self.observe(self.child,1));self.assertEqual(self.calls,['old'])
        with (self.folder/'serial.log').open('a') as stream:stream.write(final[half:]+'\n')
        result=self.observe(self.child,1)
        self.assertTrue(result['packageInstallationAccepted']);self.assertEqual(self.calls,['old','new'])

    def test_completed_malformed_fourth_line_refuses_in_production_observe(self):
        self.old_observed()
        (self.folder/'serial.log').write_text(self.text(3)+SERIAL['PREFIX']+'{"broken":\n')
        with self.assertRaises(ValueError):self.observe(self.child,1)
        self.assertEqual(self.calls,['old'])

    def test_missing_final_newline_is_not_complete_even_with_valid_json(self):
        self.old_observed()
        (self.folder/'serial.log').write_text(self.text(4).rstrip('\n'))
        self.assertIsNone(self.observe(self.child,1));self.assertEqual(self.calls,['old'])

    def test_fresh_old_seed_digest_change_refuses_before_advance(self):
        self.wrong_seed=True
        (self.folder/'serial.log').write_text(self.text(2))
        with self.assertRaisesRegex(ValueError,'QGA readback differs'):self.observe(self.child,1)
        self.assertEqual(self.calls,['old']);self.assertEqual(self.acks,[])

    def test_fresh_new_seed_digest_change_refuses_final_acceptance(self):
        self.old_observed();self.wrong_seed=True
        (self.folder/'serial.log').write_text(self.text(4))
        with self.assertRaisesRegex(ValueError,'QGA readback differs'):self.observe(self.child,1)
        self.assertEqual(self.calls,['old','new'])

    def test_new_stages_without_old_handshake_refuse(self):
        (self.folder/'serial.log').write_text(self.text(4))
        with self.assertRaisesRegex(ValueError,'out-of-order'):self.observe(self.child,1)
        self.assertEqual(self.calls,[]);self.assertEqual(self.acks,[])


if __name__=='__main__':unittest.main()
