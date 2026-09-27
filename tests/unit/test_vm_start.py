import os
from pathlib import Path
import subprocess
import socket
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'tests/e2e/lib/vm-start.sh'

class VMStartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.calls = self.root / 'calls'
        self.runtime = self.root / 'runtime with spaces'
        self.runtime.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
exit 0
''')
        self.runtime.chmod(0o755)
        self.compose = self.root / 'compose with spaces'
        self.compose.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
printf '%s\\n' "$COMPOSE_OUTPUT"
exit "$COMPOSE_RC"
''')
        self.compose.chmod(0o755)
        self.sentinel = self.root / 'containers/networks/unrelated'
        self.sentinel.parent.mkdir(parents=True)
        self.sentinel.write_bytes(b'unrelated network ownership')

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, body, deadline=10, **env):
        script = f'''set -Eeuo pipefail
source '{MODULE}'
warn() {{ echo "$*" >&2; }}
fail() {{ echo "$*" >&2; }}
step() {{ :; }}
pass() {{ :; }}
wootc_vm_configure '{self.runtime}' owned-vm '{self.root}' '{self.root}/owned compose.yml' '{self.compose}' explicit-argument
''' + body
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                              env={**os.environ, 'CALLS':str(self.calls), 'COMPOSE_OUTPUT':'',
                                   'COMPOSE_RC':'0', 'XDG_RUNTIME_DIR':str(self.root), **env}, timeout=deadline)

    def test_source_has_no_operations(self):
        result = subprocess.run(['bash', '-c', f"source '{MODULE}'"], capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_actual_phantom_network_failure_preserves_unrelated_state(self):
        result = self.shell('port_free() { return 0; }; compose_up_windows',
                            COMPOSE_OUTPUT='podman0 already exists but is a Tun interface', COMPOSE_RC='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Infrastructure: conflicting host network state', result.stderr)
        self.assertEqual(self.sentinel.read_bytes(), b'unrelated network ownership')
        calls = self.calls.read_text().splitlines()
        self.assertEqual(sum('up -d windows' in c for c in calls), 1)
        self.assertFalse(any('network' in c for c in calls))
        self.assertTrue(all('owned-vm' in c for c in calls if c.startswith('rm ')))

    def test_port_exhaustion_refuses_before_remove_or_compose(self):
        result = self.shell('port_free() { return 1; }; compose_up_windows')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no free host port', result.stderr)
        self.assertEqual(self.sentinel.read_bytes(), b'unrelated network ownership')
        self.assertEqual(self.calls.read_text().splitlines(), ['image exists localhost/wootc-e2e-windows-ssh:latest'])

    def test_ambiguous_timeout_never_replays_start(self):
        result = self.shell('port_free() { return 0; }; compose_up_windows',
                            COMPOSE_OUTPUT='address already in use', COMPOSE_RC='124')
        self.assertEqual(result.returncode, 124)
        self.assertEqual(sum('up -d windows' in c for c in self.calls.read_text().splitlines()), 1)

    def test_explicit_compose_argv_and_owned_file_are_used(self):
        result = self.shell('port_free() { return 0; }; compose_up_windows')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'explicit-argument -f {self.root}/owned compose.yml up -d windows', self.calls.read_text())

    def test_actual_local_full_backlog_observation_is_bounded(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            clients = []
            try:
                for _ in range(2):
                    client = socket.create_connection(('127.0.0.1', port), timeout=1)
                    clients.append(client)
                result = self.shell('port_free "$TEST_PORT"', deadline=3, TEST_PORT=str(port))
                self.assertEqual(result.returncode, 2)
            finally:
                for client in clients:
                    client.close()

    def test_duplicate_free_overrides_are_reselected_to_distinct_ports(self):
        result = self.shell("""
port_free() { return 0; }
pick_free_ports
printf '%s\\n' "$WOOTC_E2E_NOVNC_PORT" "$WOOTC_E2E_RDP_PORT" "$WOOTC_E2E_VNC_PORT" "$WOOTC_E2E_SSH_PORT" "$WOOTC_E2E_CDP_PORT"
""", **{key:'23001' for key in ['WOOTC_E2E_NOVNC_PORT', 'WOOTC_E2E_RDP_PORT',
                               'WOOTC_E2E_VNC_PORT', 'WOOTC_E2E_SSH_PORT', 'WOOTC_E2E_CDP_PORT']})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(set(result.stdout.splitlines())), 5)
        self.assertFalse(self.calls.exists())

    def test_absolute_start_deadline_bounds_blocking_sample(self):
        self.runtime.write_text('#!/bin/bash\nsleep 25\n')
        result = self.shell('wootc_vm_wait_argv 1 started', deadline=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_settling_requires_current_successful_accelerated_sample(self):
        for status, expected in [('0', 0), ('7', 1)]:
            self.runtime.write_text('#!/bin/bash\necho qemu-system-x86_64 -accel=kvm -enable-kvm\nexit ' + status + '\n')
            result = self.shell("wootc_vm_wait_argv 1 accelerated 'qemu-system-x86_64 -accel=kvm'")
            self.assertEqual(result.returncode, expected)
            if expected:
                self.assertEqual(result.stdout, '')
            else:
                self.assertIn('-enable-kvm', result.stdout)

    def test_invalid_sampling_budget_refuses_before_runtime(self):
        for budget in ['0', '-1', 'bad', '']:
            result = self.shell('wootc_vm_wait_argv "$BUDGET" started', BUDGET=budget)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(self.calls.exists())

    def test_actual_blocking_runtime_is_bounded_before_start(self):
        self.runtime.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
if [ "$1" = container ]; then sleep 25; fi
exit 0
""")
        result = self.shell('port_free() { return 0; }; compose_up_windows', deadline=18)
        self.assertEqual(result.returncode, 124)
        self.assertNotIn('up -d windows', self.calls.read_text())
        self.assertEqual(self.sentinel.read_bytes(), b'unrelated network ownership')

    def test_failed_owned_remove_stops_before_start(self):
        self.runtime.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
if [ "$1" = rm ]; then exit 7; fi
exit 0
""")
        result = self.shell('port_free() { return 0; }; compose_up_windows')
        self.assertEqual(result.returncode, 7)
        self.assertNotIn('up -d windows', self.calls.read_text())
        self.assertEqual(self.sentinel.read_bytes(), b'unrelated network ownership')

    def test_failed_ps_cannot_supply_qemu_evidence(self):
        self.runtime.write_text('#!/bin/bash\necho qemu-system-x86_64 -enable-kvm\nexit 7\n')
        result = self.shell('qemu_argv_sample')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

if __name__ == '__main__':
    unittest.main()
