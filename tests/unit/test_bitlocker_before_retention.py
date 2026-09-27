import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('retain', ROOT / 'tests/e2e/retain-bitlocker-before-receipt.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
GUID = '1' * 32
BEFORE = dict(schemaVersion=1, stage='before', mountPoint='C:', volumeStatus='FullyEncrypted', percentage=100, protection='Off', tpmPresent=True, tpmReady=True, protectors=[], runId=GUID)


class RetentionTests(unittest.TestCase):
    def test_exact_safe_bytes_and_refusals(self):
        raw = json.dumps(BEFORE, separators=(',', ':')).encode()
        self.assertEqual(MODULE.validate(raw + b'\r\n', GUID), raw)
        invalid = [raw + b' ' , b'x' * 16385, b'{}', raw.replace(b'"runId":', b'"schemaVersion":1,"runId":')]
        for field, value in [('runId', '2' * 32), ('percentage', True), ('tpmReady', 'True'), ('recoveryPassword', 'public-sensitive'), ('protectors', [{'id': 'bad', 'type': 'RecoveryPassword'}])]:
            changed = dict(BEFORE); changed[field] = value
            invalid.append(json.dumps(changed, separators=(',', ':')).encode())
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.validate(value, GUID)

    def test_private_exclusive_retention_and_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp); raw = json.dumps(BEFORE, separators=(',', ':')).encode() + b'\r\n'
            (base / 'input').write_bytes(raw)
            arguments = ['python3', str(ROOT / 'tests/e2e/retain-bitlocker-before-receipt.py'), str(base / 'input'), str(base / 'retained'), GUID, 'F:\\wootc\\install\\bitlocker-key.txt.activation-' + GUID + '.json', 'host-run', str(ROOT / 'tests/e2e/fixture-bitlocker-key.ps1')]
            subprocess.run(arguments, check=True)
            self.assertEqual((base / 'retained' / (GUID + '.raw.json')).read_bytes(), raw)
            self.assertEqual((base / 'retained').stat().st_mode & 0o777, 0o700)
            for path in (base / 'retained').iterdir(): self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            receipt = json.loads((base / 'retained' / (GUID + '.provenance.json')).read_bytes())
            self.assertEqual(receipt['hostRunId'], 'host-run')
            self.assertFalse(receipt['failureStageKnown'])
            self.assertNotEqual(receipt['rawSha256'], receipt['canonicalSha256'])
            self.assertNotEqual(subprocess.run(arguments, capture_output=True).returncode, 0)
            self.assertEqual((base / 'retained' / (GUID + '.raw.json')).read_bytes(), raw)

    def test_collector_one_read_separate_stderr_no_replay(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp); (base / 'input').write_text(json.dumps(BEFORE, separators=(',', ':')))
            script = '''
source "$SCRIPT_DIR/lib/fixture-bitlocker.sh"
qga_powershell() { printf '%s\\n' call >> "$ARTIFACT_DIR/calls"; cat "$ARTIFACT_DIR/input"; printf '%s\\n' 'public diagnostic stderr' >&2; }
bitlocker_collect_before_receipt F: ''' + GUID
            subprocess.run(['bash', '-c', script], check=True, env={'PATH': __import__('os').environ['PATH'], 'SCRIPT_DIR': str(ROOT / 'tests/e2e'), 'ARTIFACT_DIR': temp, 'RUN_ID': 'host-run'})
            self.assertEqual((base / 'calls').read_text(), 'call\n')
            self.assertIn('public diagnostic stderr', (base / 'bitlocker-before-receipt-read.stderr').read_text())
            self.assertEqual((base / 'bitlocker-before-receipts' / (GUID + '.json')).read_text(), (base / 'input').read_text())


if __name__ == '__main__': unittest.main()
