#!/usr/bin/env python3
"""Real file/script controls for import collisions, interrupted writes and refusals.

Run with: python3 tests/unit/test_import_safety.py
The wrapper fixtures replace mount/account observations only. Copying, journal
recovery, filesystem collisions, /proc Steam detection and result consumers run
production code against actual temporary files. No mounted-volume proof is implied.
"""
import runpy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'payload/migration'
spec = importlib.util.spec_from_file_location('wootc_import_safety', MIGRATION / 'lib/wootc_import_safety.py')
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class ImportSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home_path = self.base / 'home'
        self.home_path.mkdir()
        self.host = self.base / 'host'
        self.profile = self.host / 'Users/Alice'
        self.profile.mkdir(parents=True)
        self.account = SimpleNamespace(pw_dir=str(self.home_path), pw_uid=os.geteuid(),
                                       pw_gid=os.getegid(), pw_name='fixture')
        self.home = safety.Home(self.account)
        self.addCleanup(self.home.close)

    def put(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return path

    def office_sources(self):
        microsoft = self.profile / 'AppData/Roaming/Microsoft'
        self.put(microsoft / 'UProof/CUSTOM.DIC', 'Kubernetes\r\nwootc\r\n')
        self.put(microsoft / 'Templates/Report.dotx', b'Windows template')
        self.put(microsoft / 'Office/default.acl', 'teh\x00the'.encode('utf-16le'))
        self.put(self.profile / 'AppData/Local/Microsoft/Windows/Fonts/Calibri.ttf', b'Windows font')

    def test_office_copies_actual_files_and_repeat_preserves_linux_edits(self):
        self.office_sources()
        first = safety.office(self.home, self.host, 'Alice')
        self.assertEqual(first['status'], 'success')
        template = self.home_path / '.config/libreoffice/4/user/template/Report.dotx'
        font = self.home_path / '.local/share/fonts/Calibri.ttf'
        self.assertEqual(template.read_bytes(), b'Windows template')
        self.assertEqual(font.read_bytes(), b'Windows font')
        dictionary = self.home_path / '.config/libreoffice/4/user/wordbook/standard.dic'
        self.assertIn('Kubernetes', dictionary.read_text())
        template.write_bytes(b'Linux edited template')
        font.write_bytes(b'Linux edited font')
        registry = self.home_path / '.config/libreoffice/4/user/registrymodifications.xcu'
        registry.write_bytes(b'Linux save defaults')
        result = safety.office(self.home, self.host, 'Alice')
        self.assertEqual(result['status'], 'partial')
        self.assertEqual(result['migrated'], [])
        self.assertIn(str(template.relative_to(self.home_path)), result['preserved'])
        self.assertIn(str(font.relative_to(self.home_path)), result['preserved'])
        self.assertEqual(template.read_bytes(), b'Linux edited template')
        self.assertEqual(font.read_bytes(), b'Linux edited font')
        self.assertEqual(registry.read_bytes(), b'Linux save defaults')
        self.assertEqual(dictionary.read_text().splitlines().count('Kubernetes'), 1)
        self.assertEqual((self.profile / 'AppData/Roaming/Microsoft/Templates/Report.dotx').read_bytes(), b'Windows template')

    def test_office_symlink_parent_and_dictionary_never_touch_referent(self):
        self.office_sources()
        outside = self.base / 'outside'
        canary = self.put(outside / '4/user/wordbook/standard.dic', b'untouched native dictionary')
        (self.home_path / '.config').mkdir()
        (self.home_path / '.config/libreoffice').symlink_to(outside, target_is_directory=True)
        result = safety.office(self.home, self.host, 'Alice')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(canary.read_bytes(), b'untouched native dictionary')
        self.assertTrue((self.home_path / '.config/libreoffice').is_symlink())
        self.assertFalse((outside / '4/user/template/Report.dotx').exists())

    def test_final_symlink_and_hardlink_are_refused(self):
        canary = self.put(self.base / 'canary', b'Linux original')
        (self.home_path / 'Documents').mkdir()
        (self.home_path / 'Documents/symlink').symlink_to(canary)
        os.link(canary, self.home_path / 'Documents/hardlink')
        for name in ('symlink', 'hardlink'):
            with self.subTest(name=name), self.assertRaises((OSError, ValueError)):
                self.home.publish('Documents/' + name, data=b'Windows bytes')
        self.assertEqual(canary.read_bytes(), b'Linux original')

    def test_publication_race_preserves_competing_file(self):
        original_link = os.link
        def competitor(source, destination, **kwargs):
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600,
                         dir_fd=kwargs['dst_dir_fd'])
            os.write(fd, b'Linux race winner')
            os.close(fd)
            return original_link(source, destination, **kwargs)
        with patch.object(safety.os, 'link', side_effect=competitor):
            result = self.home.publish('Documents/report', data=b'Windows bytes')
        self.assertEqual(result, 'preserved')
        self.assertEqual((self.home_path / 'Documents/report').read_bytes(), b'Linux race winner')

    def test_moved_parent_cannot_report_a_successful_import(self):
        original_link = os.link
        def move_parent(source, destination, **kwargs):
            (self.home_path / 'Documents').rename(self.home_path / 'moved-documents')
            (self.home_path / 'Documents').mkdir()
            return original_link(source, destination, **kwargs)
        with patch.object(safety.os, 'link', side_effect=move_parent):
            with self.assertRaisesRegex(ValueError, 'parent changed'):
                self.home.publish('Documents/report', data=b'complete bytes')
        self.assertFalse((self.home_path / 'Documents/report').exists())
        self.assertEqual((self.home_path / 'moved-documents/report').read_bytes(), b'complete bytes')

    def test_failed_fsync_does_not_publish_partial_destination_and_retry_works(self):
        original_sync = os.fsync
        def full_device(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError('injected disk-full during sync')
            return original_sync(fd)
        with patch.object(safety.os, 'fsync', side_effect=full_device):
            with self.assertRaises(OSError):
                self.home.publish('Documents/report', data=b'complete bytes')
        self.assertFalse((self.home_path / 'Documents/report').exists())
        self.assertEqual(list((self.home_path / 'Documents').glob('.wootc-import-*')), [])
        self.assertEqual(self.home.publish('Documents/report', data=b'complete bytes'), 'copied')

    def interrupt_dictionary(self):
        relative = '.config/libreoffice/4/user/wordbook/standard.dic'
        self.home.publish(relative, data=b'OOoUserDict1\nlang: <none>\ntype: positive\n---\nLinuxWord\n')
        original_write = os.write
        calls = 0
        def short_write(fd, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return original_write(fd, data[:3])
            raise OSError('injected interrupted dictionary append')
        with patch.object(safety.os, 'write', side_effect=short_write):
            with self.assertRaises(OSError):
                safety.dictionary(self.home, relative, ['Kubernetes'])
        return relative

    def test_dictionary_partial_append_is_recovered_from_exact_receipt(self):
        relative = self.interrupt_dictionary()
        pending = self.home_path / '.config/wootc/office-dictionary-pending.json'
        self.assertTrue(json.loads(pending.read_text())['active'])
        self.assertTrue((self.home_path / relative).read_bytes().endswith(b'Kub'))
        safety.dictionary(self.home, relative, ['Kubernetes'])
        data = (self.home_path / relative).read_text()
        self.assertTrue(data.endswith('LinuxWord\nKubernetes\n'))
        self.assertEqual(data.splitlines().count('Kubernetes'), 1)
        self.assertFalse(json.loads(pending.read_text())['active'])

    def test_dictionary_recovery_refuses_intervening_linux_edit_without_truncate(self):
        relative = self.interrupt_dictionary()
        path = self.home_path / relative
        with path.open('ab') as out:
            out.write(b'Linux new edit\n')
        original = path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'changed after interrupted'):
            safety.dictionary(self.home, relative, ['Kubernetes'])
        self.assertEqual(path.read_bytes(), original)
        self.assertTrue(json.loads((self.home_path / '.config/wootc/office-dictionary-pending.json').read_text())['active'])

    def test_files_preserve_older_native_edits_and_reject_source_symlinks(self):
        source = self.put(self.profile / 'Documents/report', b'Windows source')
        native = self.put(self.home_path / 'Documents/report', b'Linux older edit')
        os.utime(native, (1, 1))
        outside = self.put(self.base / 'source-secret', b'not selected')
        (source.parent / 'link').symlink_to(outside)
        (source.parent / 'subdir').mkdir()
        self.put(source.parent / 'subdir/new-file', b'new file')
        result = safety.files(self.home, self.host, 'Alice')
        self.assertEqual(result['status'], 'failed')
        self.assertIn('Documents/report', result['preserved'])
        self.assertIn('Documents/subdir/new-file', result['migrated'])
        self.assertEqual(native.read_bytes(), b'Linux older edit')
        self.assertEqual(source.read_bytes(), b'Windows source')
        self.assertFalse((self.home_path / 'Documents/link').exists())

    def test_wsl_dotfiles_public_keys_and_brewfile_preserve_native_content(self):
        rootfs = self.base / 'rootfs'
        self.put(rootfs / 'home/windows/.bashrc', b'Windows WSL shell')
        self.put(rootfs / 'home/windows/.config/starship.toml', b'new prompt')
        self.put(rootfs / 'home/windows/.ssh/id_ed25519.pub', b'public key')
        self.put(rootfs / 'home/windows/.ssh/id_ed25519', b'private key must stay')
        native = self.put(self.home_path / '.bashrc', b'Linux shell edits')
        brew = self.put(self.home_path / '.config/wootc/Brewfile', b'brew "native-choice"\n')
        result = safety.wsl(self.home, rootfs, ['git', 'tmux'], 'fixture')
        self.assertEqual(result['status'], 'partial')
        self.assertIn('.bashrc', result['preserved'])
        self.assertIn('.config/wootc/Brewfile', result['preserved'])
        self.assertEqual(native.read_bytes(), b'Linux shell edits')
        self.assertEqual(brew.read_bytes(), b'brew "native-choice"\n')
        self.assertEqual((self.home_path / '.ssh/id_ed25519.pub').read_bytes(), b'public key')
        self.assertEqual(stat.S_IMODE((self.home_path / '.ssh/id_ed25519.pub').stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.home_path / '.ssh').stat().st_mode), 0o700)
        self.assertFalse((self.home_path / '.ssh/id_ed25519').exists())
        self.assertEqual(result['dotfiles'], 2)

    def test_wsl_dangling_destination_symlink_is_not_a_missing_file(self):
        rootfs = self.base / 'rootfs'
        self.put(rootfs / 'home/windows/.bashrc', b'WSL bytes')
        referent = self.base / 'must-not-appear'
        (self.home_path / '.bashrc').symlink_to(referent)
        result = safety.wsl(self.home, rootfs, [], 'fixture')
        self.assertEqual(result['status'], 'failed')
        self.assertFalse(referent.exists())
        self.assertTrue((self.home_path / '.bashrc').is_symlink())

    @unittest.skipUnless(os.geteuid() == 0, 'requires a real foreign-owned directory')
    def test_foreign_existing_directory_is_refused_not_recursively_chowned(self):
        foreign = self.home_path / '.local/share/fonts'
        self.put(foreign / 'native.ttf', b'native font')
        os.chown(foreign, 65534, 65534)
        os.chown(foreign / 'native.ttf', 65534, 65534)
        with self.assertRaisesRegex(ValueError, 'not target-owned'):
            self.home.publish('.local/share/fonts/new.ttf', data=b'Windows font')
        self.assertEqual(foreign.stat().st_uid, 65534)
        self.assertEqual((foreign / 'native.ttf').stat().st_uid, 65534)
        self.assertEqual((foreign / 'native.ttf').read_bytes(), b'native font')

    def steam_root(self):
        path = self.home_path / '.local/share/Steam/steamapps'
        path.mkdir(parents=True)
        return path / 'libraryfolders.vdf'

    def test_steam_absent_vdf_is_exclusively_created_and_exactly_recognized(self):
        vdf = self.steam_root()
        libraries = [str(self.host / 'Program Files (x86)/Steam'), str(self.host / 'Games/SteamLibrary')]
        result = safety.steam(self.home, libraries)
        self.assertEqual(result['status'], 'success')
        self.assertEqual(result['migrated'], libraries)
        self.assertEqual(safety.vdf_paths(vdf.read_bytes()), [str(vdf.parent.parent)] + libraries)
        before = vdf.read_bytes()
        second = safety.steam(self.home, libraries)
        self.assertEqual(second['migrated'], [])
        self.assertEqual(second['alreadyPresent'], libraries)
        self.assertEqual(vdf.read_bytes(), before)

    def test_steam_existing_vdf_refuses_substring_and_duplicate_indices(self):
        vdf = self.steam_root()
        library = str(self.host / 'Games/SteamLibrary')
        original = ('"libraryfolders" { "0" { "path" "' + library + '-old" } }').encode()
        vdf.write_bytes(original)
        result = safety.steam(self.home, [library])
        self.assertEqual(result['status'], 'failed')
        self.assertFalse(result['registered'])
        self.assertEqual(result['migrated'], [])
        self.assertIn('Add Library', result['failed'][0]['error'])
        self.assertEqual(vdf.read_bytes(), original)
        duplicate = b'"libraryfolders" { "0" { "path" "one" } "0" { "path" "two" } }'
        vdf.write_bytes(duplicate)
        result = safety.steam(self.home, [library])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(vdf.read_bytes(), duplicate)

    def test_steam_vdf_creation_race_refuses_and_preserves_linux_winner(self):
        vdf = self.steam_root()
        original_link = os.link
        native = b'"libraryfolders" { "7" { "path" "/native-library" } }'
        def competitor(source, destination, **kwargs):
            if destination == 'libraryfolders.vdf':
                vdf.write_bytes(native)
            return original_link(source, destination, **kwargs)
        with patch.object(safety.os, 'link', side_effect=competitor):
            result = safety.steam(self.home, [str(self.host / 'Steam')])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['migrated'], [])
        self.assertEqual(vdf.read_bytes(), native)

    @unittest.skipUnless(Path('/proc/self/comm').exists(), 'requires Linux /proc')
    def test_real_running_steam_process_blocks_absent_vdf_registration(self):
        vdf = self.steam_root()
        process = subprocess.Popen([sys.executable, '-c',
            'import ctypes,time; ctypes.CDLL(None).prctl(15,b"steam",0,0,0); print("ready",flush=True); time.sleep(60)'],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            result = safety.steam(self.home, [str(self.host / 'Steam')])
            self.assertEqual(result['status'], 'failed')
            self.assertIn('Steam is running', result['failed'][0]['error'])
            self.assertFalse(vdf.exists())
        finally:
            process.terminate()
            process.wait(timeout=10)
            process.stdout.close()

    def wrapper_environment(self):
        bins = self.base / 'bin'
        bins.mkdir(exist_ok=True)
        driver = bins / 'python3'
        driver.write_text('#!' + sys.executable + '\n'
            'import os,pwd,runpy,sys,types\n'
            'original=pwd.getpwnam\n'
            'def fixture(name):\n'
            '    if name == "fixture": return types.SimpleNamespace(pw_dir=os.environ["FIXTURE_HOME"],pw_uid=os.geteuid(),pw_gid=os.getegid(),pw_name=name)\n'
            '    return original(name)\n'
            'pwd.getpwnam=fixture\n'
            'sys.argv=sys.argv[1:]\n'
            'if sys.argv[0] == "-":\n'
            '    exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})\n'
            'else:\n'
            '    runpy.run_path(sys.argv[0],run_name="__main__")\n')
        driver.chmod(0o755)
        for name, content in {
            'mountpoint': '#!/bin/sh\nexit 0\n',
            'findmnt': '#!/bin/sh\nprintf "ro,nosuid,nodev\\n"\n',
            'getent': '#!/bin/sh\nprintf "fixture:x:' + str(os.geteuid()) + ':' + str(os.getegid()) + ':fixture:%s:/bin/bash\\n" "$FIXTURE_HOME"\n',
            'id': '#!/bin/sh\nprintf "0\\n"\n',
        }.items():
            path = bins / name
            path.write_text(content)
            path.chmod(0o755)
        return {**os.environ, 'PATH': str(bins) + ':/usr/bin:/bin', 'WOOTC_HOST': str(self.host),
                'FIXTURE_HOME': str(self.home_path), 'WOOTC_WSL_ROOTFS': str(self.base / 'rootfs')}

    def test_actual_office_and_wsl_wrappers_publish_truthful_results(self):
        self.office_sources()
        self.put(self.base / 'rootfs/home/windows/.bashrc', b'WSL shell')
        env = self.wrapper_environment()
        for name in ('wootc-office-bridge', 'wootc-wsl-bridge'):
            completed = subprocess.run(['bash', str(MIGRATION / name), 'Alice', 'fixture'],
                                       capture_output=True, text=True, env=env)
            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            result = json.loads(completed.stdout)
            self.assertEqual(result['status'], 'success')
            self.assertTrue(result['migrated'])
        self.assertEqual((self.home_path / '.bashrc').read_bytes(), b'WSL shell')
        self.assertTrue((self.home_path / '.config/libreoffice/4/user/template/Report.dotx').is_file())

    def test_actual_external_script_rejects_failed_and_unverified_bridges(self):
        env = self.wrapper_environment()
        helper = self.base / 'bin/wootc-office-bridge'
        for returncode in (7, 0):
            helper.write_text('#!/bin/sh\nexit ' + str(returncode) + '\n')
            helper.chmod(0o755)
            self.home.record('.config/wootc/bridge-office.json', {'status': 'success', 'migrated': ['stale']})
            completed = subprocess.run(['bash', str(MIGRATION / 'wootc-import'), 'import',
                str(self.host), 'Alice', '--target', 'fixture', 'office'],
                capture_output=True, text=True, env=env)
            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            result = json.loads(completed.stdout)
            self.assertEqual(result['imported'], [])
            self.assertEqual(result['failed'] if returncode else result['partial'], ['office'])
            self.assertEqual(json.loads((self.home_path / '.config/wootc/import-result.json').read_text()), result)

    def test_actual_external_script_preserves_foreign_bound_source(self):
        env = self.wrapper_environment()
        selected = self.base / 'other-host'
        (selected / 'Users/Alice').mkdir(parents=True)
        completed = subprocess.run(['bash', str(MIGRATION / 'wootc-import'), 'import',
            str(selected), 'Alice', '--target', 'fixture', 'office'],
            capture_output=True, text=True, env=env)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('another Windows volume', completed.stderr)
        self.assertFalse((self.home_path / '.config').exists())

    def test_actual_external_files_copy_reports_copied_then_preserved(self):
        env = self.wrapper_environment()
        source = self.put(self.profile / 'Documents/report', b'Windows original')
        command = ['bash', str(MIGRATION / 'wootc-import'), 'import',
                   str(self.host), 'Alice', '--target', 'fixture', 'files']
        first = subprocess.run(command, capture_output=True, text=True, env=env)
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        self.assertEqual(json.loads(first.stdout)['imported'], ['files'])
        destination = self.home_path / 'Documents/report'
        self.assertEqual(destination.read_bytes(), b'Windows original')
        destination.write_bytes(b'Linux edited copy')
        second = subprocess.run(command, capture_output=True, text=True, env=env)
        self.assertNotEqual(second.returncode, 0)
        result = json.loads(second.stdout)
        self.assertEqual(result['imported'], [])
        self.assertEqual(result['partial'], ['files'])
        self.assertEqual(result['categories']['files']['preserved'], ['Documents/report'])
        self.assertEqual(destination.read_bytes(), b'Linux edited copy')
        self.assertEqual(source.read_bytes(), b'Windows original')

    def test_gui_engine_rejects_partial_success_and_surfaces_steam_refusal(self):
        namespace = runpy.run_path(str(MIGRATION / 'wootc-import-gui'))
        engine_script = self.base / 'engine'
        record = {'status': 'failed', 'imported': [], 'categories': {
            'steam': {'status': 'failed', 'failed': [
                {'error': 'Existing Steam metadata preserved; use Settings > Storage > Add Library.'}]}}}
        engine_script.write_text('#!/bin/sh\nprintf \'%s\\n\' ' + shlex.quote(json.dumps(record)) + '\nexit 1\n')
        engine_script.chmod(0o755)
        engine = namespace['ImportEngine'](engine=str(engine_script), pkexec=False)
        with self.assertRaisesRegex(RuntimeError, 'Add Library'):
            engine.do_import('/source', 'Alice', 'fixture', ['steam'])
        record = {'status': 'partial', 'imported': [], 'categories': {
            'office': {'status': 'partial', 'preserved': ['Report.dotx']}}}
        engine_script.write_text('#!/bin/sh\nprintf \'%s\\n\' ' + shlex.quote(json.dumps(record)) + '\nexit 0\n')
        with self.assertRaisesRegex(RuntimeError, 'preserved'):
            engine.do_import('/source', 'Alice', 'fixture', ['office'])



if __name__ == '__main__':
    unittest.main()
