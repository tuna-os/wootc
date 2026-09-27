#!/usr/bin/env python3
"""Exercise the GUI acceptance gate with observable failures, not string guards."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'e2e' / 'gui-document-proof.py'
spec = importlib.util.spec_from_file_location('gui_document_proof', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SEED, MARKER = 'wootc-e2e-userdata run1', 'wootc-e2e-gui-edit-run1'


class FakeDesktop:
    def __init__(self, defect=None):
        self.defect, self.text, self.buffer = defect, SEED + '\n', ''
        self.open, self.focused, self.opens = False, False, 0
        self.events = []

    def observe(self, action):
        self.events.append(action)
        if action == 'tooling':
            return {'nativeEditor': self.defect != 'tooling-editor', 'installedFlatpaks': [],
                    'libatspi': self.defect != 'tooling-accessibility'}
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
                    'buffer': self.buffer, 'process': {'pid': 100 + self.opens,
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


if __name__ == '__main__':
    unittest.main()
