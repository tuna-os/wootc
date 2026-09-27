import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'tests/e2e/lib'


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.runtime = self.directory / 'runtime with spaces'
        self.runtime.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALLS"
count=0
[ ! -e "$COUNT" ] || count=$(cat "$COUNT")
count=$((count + 1)); printf '%s' "$count" > "$COUNT"
if [ "${BLOCK:-0}" = 1 ]; then sleep 3; fi
if [ "$count" = 1 ]; then exit "${FIRST_RC:-0}"; fi
exit "${LATER_RC:-0}"
''')
        self.runtime.chmod(0o755)
        self.env = {**os.environ, 'CALLS': str(self.directory / 'calls'),
                    'COUNT': str(self.directory / 'count')}

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, body, module=None, **environment):
        script = f'''set -Eeuo pipefail
source '{module or LIB / 'qga-transport.sh'}'
wootc_qga_configure '{self.runtime}' dedicated-vm /private/client.py
''' + body
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                              env={**self.env, **environment}, timeout=10)

    def count(self):
        return int((self.directory / 'count').read_text())

    def test_source_has_no_runtime_operation_and_unconfigured_call_refuses(self):
        result = subprocess.run(['bash', '-c', f'''set -u
source '{LIB}/qga-transport.sh'
source '{LIB}/host-runtime.sh'
source '{LIB}/retention.sh'
'''], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.directory / 'calls').exists())
        result = subprocess.run(['bash', '-c', f"source '{LIB}/qga-transport.sh'; qga_call ping"],
                                env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.directory / 'calls').exists())

    def test_side_effect_request_is_never_replayed_on_any_failure(self):
        for status in ['1', '42', '124']:
            (self.directory / 'count').unlink(missing_ok=True)
            result = self.shell('qga_call powershell "mutate BCD"', FIRST_RC=status)
            self.assertEqual(result.returncode, int(status), result.stderr)
            self.assertEqual(self.count(), 1)
        self.assertIn('exec dedicated-vm python3 /private/client.py powershell mutate BCD',
                      (self.directory / 'calls').read_text())

    def test_idempotent_retry_preserves_transport_and_guest_status(self):
        for status, later, expected, calls in [('42', '0', 0, 2), ('124', '0', 0, 2),
                                                ('42', '42', 42, 3), ('7', '0', 7, 1)]:
            (self.directory / 'count').unlink(missing_ok=True)
            result = self.shell('sleep() { :; }; qga_call_retry read /safe/log',
                                FIRST_RC=status, LATER_RC=later)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual(self.count(), calls)
        (self.directory / 'count').unlink()
        result = self.shell('WOOTC_QGA_CALL_TIMEOUT=5 qga_call_retry ping', FIRST_RC='42')
        self.assertEqual(result.returncode, 42)
        self.assertEqual(self.count(), 1)

    def test_zero_negative_or_malformed_budget_refuses_before_runtime(self):
        for operation in ['qga_call', 'qga_call_retry']:
            for budget in ['', '0', '-1', 'bad', '1.5']:
                result = self.shell(f'{operation} ping', WOOTC_QGA_CALL_TIMEOUT=budget)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse((self.directory / 'calls').exists())

    def test_actual_blocking_transport_is_bounded_without_replay(self):
        result = self.shell('WOOTC_QGA_CALL_TIMEOUT=1 qga_call powershell mutate', BLOCK='1')
        self.assertEqual(result.returncode, 124)
        self.assertEqual(self.count(), 1)

    def test_actual_blocking_reap_cannot_prevent_one_reconnect_cycle(self):
        self.runtime.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
case "$*" in
 *pkill*) sleep 20 ;;
 *reconnect*) printf 'mock channel answered\\n' ;;
esac
''')
        result = self.shell('''warn() { :; }; pass() { printf '%s\\n' "$*"; }
qga_reconnect_cycle
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('RECOVERED', result.stdout)
        lines = (self.directory / 'calls').read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn('pkill', lines[0])
        self.assertIn('reconnect', lines[1])
        # Removing the actual reap bound must make this same operation hang.
        mutant = self.directory / 'unbounded-reap.sh'
        source = (LIB / 'qga-transport.sh').read_text()
        bounded = 'timeout 5 "${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec'
        self.assertIn(bounded, source)
        mutant.write_text(source.replace(bounded, '"${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec', 1))
        with self.assertRaises(subprocess.TimeoutExpired):
            self.shell('warn() { :; }; pass() { :; }; qga_reconnect_cycle', module=mutant)

    def test_ping_is_not_identity_and_windows_clears_phase_in_actual_caller(self):
        result = self.shell(f'''source '{ROOT}/tests/e2e/steps.sh'
source '{ROOT}/tests/e2e/phase-ledger.sh'
qga_powershell() {{ printf '%s' unknown; }}
qga_call() {{ printf '%s' unknown; }}
qga_probe
if qga_windows_probe || qga_linux_probe; then exit 17; fi
WOOTC_CURRENT_PHASE_ID=fisherman; WOOTC_PHASE_CARRY=stale
qga_powershell() {{ printf '%s' Windows_NT; }}
qga_windows_probe
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY" ]
qga_call() {{ printf '%s' Linux; }}
qga_linux_probe
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_identity_refuses_failed_command_and_ambiguous_output(self):
        for probe, call, token in [('qga_windows_probe', 'qga_powershell', 'Windows_NT'),
                                    ('qga_linux_probe', 'qga_call', 'Linux')]:
            for output, status, expected in [(token + '\r\n', 0, 0), (token, 7, 1),
                                              ('not-' + token, 0, 1), (token + '\nextra', 0, 1),
                                              (token + ' ', 0, 1), ('', 0, 1)]:
                result = self.shell(f'''wootc_phase_boundary() {{ :; }}
{call}() {{ printf '%s' "$OBSERVATION"; return "$GUEST_STATUS"; }}
{probe}
''', OBSERVATION=output, GUEST_STATUS=str(status))
                self.assertEqual(result.returncode, expected, (probe, output, status, result.stderr))

    def test_actual_channel_loss_records_infrastructure_not_product_pass(self):
        ledger = self.directory / 'results.jsonl'
        legacy = self.directory / 'failures'
        marker = self.directory / '.passed'
        legacy.write_text('')
        result = self.shell(f'''source '{LIB}/results.sh'
source '{LIB}/result-runner.sh'
RUN_ID=adapter-run; WOOTC_RESULT_LEDGER='{ledger}'; WOOTC_FAILURE_LEDGER='{legacy}'
RED=; NC=; YELLOW=; GREEN=
note_flake() {{ printf '%s' "$1" > '{self.directory}/flake'; }}
wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
qga_channel_lost 'real consumer test'
wootc_result_finish "$WOOTC_RESULT_LEDGER" "$RUN_ID" "$WOOTC_FAILURE_LEDGER" '{marker}' image
''')
        self.assertNotEqual(result.returncode, 0)
        rows = [json.loads(line) for line in ledger.read_text().splitlines()]
        self.assertTrue(any(r['kind'] == 'failure' and r['domain'] == 'infrastructure' for r in rows))
        self.assertEqual(rows[-1]['productVerdict'], 'unknown')
        self.assertFalse(marker.exists())

    def preflight(self, disk_gib=114, memory_mib=8192, cached=False, reuse=False, floor=None):
        storage = self.directory / 'storage'
        storage.mkdir(exist_ok=True)
        if cached:
            (storage / 'windows.11.iso').touch()
        memory = self.directory / 'meminfo'
        memory.write_text(f'MemAvailable: {memory_mib * 1024} kB\n')
        explicit = '' if floor is None else f'WOOTC_E2E_MIN_FREE_GIB={floor}\n'
        body = f'''source '{LIB}/host-runtime.sh'
command() {{ if [ "$*" = '-v podman' ]; then return 0; fi; builtin command "$@"; }}
df() {{ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 0 0 {disk_gib * 1024 * 1024} 0%% /fixture\\n'; }}
infra_fail() {{ printf '%s\\n' "$*" >&2; }}
pass() {{ printf '%s\\n' "$*"; }}
info() {{ :; }}
deadline_in() {{ echo 1; }}
past_deadline() {{ return 0; }}
{explicit}host_preflight '{storage}' {'true' if reuse else 'false'} '{memory}' /dev/null /dev/null
'''
        return self.shell(body)

    def test_actual_preflight_capacity_observations_and_explicit_floor(self):
        self.assertEqual(self.preflight().returncode, 0)
        self.assertNotEqual(self.preflight(disk_gib=89).returncode, 0)
        self.assertEqual(self.preflight(disk_gib=75, cached=True).returncode, 0)
        self.assertEqual(self.preflight(disk_gib=55, reuse=True).returncode, 0)
        self.assertEqual(self.preflight(disk_gib=45, cached=True, floor=45).returncode, 0)
        self.assertNotEqual(self.preflight(disk_gib=44, floor=45).returncode, 0)
        result = self.preflight(memory_mib=4096)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('after 10 min', result.stderr)
        self.assertFalse((self.directory / 'calls').exists())

    def test_missing_actual_device_refuses_before_vm_commands(self):
        memory = self.directory / 'meminfo'
        memory.write_text('MemAvailable: 99999999 kB\n')
        result = self.shell(f'''source '{LIB}/host-runtime.sh'
command() {{ if [ "$*" = '-v podman' ]; then return 0; fi; builtin command "$@"; }}
infra_fail() {{ printf '%s' "$*" >&2; }}
host_preflight '{self.directory}' false '{memory}' '{self.directory}/missing-kvm' /dev/null
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('kvm', result.stderr)
        self.assertFalse((self.directory / 'calls').exists())

    def test_stop_policy_and_compose_fallback_use_only_configured_vm(self):
        bin_dir = self.directory / 'bin'
        bin_dir.mkdir()
        for name in ['podman', 'docker']:
            executable = bin_dir / name
            executable.write_text(f'''#!/bin/bash
printf '%s\\n' '{name}'" $*" >> "$CALLS"
if [ '{name}' = podman ] && [ "$1" = compose ]; then exit 8; fi
''')
            executable.chmod(0o755)
        body = f'''source '{LIB}/host-runtime.sh'
info() {{ :; }}
host_stop_vm '{self.runtime}' dedicated-vm '{self.directory}/compose.yml' true
[ ! -e "$CALLS" ]
host_stop_vm '{self.runtime}' dedicated-vm '{self.directory}/compose.yml' false
'''
        result = self.shell(body, PATH=str(bin_dir) + ':' + os.environ['PATH'])
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.directory / 'calls').read_text().splitlines()
        self.assertEqual(lines[0], 'exec dedicated-vm pkill -9 -f process=windows')
        self.assertIn('podman compose -f ', lines[1])
        self.assertIn('docker compose -f ', lines[2])
        self.assertEqual(lines[3], 'podman rm -f dedicated-vm')

    def test_iso_cache_preserves_source_and_handles_failed_copy(self):
        storage = self.directory / 'storage'
        cache = self.directory / 'cache'
        storage.mkdir()
        original = storage / 'windows.11.iso'
        original.write_bytes(b'controlled ISO bytes')
        target = cache / 'windows-11.iso'
        body = f'''source '{LIB}/host-runtime.sh'
info() {{ :; }}
cache_downloaded_iso '{cache}' '{target}' '{storage}'
'''
        result = self.shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), original.read_bytes())
        target.unlink()
        result = self.shell('cp() { return 19; }; ' + body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(target.exists())
        self.assertFalse(Path(str(target) + '.part').exists())
        self.assertEqual(original.read_bytes(), b'controlled ISO bytes')

    def test_windows_identity_probe_validates_and_caps_caller_budget(self):
        body = """
wootc_phase_boundary() { :; }
qga_powershell() { printf '%s' "$WOOTC_QGA_CALL_TIMEOUT" > "$COUNT"; printf Windows_NT; }
qga_windows_probe "$PROBE_BUDGET"
"""
        for budget in ['', '0', '-1', 'bad']:
            result = self.shell(body, PROBE_BUDGET=budget)
            self.assertEqual(result.returncode, 2)
            self.assertFalse((self.directory / 'count').exists())
        for budget, expected in [('1', 1), ('20', 5)]:
            result = self.shell(body, PROBE_BUDGET=budget)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.count(), expected)

    def test_actual_return_observer_refuses_failed_linux_token(self):
        for guest_status, expected in [('0', 'linux'), ('7', 'unknown')]:
            result = self.shell("""
qga_probe() { return 0; }
qga_windows_probe() { return 1; }
qga_call() { printf 'Linux\\r\\n'; return "$GUEST_STATUS"; }
WOOTC_E2E_P2_REBOOT_TRIES=1
WOOTC_E2E_P2_REBOOT_POLL_S=0
p2_reboot_observe
""", GUEST_STATUS=guest_status)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_actual_entrypoint_retention_failure_stops_before_runtime(self):
        tree = self.directory / 'repo/tests/e2e'
        tree.mkdir(parents=True)
        for name in ['run-e2e.sh', 'steps.sh', 'phase-ledger.sh']:
            shutil.copyfile(ROOT / 'tests/e2e' / name, tree / name)
        shutil.copytree(LIB, tree / 'lib', ignore=shutil.ignore_patterns('__pycache__'))
        (tree / 'wootc-files').mkdir()
        (tree / 'wootc-files/wootc.exe').write_bytes(b'controlled CLI fixture')
        old = tree / 'storage/artifacts/old-run'
        old.mkdir(parents=True)
        (old / 'serial.log').write_text('retained diagnostic evidence')
        os.utime(old, (1, 1))
        bin_dir = self.directory / 'bin'
        bin_dir.mkdir()
        cp = bin_dir / 'cp'
        cp.write_text('''#!/bin/bash
case "${*: -1}" in */.evidence/*) exit 9;; esac
exec /bin/cp "$@"
''')
        cp.chmod(0o755)
        podman = bin_dir / 'podman'
        podman.write_text('#!/bin/bash\necho runtime >> "$CALLS"\n')
        podman.chmod(0o755)
        result = subprocess.run(['bash', str(tree / 'run-e2e.sh')], capture_output=True, text=True,
                                env={**self.env, 'TMPDIR': str(self.directory),
                                     'WOOTC_E2E_KEEP_RUNS': '1', 'WOOTC_E2E_RUN_ID': 'retention-run',
                                     'PATH': str(bin_dir) + ':' + os.environ['PATH']}, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Artifact retention failed', result.stderr)
        self.assertEqual((old / 'serial.log').read_text(), 'retained diagnostic evidence')
        self.assertFalse((self.directory / 'calls').exists())
        evidence = tree / 'storage/artifacts/retention-run/results.jsonl'
        rows = [json.loads(line) for line in evidence.read_text().splitlines()]
        self.assertTrue(any(r['kind'] == 'failure' and r['domain'] == 'infrastructure' for r in rows))
        self.assertEqual(rows[-1]['productVerdict'], 'unknown')


if __name__ == '__main__':
    unittest.main()
