"""Actual failed subprocess bytes survive into bounded typed guest evidence."""
import json,runpy,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
CONSUMER=runpy.run_path(str(ROOT/'tests/e2e/esp-chain/package-consumer.py'))
LAUNCH=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/launch.py'))
BOOTSTRAP=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/bootstrap.py'))
class FailureTests(unittest.TestCase):
    def test_actual_failed_command_retains_status_and_both_streams(self):
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            CONSUMER['execute'](['/usr/bin/python3','-c','import sys;print("actual package output");print("actual package cause",file=sys.stderr);sys.exit(37)'])
        error=raised.exception
        self.assertEqual(error.returncode,37)
        self.assertEqual(error.stdout,b'actual package output\n')
        self.assertEqual(error.stderr,b'actual package cause\n')
    def test_actual_guest_publication_preserves_failure_not_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            seed=Path(temporary);(seed/'manifest.json').write_text(json.dumps({'scratchId':'a'*32,'challenge':'b'*64,'vmUuid':'12345678-1234-1234-1234-123456789abc'}))
            records=[]
            def fail(*_):
                return CONSUMER['execute'](['/usr/bin/python3','-c','import sys;print("stdout");print("cause",file=sys.stderr);sys.exit(17)'])
            with self.assertRaises(subprocess.CalledProcessError):
                BOOTSTRAP['run_reported'](seed,seed/'workspace',records.append,operation=fail,observe_boot=lambda:'11111111-2222-3333-4444-555555555555')
            self.assertEqual(len(records),3);record=records[-1]
            self.assertEqual(record['stage'],'failed');self.assertEqual(record['commandFailure']['returnCode'],17)
            self.assertEqual(record['commandFailure']['stdout'],'stdout\n');self.assertEqual(record['commandFailure']['stderr'],'cause\n')
            self.assertFalse((seed/'workspace').exists())
    def test_evidence_truncation_is_explicit_and_total_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            seed=Path(temporary);(seed/'manifest.json').write_text('{}');records=[]
            def fail(*_):raise subprocess.CalledProcessError(100,['apt-get'],output=b'x'*10000,stderr=b'y'*20000)
            with self.assertRaises(subprocess.CalledProcessError):BOOTSTRAP['run_reported'](seed,seed/'workspace',records.append,operation=fail,observe_boot=lambda:'11111111-2222-3333-4444-555555555555')
            evidence=records[-1]['commandFailure']
            self.assertEqual((evidence['stdoutBytes'],evidence['stderrBytes']),(10000,20000))
            self.assertTrue(evidence['stdoutTruncated']);self.assertTrue(evidence['stderrTruncated'])
            self.assertLess(len(json.dumps(records[-1]).encode()),16384)
    def test_full_binary_failure_chunks_reconstruct_exactly_and_mutants_refuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            seed=Path(temporary);(seed/'manifest.json').write_text('{}');records=[]
            stdout=bytes(range(256))*100;stderr=b'actual final cause at tail'+b'\xff'*10000
            def fail(*_):raise subprocess.CalledProcessError(100,['apt-get'],output=stdout,stderr=stderr)
            with self.assertRaises(subprocess.CalledProcessError):BOOTSTRAP['run_reported'](seed,seed/'workspace',records.append,operation=fail,observe_boot=lambda:'11111111-2222-3333-4444-555555555555')
            LAUNCH['retain_command_output'](seed,records,records[-1])
            self.assertEqual((seed/'command-failure.stdout').read_bytes(),stdout);self.assertEqual((seed/'command-failure.stderr').read_bytes(),stderr)
            for mutate in ('missing','duplicate','changed','wrongboot'):
                broken=json.loads(json.dumps(records))
                if mutate=='missing':broken.pop(0)
                elif mutate=='duplicate':broken.insert(0,broken[0])
                elif mutate=='changed':broken[0]['data']='eA=='
                else:broken[0]['bootId']='22222222-2222-3333-4444-555555555555'
                with self.subTest(mutate=mutate),self.assertRaises(ValueError):LAUNCH['retain_command_output'](seed,broken,records[-1])
    def test_actual_invalid_utf8_and_unicode_failure_preserves_complete_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            seed=Path(temporary);manifest={'scratchId':'a'*32,'challenge':'b'*64,'vmUuid':'12345678-1234-1234-1234-123456789abc'}
            (seed/'manifest.json').write_text(json.dumps(manifest));records=[]
            def fail(*_):return CONSUMER['execute'](['/usr/bin/python3','-c','import os,sys;os.write(1,bytes(range(256))*80);os.write(2,("é"*12000).encode()+b"\\xff"*10000);sys.exit(42)'])
            with self.assertRaises(subprocess.CalledProcessError) as raised:BOOTSTRAP['run_reported'](seed,seed/'workspace',records.append,operation=fail,observe_boot=lambda:'11111111-2222-3333-4444-555555555555')
            self.assertLess(len(json.dumps(records[-1]).encode()),16384)
            self.assertEqual(records[-1]['commandFailure']['returnCode'],42)
            (seed/'serial.log').write_text(''.join(BOOTSTRAP['PREFIX']+json.dumps(record)+'\n' for record in records))
            def forbidden(*_):raise AssertionError('QGA is unavailable; it cannot gate complete failure retention')
            observer=LAUNCH['make_observer'](seed,dict(manifest,actualVirtualBytes=1024**3),forbidden,forbidden)
            with self.assertRaisesRegex(ValueError,'guest producer refused'):observer(None,10)
            self.assertEqual((seed/'command-failure.stdout').read_bytes(),raised.exception.stdout)
            self.assertEqual((seed/'command-failure.stderr').read_bytes(),raised.exception.stderr)
if __name__=='__main__':unittest.main()
