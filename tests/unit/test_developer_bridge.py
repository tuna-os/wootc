#!/usr/bin/env python3
"""Developer-setup bridge: Windows ~/.ssh and ~/.gitconfig -> the Linux account.

Run with: python3 tests/unit/test_developer_bridge.py
Copies, modes, refusals and the chooser gate run the production library,
wrapper and wootc-mount-user-dirs function against real temporary trees;
only account lookup, mountpoint and SELinux tools are fixtures.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'payload/migration'
spec = importlib.util.spec_from_file_location('wootc_import_safety', MIGRATION / 'lib/wootc_import_safety.py')
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)

PRIVATE = b'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n'
PUBLIC = b'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture wootc-e2e-run\n'
CONFIG = b'Host wootc-e2e-git\n  HostName git.example.org\n  User git\n  IdentityFile ~/.ssh/id_ed25519\n'
KNOWN = b'git.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostFixture\n'
AUTHORIZED = b'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAuthorized laptop\n'
GITCONFIG = (b'\xef\xbb\xbf# Windows Git for Windows config\r\n'
             b'[user]\r\n\tname = Wootc Tester\r\n\temail = wootc@example.org\r\n'
             b'\tsigningkey = C:/Users/wootc/.ssh/id_ed25519.pub\r\n'
             b'[core]\r\n\tautocrlf = true\r\n\tsshCommand = C:/Windows/System32/OpenSSH/ssh.exe\r\n'
             b'[credential]\r\n\thelper = manager\r\n'
             b'[credential "https://dev.azure.com"]\r\n\tuseHttpPath = true\r\n'
             b'[init]\r\n\tdefaultBranch = main\r\n')


class DeveloperBridge(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home_path = self.base / 'home'
        self.home_path.mkdir()
        self.host = self.base / 'host'
        self.profile = self.host / 'Users/wootc'
        self.profile.mkdir(parents=True)
        account = SimpleNamespace(pw_dir=str(self.home_path), pw_uid=os.geteuid(),
                                  pw_gid=os.getegid(), pw_name='fixture')
        self.home = safety.Home(account)
        self.addCleanup(self.home.close)

    def put(self, relative, content):
        path = self.profile / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def seed(self):
        """The hosted E2E's Windows seed, byte for byte."""
        self.put('.ssh/id_ed25519', PRIVATE)
        self.put('.ssh/id_ed25519.pub', PUBLIC)
        self.put('.ssh/config', CONFIG)
        self.put('.ssh/known_hosts', KNOWN)
        self.put('.ssh/authorized_keys', AUTHORIZED)
        self.put('.gitconfig', GITCONFIG)

    def mode(self, relative):
        return stat.S_IMODE((self.home_path / relative).stat().st_mode)

    def test_public_ssh_files_copied_byte_identical_with_ssh_modes(self):
        self.seed()
        result = safety.developer(self.home, self.host, 'wootc')
        self.assertEqual(result['status'], 'success', result)
        for name, content, mode in (('id_ed25519.pub', PUBLIC, 0o644), ('config', CONFIG, 0o600),
                                    ('known_hosts', KNOWN, 0o644), ('authorized_keys', AUTHORIZED, 0o600)):
            with self.subTest(name=name):
                self.assertEqual((self.home_path / '.ssh' / name).read_bytes(), content)
                self.assertEqual(self.mode('.ssh/' + name), mode)
                self.assertEqual((self.home_path / '.ssh' / name).stat().st_uid, os.geteuid())
                self.assertIn('.ssh/' + name, result['migrated'])
        self.assertEqual(self.mode('.ssh'), 0o700)
        record = json.loads((self.home_path / '.config/wootc/bridge-developer.json').read_text())
        self.assertEqual(record, result)

    @unittest.skipUnless(shutil.which('ssh'), 'ssh not installed')
    def test_copied_config_resolves_the_e2e_host(self):
        self.seed()
        safety.developer(self.home, self.host, 'wootc')
        resolved = subprocess.run(['ssh', '-G', '-F', str(self.home_path / '.ssh/config'), 'wootc-e2e-git'],
                                  capture_output=True, text=True, check=True).stdout.splitlines()
        self.assertIn('hostname git.example.org', resolved)
        self.assertIn('user git', resolved)

    def test_private_keys_are_never_copied_and_are_listed(self):
        self.seed()
        self.put('.ssh/id_rsa', b'opaque bytes with no header\n')        # id_* without extension
        self.put('.ssh/work', b'opaque\n')                               # has a matching .pub
        self.put('.ssh/work.pub', PUBLIC)
        self.put('.ssh/deploy-key', b'-----BEGIN RSA PRIVATE KEY-----\nMIIE\n')  # header only
        self.put('.ssh/misnamed.pub', b'-----BEGIN EC PRIVATE KEY-----\nMHcC\n')
        self.put('.ssh/putty.ppk', b'PuTTY-User-Key-File-3: ssh-ed25519\n')
        self.put('.ssh/known_hosts.old', KNOWN)
        result = safety.developer(self.home, self.host, 'wootc')
        left = {entry['path']: entry['reason'] for entry in result['leftOnWindows']}
        self.assertEqual(set(left), {'.ssh/id_ed25519', '.ssh/id_rsa', '.ssh/work', '.ssh/deploy-key',
                                     '.ssh/misnamed.pub', '.ssh/putty.ppk'})
        self.assertIn('matching .pub', left['.ssh/id_ed25519'])
        self.assertIn('PRIVATE KEY', left['.ssh/misnamed.pub'])
        for name in left:
            self.assertFalse((self.home_path / name).exists(), name)
        for path in self.home_path.rglob('*'):
            if path.is_file():
                self.assertNotIn(b'-----BEGIN', path.read_bytes(), path)
        self.assertEqual((self.home_path / '.ssh/work.pub').read_bytes(), PUBLIC)
        self.assertIn({'path': '.ssh/known_hosts.old', 'reason':
                       'only SSH public keys, config, known_hosts and authorized_keys are copied'},
                      result['notCarried'])
        self.assertFalse((self.home_path / '.ssh/known_hosts.old').exists())

    def test_gitconfig_carries_identity_only(self):
        self.seed()
        result = safety.developer(self.home, self.host, 'wootc')
        written = (self.home_path / '.gitconfig').read_text()
        body = [line for line in written.splitlines() if not line.startswith('#')]
        self.assertEqual(body, ['[user]', '\tname = Wootc Tester', '\temail = wootc@example.org',
                                '[init]', '\tdefaultBranch = main'])
        self.assertEqual(self.mode('.gitconfig'), 0o644)
        for leaked in ('credential', 'autocrlf', 'sshCommand', 'C:/', 'manager'):
            self.assertNotIn(leaked, "\n".join(body))
        not_carried = {entry['key']: entry['reason'] for entry in result['notCarried'] if entry['path'] == '.gitconfig'}
        self.assertEqual(set(not_carried), {'user.signingkey', 'core.autocrlf', 'core.sshcommand',
                                            'credential.helper', 'credential.https://dev.azure.com.usehttppath'})
        self.assertEqual(not_carried['user.signingkey'], 'Windows path')
        self.assertIn('credential store', not_carried['credential.helper'])
        self.assertIn('.gitconfig', result['migrated'])

    @unittest.skipUnless(shutil.which('git'), 'git not installed')
    def test_gitconfig_values_parse_exactly_as_git_reads_them(self):
        tricky = (b'[user]\n  name = "  Ann ; O\\"Neil #1 "  ; trailing comment\n'
                  b'  email = ann@example.org # comment\n'
                  b'[alias]\n  co = checkout\n'
                  b'[user]\n  signingkey = ABCD\\\n1234\n')
        self.put('.gitconfig', tricky)
        safety.developer(self.home, self.host, 'wootc')
        written = self.home_path / '.gitconfig'
        for key in ('user.name', 'user.email', 'user.signingkey'):
            with self.subTest(key=key):
                windows = subprocess.run(['git', 'config', '--file', str(self.profile / '.gitconfig'), '--get', key],
                                         capture_output=True, text=True, check=True).stdout
                linux = subprocess.run(['git', 'config', '--file', str(written), '--get', key],
                                       capture_output=True, text=True, check=True).stdout
                self.assertEqual(linux, windows)
        self.assertNotIn('checkout', written.read_text())

    def test_existing_linux_gitconfig_and_xdg_config_are_preserved(self):
        self.seed()
        native = b'[user]\n\tname = Linux Me\n'
        (self.home_path / '.gitconfig').write_bytes(native)
        result = safety.developer(self.home, self.host, 'wootc')
        self.assertEqual((self.home_path / '.gitconfig').read_bytes(), native)
        self.assertIn('.gitconfig', result['preserved'])
        self.assertEqual(result['status'], 'partial')
        (self.home_path / '.gitconfig').unlink()
        (self.home_path / '.config/git').mkdir(parents=True)
        (self.home_path / '.config/git/config').write_bytes(native)
        result = safety.developer(self.home, self.host, 'wootc')
        self.assertFalse((self.home_path / '.gitconfig').exists())
        self.assertIn('.config/git/config', result['preserved'])

    def test_second_boot_is_idempotent_and_never_overwrites_edits(self):
        self.seed()
        first = safety.developer(self.home, self.host, 'wootc')
        snapshot = {p: p.read_bytes() for p in self.home_path.rglob('*')
                    if p.is_file() and '.config/wootc' not in str(p)}
        second = safety.developer(self.home, self.host, 'wootc')
        self.assertEqual(second['status'], 'success')
        self.assertEqual(second['migrated'], [])
        self.assertEqual(sorted(second['alreadyPresent']), sorted(first['migrated']))
        self.assertEqual(second['leftOnWindows'], first['leftOnWindows'])
        self.assertEqual({p: p.read_bytes() for p in snapshot}, snapshot)
        edited = self.home_path / '.ssh/known_hosts'
        edited.write_bytes(KNOWN + b'linux.example.org ssh-ed25519 AAAALinux\n')
        third = safety.developer(self.home, self.host, 'wootc')
        self.assertIn('.ssh/known_hosts', third['preserved'])
        self.assertTrue(edited.read_bytes().endswith(b'AAAALinux\n'))

    def test_symlinked_source_ssh_dir_is_refused(self):
        outside = self.base / 'outside'
        outside.mkdir()
        (outside / 'id_ed25519.pub').write_bytes(PUBLIC)
        (self.profile / '.ssh').symlink_to(outside, target_is_directory=True)
        result = safety.developer(self.home, self.host, 'wootc')
        self.assertEqual(result['status'], 'failed')
        self.assertFalse((self.home_path / '.ssh').exists())

    def environment(self):
        bins = self.base / 'bin'
        bins.mkdir()
        driver = bins / 'python3'
        driver.write_text('#!' + sys.executable + '\n'
            'import os,pwd,runpy,sys,types\n'
            'original=pwd.getpwnam\n'
            'def fixture(name):\n'
            '    if name == "fixture": return types.SimpleNamespace(pw_dir=os.environ["FIXTURE_HOME"],pw_uid=os.geteuid(),pw_gid=os.getegid(),pw_name=name)\n'
            '    return original(name)\n'
            'pwd.getpwnam=fixture\n'
            'sys.argv=sys.argv[1:]\n'
            'runpy.run_path(sys.argv[0],run_name="__main__")\n')
        stubs = {
            'mountpoint': '#!/bin/sh\nexit 0\n',
            'getent': '#!/bin/sh\nprintf "fixture:x:0:0::%s:/bin/bash\\n" "$FIXTURE_HOME"\n',
            'selinuxenabled': '#!/bin/sh\nexit 0\n',
            'restorecon': '#!/bin/sh\nprintf "%s\\n" "$*" >>"$RESTORECON_LOG"\n',
        }
        for name, content in stubs.items():
            (bins / name).write_text(content)
        for path in bins.iterdir():
            path.chmod(0o755)
        for name in ('wootc-developer-bridge', 'wootc-selection'):
            (bins / name).symlink_to(MIGRATION / name)
        return {**os.environ, 'PATH': str(bins) + ':/usr/bin:/bin', 'WOOTC_HOST': str(self.host),
                'FIXTURE_HOME': str(self.home_path), 'RESTORECON_LOG': str(self.base / 'restorecon.log'),
                'WOOTC_SELECTION': str(self.base / 'selection.json')}

    def boot(self, env):
        """Run the per-user call exactly as wootc-mount-user-dirs defines it."""
        script = MIGRATION / 'wootc-mount-user-dirs'
        return subprocess.run(['bash', '-c',
            'log() { echo "[wootc-passthrough] $*"; }\n'
            'eval "$(sed -n \'/^sel_on()/,/^}/p\' "$1")"\n'
            'eval "$(sed -n \'/^developer_bridge()/,/^}/p\' "$1")"\n'
            'developer_bridge wootc fixture', 'bash', str(script)],
            capture_output=True, text=True, env=env)

    def test_boot_gate_copies_when_on_relabels_and_skips_when_chooser_off(self):
        self.seed()
        env = self.environment()
        selection = Path(env['WOOTC_SELECTION'])
        selection.write_text(json.dumps({'version': 1, 'selection': {'wootc': {'developer': {'on': False}}}}))
        off = self.boot(env)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertIn('developer: skipped for fixture (turned off in the migration chooser)', off.stdout)
        self.assertEqual(list(self.home_path.iterdir()), [])
        self.assertFalse(Path(env['RESTORECON_LOG']).exists())

        selection.write_text(json.dumps({'version': 1, 'selection': {'wootc': {'developer': {'on': True}}}}))
        on = self.boot(env)
        self.assertEqual(on.returncode, 0, on.stderr)
        record = json.loads(on.stdout.splitlines()[-1])
        self.assertEqual(record['status'], 'success')
        self.assertIn('.ssh/id_ed25519', [entry['path'] for entry in record['leftOnWindows']])
        self.assertEqual((self.home_path / '.ssh/config').read_bytes(), CONFIG)
        self.assertFalse((self.home_path / '.ssh/id_ed25519').exists())
        relabelled = Path(env['RESTORECON_LOG']).read_text().splitlines()
        self.assertEqual(relabelled, ['-RF ' + str(self.home_path / '.ssh'), '-RF ' + str(self.home_path / '.gitconfig')])
        self.assertIn('restored SELinux labels on ' + str(self.home_path / '.ssh'), on.stderr)

    def test_manifest_offers_developer_setup_default_on(self):
        self.seed()
        scan = subprocess.run([sys.executable, str(MIGRATION / 'wootc-manifest'), 'scan', 'wootc'],
                              capture_output=True, text=True, check=True,
                              env={**os.environ, 'WOOTC_HOST': str(self.host)})
        category = next(c for c in json.loads(scan.stdout)['users'][0]['categories'] if c['id'] == 'developer')
        self.assertEqual(category['label'], 'Developer setup')
        self.assertTrue(category['present'] and category['defaultOn'])
        self.assertIn('private keys', category['summary'])
        self.assertEqual([i['id'] for i in category['items']], ['ssh', 'git-identity'])


if __name__ == '__main__':
    unittest.main()
