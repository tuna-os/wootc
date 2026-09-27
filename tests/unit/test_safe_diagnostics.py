#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('safe_log', ROOT / 'tests/e2e/safe-log.py')
SAFE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SAFE)
# Synthetic format example; never derived from an actual protector.
SYNTHETIC = '-'.join(['000000'] * 8)


class SafeDiagnosticsTests(unittest.TestCase):
    def test_actual_mixed_transcript_and_stream_refuse_password(self):
        raw = b'UTF8 OEM header\n' + ('native recovery ' + SYNTHETIC + '\r\nnext line\r\n').encode('utf-16le')
        result = subprocess.run(['python3', str(ROOT / 'tests/e2e/safe-log.py')], input=raw, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = result.stdout.decode()
        self.assertNotIn(SYNTHETIC, text)
        self.assertNotIn('\x00', text)
        self.assertIn('UTF8 OEM header', text)
        self.assertIn('native recovery [REDACTED recovery password]', text)
        self.assertIn('next line', text)

    def test_nul_interleaving_and_flat_password_are_removed(self):
        for raw in [SYNTHETIC.encode(), SYNTHETIC.encode('utf-16le'), SYNTHETIC.encode('utf-16be'), b'X' + (SYNTHETIC + '\r\n').encode('utf-16le'), ('000000' * 8).encode()]:
            self.assertIn('[REDACTED recovery password]', SAFE.normalize(raw))
        self.assertEqual(SAFE.normalize('ProtectionOff café\r\n'.encode('utf-16le')), 'ProtectionOff café\n')

    def test_actual_missing_log_reader_does_not_create_oem_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            body = f'''set -euo pipefail
SCRIPT_DIR='{ROOT}/tests/e2e'
source "$SCRIPT_DIR/lib/diagnostics.sh"
qga_read() {{ printf 'missing file native %s\\n' '{SYNTHETIC}' >&2; return 1; }}
OEM_FAILURE=$(qga_safe_log 'C:\\OEM\\e2e-setup-failed.txt' 2>/dev/null || true)
[ -z "$OEM_FAILURE" ]
qga_safe_log missing > '{directory}/stdout' 2> '{directory}/stderr' || true
'''
            result = subprocess.run(['bash', '-c', body], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(directory) / 'stdout').read_text(), '')
            text = (Path(directory) / 'stderr').read_text()
            self.assertNotIn(SYNTHETIC, text)
            self.assertIn('missing file', text)

    def test_artifact_tree_preserves_binary_and_refuses_link(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            (p / 'oem.log').write_bytes(('native ' + SYNTHETIC).encode('utf-16le'))
            (p / 'frame.png').write_bytes(b'\x89PNG\r\n\x1a\n\x00binary unchanged')
            (p / 'transcript-without-suffix').write_bytes(b'X' + SYNTHETIC.encode('utf-16le'))
            (p / 'native-output.bin').write_bytes(SYNTHETIC.encode('utf-16be'))
            (p / 'error.json').write_text(json.dumps({'message': SYNTHETIC}))
            result = subprocess.run(['python3', str(ROOT / 'tests/e2e/safe-log.py'), '--tree', directory])
            self.assertEqual(result.returncode, 0)
            self.assertNotIn(SYNTHETIC, (p / 'oem.log').read_text())
            self.assertNotIn(SYNTHETIC, (p / 'transcript-without-suffix').read_text())
            self.assertNotIn(SYNTHETIC, (p / 'error.json').read_text())
            self.assertNotIn(SYNTHETIC, (p / 'native-output.bin').read_text())
            self.assertEqual((p / 'frame.png').read_bytes(), b'\x89PNG\r\n\x1a\n\x00binary unchanged')
            (p / 'unsafe.log').symlink_to(p / 'oem.log')
            result = subprocess.run(['python3', str(ROOT / 'tests/e2e/safe-log.py'), '--tree', directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_upload_gate_refuses_a_failed_actual_sanitizer(self):
        workflow = (ROOT / '.github/workflows/e2e-hosted.yml').read_text()
        sanitizer = workflow.index('id: safe_logs')
        upload = workflow.index('uses: actions/upload-artifact', sanitizer)
        self.assertIn("if: always() && steps.safe_logs.outcome == 'success'", workflow[upload:upload + 200])
        self.assertIn('python3 tests/e2e/safe-log.py --tree /tmp/evidence', workflow[sanitizer:upload])
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            (p / 'linked.log').symlink_to(p / 'target')
            result = subprocess.run(['python3', str(ROOT / 'tests/e2e/safe-log.py'), '--tree', directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def shell(self, identity=True, drive='F'):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            raw = p / 'raw'
            raw.write_bytes(('native ' + SYNTHETIC).encode('utf-16le'))
            body = f'''set -euo pipefail
SCRIPT_DIR='{ROOT}/tests/e2e'; ARTIFACT_DIR='{p}'; WOOTC_GUEST_ROOT='C:'
source "$SCRIPT_DIR/lib/diagnostics.sh"
qga_windows_probe() {{ {'true' if identity else 'false'}; }}
qga_powershell() {{
  printf '%s\\n' "$1" >> "$ARTIFACT_DIR/calls"
  if [[ "$1" == *Get-PSDrive* ]]; then printf '%s\\n' '{drive}';
  else printf '%s\\n' '{{"protectionStatus":"Off","protectors":[{{"type":"RecoveryPassword","id":"synthetic-id"}}]}}'; fi
}}
qga_read() {{ printf '%s\\n' "$1" >> "$ARTIFACT_DIR/read-paths"; cat '{raw}'; }}
if collect_windows_diagnostic_metadata; then
 qga_safe_log "$WOOTC_GUEST_ROOT\\wootc\\logs\\deployer.log" > "$ARTIFACT_DIR/deployer.log"
fi
'''
            result = subprocess.run(['bash', '-c', body], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return {f.name: f.read_text(errors='replace') for f in p.iterdir() if f.name != 'raw'}

    def test_actual_collector_discovers_f_and_selects_only_safe_metadata(self):
        files = self.shell()
        self.assertEqual(files['storage-root.txt'].strip(), 'F:')
        self.assertEqual(files['read-paths'].strip(), 'F:\\wootc\\logs\\deployer.log')
        self.assertNotIn(SYNTHETIC, files['deployer.log'])
        commands = files['calls']
        self.assertNotIn('.RecoveryPassword', commands)
        self.assertIn('KeyProtectorType', commands)
        self.assertIn('KeyProtectorId', commands)
        self.assertEqual(json.loads(files['bitlocker-metadata.json'])['protectionStatus'], 'Off')

    def test_wrong_identity_or_ambiguous_drives_cannot_use_cached_c(self):
        wrong = self.shell(identity=False)
        self.assertNotIn('calls', wrong)
        self.assertNotIn('read-paths', wrong)
        ambiguous = self.shell(drive='CF')
        self.assertNotIn('bitlocker-metadata.json', ambiguous)
        self.assertNotIn('read-paths', ambiguous)
        self.assertIn('ambiguous', ambiguous['storage-root.txt'])


if __name__ == '__main__':
    unittest.main()
