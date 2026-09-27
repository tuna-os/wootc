"""Real stdlib QGA client over a private fixture socket; OS/signatures are fixtures."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import socket
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/orchestrate.py'))
Transport, run, check_vm = (MODULE[n] for n in ('Transport', 'run', 'check_vm'))


class AgentFixture:
    def __init__(self, path, args):
        self.path, self.args = path, args
        self.generation = 0
        self.windows = False
        self.bootnext = False
        self.stale_windows = False
        self.wrong_vm = False
        self.helper = b'explicit helper fixture'
        self.helper_delay = 0
        self.no_progress = False
        self.read_slow = False
        self.byte_drip = False
        self.executions = 0
        self.output = b''
        self.stop = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path)); self.server.listen(); self.server.settimeout(.1)
        self.thread = threading.Thread(target=self.serve, daemon=True); self.thread.start()

    def close(self):
        self.stop.set(); self.thread.join(2); self.server.close()

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            with connection:
                stream = connection.makefile('rwb')
                while True:
                    line = stream.readline()
                    if not line:
                        break
                    request = json.loads(line.lstrip(b'\xff'))
                    command, args = request['execute'], request.get('arguments', {})
                    prefix = b''
                    if command == 'guest-sync-delimited':
                        value = args['id']; prefix = b'\xff'
                    elif command == 'guest-file-open':
                        value = 1
                    elif command == 'guest-file-read':
                        time.sleep(self.helper_delay)
                        value = {'count': len(self.helper), 'buf-b64': base64.b64encode(self.helper).decode(), 'eof': True}
                        if self.no_progress:
                            value = {'count': 0, 'buf-b64': '', 'eof': False}
                        if self.read_slow:
                            value = {'count': 1, 'buf-b64': base64.b64encode(b'x').decode(), 'eof': False}
                    elif command == 'guest-file-close':
                        value = {}
                    elif command == 'guest-exec':
                        self.executions += 1
                        path, arguments = args['path'], args['arg']
                        self.output = b''
                        if path == '/usr/bin/python3' and 'capture.py' in arguments[0]:
                            nonce = arguments[arguments.index('--transport-nonce')+1]
                            data = copy.deepcopy(self.args[1+self.generation])
                            data['transportNonce'] = nonce
                            if self.wrong_vm:
                                data['vmUuid'] = 'foreign'
                            self.output = json.dumps(data).encode()
                        elif path == 'powershell.exe':
                            script = base64.b64decode(arguments[-1]).decode('utf-16le')
                            self.last_windows_command = script
                            data = copy.deepcopy(self.args[-1])
                            data['transportNonce'] = 'cached' if self.stale_windows else re.search("-TransportNonce '([^']+)'", script)[1]
                            self.output = json.dumps(data).encode()
                        elif path == '/usr/bin/efibootmgr':
                            self.bootnext = True
                        elif path == '/usr/bin/systemctl' and arguments == ['reboot']:
                            if self.bootnext:
                                self.generation += 1; self.bootnext = False
                            else:
                                self.windows = True
                        value = {'pid': self.executions}
                    elif command == 'guest-exec-status':
                        value = {'exited': True, 'exitcode': 0, 'out-data': base64.b64encode(self.output).decode()}
                    else:
                        raise AssertionError(command)
                    try:
                        payload = prefix+json.dumps({'return': value}).encode()+b'\n'
                        if self.byte_drip:
                            for byte in payload:
                                if self.stop.is_set():
                                    break
                                stream.write(bytes([byte])); stream.flush(); time.sleep(.005)
                        else:
                            stream.write(payload); stream.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        break


class OrchestratorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.folder = Path(self.temporary.name)
        fixture = runpy.run_path(str(ROOT/'tests/unit/test_wootc_esp_acceptance.py'))['AcceptanceTests'](); fixture.setUp(); self.args = fixture.args
        self.plan = self.args[0]
        self.plan.update(windowsVolume='F:', espMount='/run/wootc-qa-esp',
                         helperHashesLinux={'/helper': hashlib.sha256(b'explicit helper fixture').hexdigest()},
                         helperHashesWindows={'F:\\wootc\\qa\\capture-windows.ps1': hashlib.sha256(b'explicit helper fixture').hexdigest()})
        self.record = {'scratchId': self.plan['scratchId'], 'vmUuid': self.plan['vmUuid'], 'overlay': str(self.folder/'disk.qcow2')}
        self.agent = AgentFixture(self.folder/'qga.sock', self.args)
        self.transport = Transport(self.folder, self.record, identity_check=lambda *_: self.folder/'qga.sock', helper_policy=lambda kind, plan: plan['helperHashesLinux' if kind == 'linux' else 'helperHashesWindows'])

    def tearDown(self):
        self.transport.close(); self.agent.close(); self.temporary.cleanup()

    def test_actual_qga_client_execution_order_with_fixture_os(self):
        result = run(self.transport, self.plan)
        self.assertTrue(result['chronologyVerified'])
        self.assertFalse(result['firmwareAcceptance'])
        self.assertFalse(result['classicOsBootAcceptance'])
        self.assertEqual([e['os'] for e in self.transport.events if e['kind'] == 'capture-verified'], ['linux', 'linux', 'linux', 'windows'])
        self.assertIn("& 'F:\\wootc\\qa\\capture-windows.ps1'", self.agent.last_windows_command)
        self.assertTrue(self.transport.ledger.is_file())
        self.assertEqual(len(list(self.folder.glob('*-result.json'))), 1)

    def test_stale_windows_response_never_verifies_chronology(self):
        self.agent.stale_windows = True
        with self.assertRaisesRegex(ValueError, 'stale capture'):
            self.transport.capture('windows', self.plan, self.args[3])
        self.assertFalse(any(e['kind'] == 'capture-verified' for e in self.transport.events))

    def test_wrong_vm_capture_is_refused(self):
        self.agent.wrong_vm = True
        with self.assertRaisesRegex(ValueError, 'wrong actual VM'):
            self.transport.capture('linux', self.plan)

    def test_changed_guest_helper_refuses_before_execution(self):
        self.agent.helper = b'mutated helper'
        with self.assertRaisesRegex(ValueError, 'helper hash differs'):
            self.transport.capture('linux', self.plan)
        self.assertEqual(self.agent.executions, 0)

    def test_wait_budget_bounds_blocking_helper_read(self):
        self.agent.helper_delay = .25
        start = time.monotonic()
        with self.assertRaisesRegex(ValueError, 'deadline exceeded'):
            self.transport.wait_capture('linux', self.plan, self.args[1], seconds=.08)
        self.assertLess(time.monotonic()-start, .2)
        self.assertEqual(self.agent.executions, 0)

    def test_wait_budget_bounds_slow_stream_of_helper_reads(self):
        self.agent.helper_delay = .03; self.agent.read_slow = True
        start = time.monotonic()
        with self.assertRaisesRegex(ValueError, 'deadline exceeded'):
            self.transport.wait_capture('linux', self.plan, self.args[1], seconds=.08)
        self.assertLess(time.monotonic()-start, .2)
        self.assertEqual(self.agent.executions, 0)

    def test_wait_budget_bounds_continuous_sync_byte_drip(self):
        self.agent.byte_drip = True
        start = time.monotonic()
        with self.assertRaisesRegex(ValueError, 'deadline exceeded'):
            self.transport.wait_capture('linux', self.plan, self.args[1], seconds=.08)
        self.assertLess(time.monotonic()-start, .2)

    def test_no_progress_helper_read_refuses(self):
        self.agent.no_progress = True
        with self.assertRaisesRegex(ValueError, 'no progress'):
            self.transport.capture('linux', self.plan)
        self.assertEqual(self.agent.executions, 0)

    def test_incomplete_production_helper_closure_refuses(self):
        production = Transport(self.folder, self.record, identity_check=lambda *_: self.folder/'qga.sock')
        try:
            with self.assertRaisesRegex(ValueError, 'closure is incomplete'):
                production.capture('linux', self.plan)
            self.assertEqual(self.agent.executions, 0)
        finally:
            production.close()

    def test_owned_socket_does_not_authorize_wrong_host_process(self):
        (self.folder/'disk.qcow2').write_bytes(b'fixture')
        (self.folder/'qemu.pid').write_text(str(os.getpid()))
        with self.assertRaisesRegex(ValueError, 'not one owned QEMU'):
            check_vm(self.folder, self.record)


if __name__ == '__main__':
    unittest.main()
