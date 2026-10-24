#!/usr/bin/env python3
"""Exercise the GUI acceptance gate with observable failures, not string guards."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'e2e' / 'gui-document-proof.py'
spec = importlib.util.spec_from_file_location('gui_document_proof', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SEED, MARKER = 'wootc-e2e-userdata run1', 'wootc-e2e-gui-edit-run1'


class FakeDesktop:
    def __init__(self, defect=None):
        self.defect, self.text, self.buffer = defect, SEED + '\n', ''
        self.open, self.focused, self.opens = False, False, 0
        self.installed, self.installs = False, 0
        self.events = []

    def observe(self, action):
        self.events.append(action)
        if action == 'tooling':
            native = self.defect not in ('tooling-editor', 'install', 'install-fails', 'install-lies')
            return {'nativeEditor': native, 'installedFlatpaks': ['org.gnome.TextEditor'] if self.installed else [],
                    'libatspi': self.defect != 'tooling-accessibility'}
        if action == 'provision':
            self.installs += 1
            return {'started': True}
        if action == 'provisioned':
            # 'install-lies' reports success while flatpak still lists nothing.
            self.installed = self.defect == 'install'
            return {'finished': True, 'installed': self.installed or self.defect == 'install-lies',
                    'unit': {'Result': 'success' if self.defect != 'install-fails' else 'exit-code'}}
        if action == 'prepare':
            return {'prepared': True}
        if action == 'desktop':
            return {'Active': 'no' if self.defect == 'desktop' else 'yes', 'Type': 'wayland',
                    'Name': 'wootc', 'uid': 1000}
        if action == 'disk':
            return {'text': self.text, 'sha256': hashlib.sha256(self.text.encode()).hexdigest(), 'uid': 1000}
        if action == 'launch':
            if self.open:
                raise RuntimeError('Previous editor never closed')
            if self.defect == 'editor':
                raise RuntimeError('No installed editor')
            self.open, self.focused = True, False
            self.opens += 1
            self.buffer = SEED + '\n' if self.defect == 'reopen' and self.opens > 1 else self.text
            return {'launched': ['gnome-text-editor']}
        if action in ('probe', 'focus'):
            if self.defect == 'accessibility':
                raise RuntimeError('No accessibility bus')
            if not self.open:
                raise RuntimeError('No editor buffer')
            if action == 'focus':
                self.focused = True
            return {'showing': True, 'editable': self.defect != 'readonly', 'focused': self.focused,
                    'buffer': self.buffer, 'process': {'pid': 100 + self.opens, 'startTicks': str(100 + self.opens),
                                                     'uid': 0 if self.defect == 'root' else 1000,
                                                     'exe': '/usr/bin/gnome-text-editor', 'command': '/usr/bin/gnome-text-editor'}}
        if action == 'closed':
            return {'processes': [100 + self.opens] if self.open else []}
        raise AssertionError(action)

    def keys(self, keys):
        self.events.append(('keys', keys))
        if not self.focused:
            raise RuntimeError('Keys sent to unfocused window')
        for key in keys:
            if key == 'ctrl-end':
                continue
            if key == 'ctrl-s':
                if self.defect != 'save':
                    self.text = self.buffer
            elif key == 'ctrl-q':
                if self.defect != 'close':
                    self.open = False
            elif key == 'ret':
                self.buffer += '\n'
            else:
                self.buffer += '-' if key == 'minus' else key
        if self.defect == 'premature-write' and 'ctrl-end' in keys:
            self.text = self.buffer

    def screenshot(self, stage):
        self.events.append(('screenshot', stage))


class GateTests(unittest.TestCase):
    def exercise(self, desktop, phase='edit'):
        with tempfile.TemporaryDirectory() as directory:
            now = [0]
            def pause(seconds):
                now[0] += 20
            proof = module.Proof(desktop, SEED, MARKER, Path(directory) / 'evidence.jsonl', pause, lambda: now[0])
            result = proof.run(phase)
            evidence = (Path(directory) / 'evidence.jsonl').read_text()
            return result, evidence

    def test_gui_save_close_reopen_and_restart(self):
        desktop = FakeDesktop()
        digest, evidence = self.exercise(desktop)
        self.assertIn('saved-file-reopened', evidence)
        self.assertEqual(desktop.opens, 2)
        self.assertFalse(desktop.open)
        restarted = FakeDesktop()
        restarted.text = desktop.text
        restart_digest, restart_evidence = self.exercise(restarted, 'reopen')
        self.assertEqual(digest, restart_digest)
        self.assertIn('restart-file-reopened', restart_evidence)
        self.assertFalse(any(isinstance(event, tuple) and event[0] == 'keys' and 'ctrl-s' in event[1]
                             for event in restarted.events))

    def test_missing_editor_is_installed_then_held_to_every_observation(self):
        desktop = FakeDesktop('install')
        with tempfile.TemporaryDirectory() as directory:
            proof = module.Proof(desktop, SEED, MARKER, Path(directory) / 'evidence.jsonl', lambda s: None, lambda: 0)
            proof.run('edit')
            evidence = (Path(directory) / 'evidence.jsonl').read_text()
        self.assertEqual(proof.editor_source, 'fixture-flatpak')
        self.assertEqual(desktop.installs, 1)
        self.assertIn('fixture-editor-finished', evidence)
        self.assertIn('saved-file-reopened', evidence)

    def test_failed_or_unconfirmed_install_fails_the_gate(self):
        for defect in ('install-fails', 'install-lies', 'tooling-editor'):
            with self.subTest(defect=defect), self.assertRaisesRegex(RuntimeError, 'could not install'):
                self.exercise(FakeDesktop(defect))

    def test_restart_never_reinstalls_a_lost_editor(self):
        desktop = FakeDesktop('install')
        desktop.text += MARKER
        with self.assertRaisesRegex(RuntimeError, 'lacks an installed GNOME Text Editor'):
            self.exercise(desktop, 'reopen')
        self.assertEqual(desktop.installs, 0)

    def test_disabled_save_fails_even_when_buffer_contains_edit(self):
        with self.assertRaisesRegex(RuntimeError, 'saved-file'):
            self.exercise(FakeDesktop('save'))

    def test_missing_or_readonly_gui_cannot_pass(self):
        for defect in ('tooling-editor', 'tooling-accessibility', 'desktop', 'editor', 'accessibility', 'readonly', 'root'):
            with self.subTest(defect=defect), self.assertRaises(RuntimeError):
                self.exercise(FakeDesktop(defect))

    def test_close_and_reopen_are_observed(self):
        for defect in ('close', 'reopen'):
            with self.subTest(defect=defect), self.assertRaises(RuntimeError):
                self.exercise(FakeDesktop(defect))

    def test_shell_or_autosave_change_before_save_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'before the GUI Save'):
            self.exercise(FakeDesktop('premature-write'))

    def test_stale_marker_does_not_prove_current_save(self):
        desktop = FakeDesktop()
        desktop.text += MARKER
        with self.assertRaisesRegex(RuntimeError, 'stale GUI edit'):
            self.exercise(desktop)

    def test_restart_cannot_pass_when_saved_edit_is_missing(self):
        with self.assertRaisesRegex(RuntimeError, 'restart-file-reopened'):
            self.exercise(FakeDesktop(), 'reopen')


class TransportTests(unittest.TestCase):
    def test_hmp_key_input_ends_in_newline_and_monitor_error_is_fatal(self):
        class Monitor:
            def __init__(self, response):
                self.response, self.sent, self.reads = response, [], 0
            def settimeout(self, seconds):
                self.timeout = seconds
            def connect(self, path):
                self.path = path
            def recv(self, count):
                self.reads += 1
                return b"(qemu)" if self.reads == 1 else self.response
            def sendall(self, data):
                self.sent.append(data)
            def close(self):
                pass
        transport = module.Transport('runtime', 'fixture', 'document', SEED, Path('/tmp'))
        for failed in (False, True):
            monitor = Monitor(b'Error: unsupported command' if failed else b'(qemu)')
            def command(args, seconds=45):
                with patch('socket.socket', return_value=monitor), patch('time.sleep'), patch('sys.argv', ['hmp', args[6]]):
                    exec(compile(args[5], 'hmp-proof', 'exec'), {})
            transport.command = command
            if failed:
                with self.assertRaisesRegex(RuntimeError, 'unsupported'):
                    transport.keys(['ctrl-s'])
            else:
                transport.keys(['ctrl-s'])
            self.assertEqual(monitor.sent, [b'sendkey ctrl-s 40\n'])
            self.assertEqual(monitor.path, '/run/shm/monitor.sock')

    def test_positive_linux_identity_is_required(self):
        transport = module.Transport('runtime', 'fixture', 'document', SEED, Path('/tmp'))
        transport.command = lambda args, seconds=45: ''
        calls = []
        def qga(*args):
            calls.append(args)
            return 'Windows_NT' if '/usr/bin/uname' in args else ''
        transport.qga = qga
        with self.assertRaisesRegex(RuntimeError, 'positive Linux'):
            transport.stage()
        self.assertEqual(calls, [('exec', '/usr/bin/uname', '-s')])


class GuestIdentityTests(unittest.TestCase):
    def test_flatpak_proxy_requires_the_same_editor_sandbox_and_app_id(self):
        guest_spec = importlib.util.spec_from_file_location('gui_document_guest', SOURCE.with_name('gui-document-guest.py'))
        guest = importlib.util.module_from_spec(guest_spec)
        guest_spec.loader.exec_module(guest)
        guest.unix_socket_peers = lambda a, b: []
        peer = {'pid': 40, 'startTicks': '40', 'uid': 1000, 'exe': '/usr/bin/xdg-dbus-proxy', 'command': 'proxy'}
        editor = {'pid': 60, 'startTicks': '60', 'uid': 1000, 'exe': '/app/bin/gnome-text-editor', 'command': 'gnome-text-editor'}
        wrapper = {'pid': 20, 'startTicks': '20', 'uid': 1000, 'exe': '/usr/bin/bwrap'}
        unrelated = {'pid': 21, 'startTicks': '21', 'uid': 1000, 'exe': '/usr/bin/bwrap'}
        with patch.object(guest, 'process', side_effect=lambda pid: peer if pid == 40 else editor), patch.object(guest, 'editor_processes', return_value=[editor]):
            with patch.object(guest, 'flatpak_app', return_value='org.gnome.TextEditor'):
                with patch.object(guest, 'ancestors', side_effect=lambda pid: [peer, wrapper] if pid == 40 else [editor, wrapper]):
                    self.assertEqual(guest.editor_identity(40, 1000)['pid'], 60)
                with patch.object(guest, 'ancestors', side_effect=lambda pid: [peer, wrapper] if pid == 40 else [editor, unrelated]):
                    self.assertIsNone(guest.editor_identity(40, 1000))
            with patch.object(guest, 'flatpak_app', return_value='org.example.Other'), patch.object(guest, 'ancestors', return_value=[wrapper]):
                self.assertIsNone(guest.editor_identity(40, 1000))
            with patch.object(guest, 'flatpak_app', return_value='org.gnome.TextEditor'):
                with patch.object(guest, 'editor_processes', return_value=[editor, {**editor, 'pid': 61}]), patch.object(guest, 'ancestors', return_value=[wrapper]):
                    self.assertIsNone(guest.editor_identity(40, 1000))
                with patch.object(guest, 'ancestors', side_effect=lambda pid: [wrapper] if pid == 40 else [{**wrapper, 'startTicks': 'reused'}]):
                    self.assertIsNone(guest.editor_identity(40, 1000))
            self.assertIsNone(guest.editor_identity(40, 0))
        native = {**editor, 'exe': '/usr/bin/gnome-text-editor'}
        with patch.object(guest, 'process', return_value=native):
            self.assertEqual(guest.editor_identity(60, 1000), native)
        with patch.object(guest, 'process', side_effect=[native, {**native, 'startTicks': 'reused'}]):
            with self.assertRaisesRegex(RuntimeError, 'changed during'):
                guest.editor_identity(60, 1000)
        with patch.object(guest, 'process', side_effect=[native, FileNotFoundError('exited')]):
            with self.assertRaises(FileNotFoundError):
                guest.editor_identity(60, 1000)

    def test_unreadable_ancestor_keeps_an_exact_opaque_identity(self):
        guest_spec = importlib.util.spec_from_file_location('gui_document_guest', SOURCE.with_name('gui-document-guest.py'))
        guest = importlib.util.module_from_spec(guest_spec)
        guest_spec.loader.exec_module(guest)
        guest.unix_socket_peers = lambda a, b: []
        proxy = {'pid': 40, 'startTicks': '40', 'uid': 1000, 'exe': '/usr/bin/xdg-dbus-proxy', 'command': 'proxy'}
        inner = {'pid': 30, 'startTicks': '30', 'uid': 1000, 'exe': '/usr/bin/bwrap', 'command': 'bwrap'}
        outer = {'pid': 20, 'startTicks': '20', 'uid': 1000, 'exe': None, 'name': 'bwrap'}
        editor = {'pid': 60, 'startTicks': '60', 'uid': 1000, 'exe': '/app/bin/gnome-text-editor', 'command': 'gnome-text-editor'}
        parents = {40: 30, 30: 20, 20: 1, 60: 50, 50: 20}
        readable = {40: proxy, 30: inner, 60: editor, 50: {**inner, 'pid': 50, 'startTicks': '50'}}
        def fake_process(pid):
            if pid not in readable:
                raise PermissionError(13, 'Permission denied', f'/proc/{pid}/exe')
            return readable[pid]
        status = lambda self: f"PPid:\t{parents[int(self.parts[2])]}\n"
        with patch.object(guest, 'process', side_effect=fake_process), \
                patch.object(guest, 'opaque_process', side_effect=lambda pid: outer if pid == 20 else None), \
                patch.object(guest.Path, 'read_text', autospec=True, side_effect=status):
            self.assertEqual([p['pid'] for p in guest.ancestors(40)], [40, 30, 20])
            with patch.object(guest, 'editor_processes', return_value=[editor]), \
                    patch.object(guest, 'flatpak_app', return_value='org.gnome.TextEditor'):
                match = guest.editor_identity(40, 1000)
                self.assertEqual(match['pid'], 60)
                self.assertIn((20, '20'), match['sharedWrapperIdentities'])
            reused = {**outer, 'startTicks': 'reused'}
            with patch.object(guest, 'opaque_process', side_effect=[outer, reused]):
                with self.assertRaisesRegex(RuntimeError, 'changed during'):
                    guest.ancestors(30)
        with patch.object(guest, 'process', side_effect=PermissionError(13, 'Permission denied')):
            with self.assertRaises(PermissionError):
                guest.ancestors(40)

    def test_proxy_bound_by_an_established_socket_pair(self):
        guest_spec = importlib.util.spec_from_file_location('gui_document_guest', SOURCE.with_name('gui-document-guest.py'))
        guest = importlib.util.module_from_spec(guest_spec)
        guest_spec.loader.exec_module(guest)
        table = "\n".join([
            'u_str ESTAB 0 0 * 9001 * 9002 users:(("gnome-text-edit",pid=60,fd=7))',
            'u_str ESTAB 0 0 /run/user/1000/.dbus-proxy/a11y-bus-proxy-X 9002 * 9001 users:(("xdg-dbus-proxy",pid=40,fd=12))',
            'u_str ESTAB 0 0 * 9003 * 9004 users:(("gnome-shell",pid=70,fd=3))',
            'u_str ESTAB 0 0 * 9004 * 9003 users:(("xdg-dbus-proxy",pid=40,fd=13))',
            'u_str LISTEN 0 0 /run/user/1000/bus 8000 * 0 users:(("dbus-broker",pid=9,fd=3))'])
        with patch.object(guest, 'run', return_value=table):
            self.assertEqual(guest.unix_socket_peers(60, 40), [(9001, 9002)])
            self.assertEqual(guest.unix_socket_peers(70, 40), [(9003, 9004)])
            self.assertEqual(guest.unix_socket_peers(61, 40), [])
            self.assertEqual(guest.unix_socket_peers(60, 70), [])
        peer = {'pid': 40, 'startTicks': '40', 'uid': 1000, 'exe': '/usr/bin/xdg-dbus-proxy', 'command': 'proxy'}
        editor = {'pid': 60, 'startTicks': '60', 'uid': 1000, 'exe': '/app/bin/gnome-text-editor', 'command': 'gnome-text-editor'}
        own = {'pid': 39, 'startTicks': '39', 'uid': 1000, 'exe': '/usr/bin/bwrap'}
        other = {'pid': 59, 'startTicks': '59', 'uid': 1000, 'exe': '/usr/bin/bwrap'}
        with patch.object(guest, 'process', side_effect=lambda pid: peer if pid == 40 else editor), \
                patch.object(guest, 'editor_processes', return_value=[editor]), \
                patch.object(guest, 'ancestors', side_effect=lambda pid: [peer, own] if pid == 40 else [editor, other]):
            with patch.object(guest, 'flatpak_app', return_value='org.gnome.TextEditor'):
                with patch.object(guest, 'unix_socket_peers', return_value=[(9001, 9002)]):
                    match = guest.editor_identity(40, 1000)
                    self.assertEqual((match['pid'], match['proxySocketPairs']), (60, [(9001, 9002)]))
                with patch.object(guest, 'unix_socket_peers', return_value=[]):
                    self.assertIsNone(guest.editor_identity(40, 1000))
            with patch.object(guest, 'flatpak_app', return_value='org.example.Other'), \
                    patch.object(guest, 'unix_socket_peers', return_value=[(9001, 9002)]):
                self.assertIsNone(guest.editor_identity(40, 1000))

    def test_rejected_peer_records_why_without_relaxing(self):
        guest_spec = importlib.util.spec_from_file_location('gui_document_guest', SOURCE.with_name('gui-document-guest.py'))
        guest = importlib.util.module_from_spec(guest_spec)
        guest_spec.loader.exec_module(guest)
        guest.unix_socket_peers = lambda a, b: []
        peer = {'pid': 40, 'startTicks': '40', 'uid': 1000, 'exe': '/usr/bin/xdg-dbus-proxy', 'command': 'proxy'}
        shell = {**peer, 'exe': '/usr/bin/gnome-shell'}
        why = []
        with patch.object(guest, 'process', return_value=shell):
            self.assertIsNone(guest.editor_identity(40, 1000, why))
        self.assertIn('neither the editor nor xdg-dbus-proxy', why[0])
        why = []
        with patch.object(guest, 'process', return_value=peer), patch.object(guest, 'editor_processes', return_value=[]), \
                patch.object(guest, 'ancestors', return_value=[peer]):
            self.assertIsNone(guest.editor_identity(40, 1000, why))
        self.assertTrue(any('no readable gnome-text-editor' in reason for reason in why))
        self.assertTrue(any('matched 0 editor sandboxes' in reason for reason in why))



if __name__ == '__main__':
    unittest.main()
