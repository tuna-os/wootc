#!/usr/bin/env python3
"""Actual conversion script/rsync/move with private files and mount/identity mocks."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'payload/migration/wootc-convert-dir'


class ConversionSwap(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('rsync'):
            raise RuntimeError('rsync required for actual conversion behavior tests')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wootc convert swap ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / 'home'
        self.dst = self.home / 'Documents'
        self.dst.mkdir(parents=True)
        self.src = self.base / 'Windows Documents'
        self.src.mkdir()
        (self.src / 'work.txt').write_bytes(b'Windows original\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.command('getent', f"printf '%s\\n' {shlex.quote(f'audit-convert:x:{os.getuid()}:{os.getgid()}::{self.home}:/bin/sh')}")
        self.command('mountpoint', 'exit 0')
        self.command('findmnt', f"printf '%s\\n' {shlex.quote(str(self.src))}")
        self.command('umount', 'exit 0')
        self.command('chown', 'exit 0')
        self.marker = self.home / '.config/wootc/converted-Documents'
        self.staging = self.home / '.wootc-convert-Documents.partial'

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def run_script(self, script=SCRIPT):
        env = os.environ.copy()
        env['PATH'] = str(self.bin) + os.pathsep + env['PATH']
        result = subprocess.run(['bash', str(script), 'audit-convert', 'Documents'],
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual((self.src / 'work.txt').read_bytes(), b'Windows original\n')
        return result

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.marker.exists(), 'refused swap published conversion')

    def test_native_work_refused_before_copy(self):
        self.command('mountpoint', 'exit 1')
        (self.dst / 'linux.txt').write_bytes(b'Linux edits\n')
        self.assert_refused(self.run_script())
        self.assertEqual((self.dst / 'linux.txt').read_bytes(), b'Linux edits\n')
        self.assertFalse(self.staging.exists())

    def test_hidden_native_work_after_unmount_refuses_marker(self):
        path = shlex.quote(str(self.dst / 'hidden.txt'))
        self.command('umount', f"printf '%s\\n' 'Hidden native work' > {path}")
        self.assert_refused(self.run_script())
        self.assertEqual((self.dst / 'hidden.txt').read_text(), 'Hidden native work\n')
        self.assertEqual((self.staging / 'work.txt').read_bytes(), b'Windows original\n')
        self.assertFalse((self.dst / self.staging.name).exists())

    def race_at_move(self):
        dst = shlex.quote(str(self.dst))
        path = shlex.quote(str(self.dst / 'racing.txt'))
        mv = shlex.quote(shutil.which('mv'))
        self.command('mv', f'mkdir -p {dst}\nprintf "Racing work\\n" > {path}\nexec {mv} "$@"')

    def test_directory_appearing_at_move_cannot_nest_staging(self):
        self.race_at_move()
        self.assert_refused(self.run_script())
        self.assertEqual((self.dst / 'racing.txt').read_text(), 'Racing work\n')
        self.assertTrue((self.staging / 'work.txt').exists())
        self.assertFalse((self.dst / self.staging.name).exists())

    def test_success_publishes_actual_folder_then_preserves_edits_on_retry(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.is_file())
        self.assertFalse(self.staging.exists())
        self.assertEqual((self.dst / 'work.txt').read_bytes(), b'Windows original\n')
        (self.dst / 'work.txt').write_bytes(b'New Linux edits\n')
        marker = self.marker.read_bytes()
        self.command('mountpoint', 'exit 1')
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual((self.dst / 'work.txt').read_bytes(), b'New Linux edits\n')
        self.assertEqual(self.marker.read_bytes(), marker)

    def test_move_guard_mutant_reproduces_false_conversion(self):
        self.race_at_move()
        mutant = self.base / 'unsafe-convert'
        source = SCRIPT.read_text()
        self.assertIn('mv -T -- "$staging" "$dst"', source)
        mutant.write_text(source.replace('mv -T -- "$staging" "$dst"',
                                         'mv -- "$staging" "$dst"'))
        result = self.run_script(mutant)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertFalse((self.dst / 'work.txt').exists())
        self.assertTrue((self.dst / self.staging.name / 'work.txt').exists())


if __name__ == '__main__':
    unittest.main()
