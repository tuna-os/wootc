#!/usr/bin/env python3
"""Hostile-tree controls for the account-picture copy (wootc-identity apply).

Run with: python3 tests/unit/test_identity_safety.py
`apply` runs as root on every boot and touches two trees that the migrated
person controls: the Windows profile it reads and the Linux home it writes.
Each test plants a link to a canary outside that tree and fails when the canary
is read or changed. The production script runs against real temporary files;
only the switch to the home owner's credentials is observed through a recorder,
because the fast tier has no root. tests/migration/test-bridge.sh repeats the
destination case as root with a real account.
"""
from importlib.machinery import SourceFileLoader
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'payload/migration/wootc-identity'


class IdentityPicture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.host = self.base / 'host'
        self.pictures = self.host / 'Users/bob/AppData/Roaming/Microsoft/Windows/AccountPictures'
        self.pictures.mkdir(parents=True)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.accounts = self.base / 'accounts'
        self.outside = self.base / 'outside'
        self.outside.mkdir()
        self.canary = self.outside / 'canary'
        self.canary.write_text('canary\n')

    def apply(self):
        environment = dict(os.environ, WOOTC_HOST=str(self.host), WOOTC_HOME=str(self.home),
                           WOOTC_AS_DIR=str(self.accounts))
        completed = subprocess.run([sys.executable, str(SCRIPT), 'apply', 'bob', 'bob'],
                                   env=environment, capture_output=True, text=True, check=True)
        return json.loads(completed.stdout)

    def test_face_link_to_an_existing_file_is_replaced_not_written_through(self):
        (self.pictures / 'tile.png').write_bytes(b'PICTURE')
        (self.home / '.face').symlink_to(self.canary)
        result = self.apply()
        self.assertEqual(self.canary.read_text(), 'canary\n')
        self.assertFalse((self.home / '.face').is_symlink())
        self.assertEqual((self.home / '.face').read_bytes(), b'PICTURE')
        self.assertIn('face', result['applied'])
        self.assertEqual([entry.name for entry in self.home.iterdir()], ['.face'])

    def test_dangling_face_link_creates_nothing_at_its_referent(self):
        (self.pictures / 'tile.png').write_bytes(b'PICTURE')
        referent = self.outside / 'created-by-root'
        (self.home / '.face').symlink_to(referent)
        self.apply()
        self.assertFalse(referent.exists())
        self.assertEqual(sorted(entry.name for entry in self.outside.iterdir()), ['canary'])
        self.assertEqual((self.home / '.face').read_bytes(), b'PICTURE')

    def test_linked_picture_is_never_read(self):
        secret = self.outside / 'secret'
        secret.write_bytes(b'S' * 4096)
        (self.pictures / 'large.png').symlink_to(secret)
        result = self.apply()
        self.assertEqual(result['applied'], [])
        self.assertFalse((self.home / '.face').exists())
        self.assertFalse((self.accounts / 'icons/bob').exists())
        # A real picture next to the link is still the one that is copied.
        (self.pictures / 'tile.png').write_bytes(b'PICTURE')
        self.apply()
        self.assertEqual((self.home / '.face').read_bytes(), b'PICTURE')
        self.assertEqual((self.accounts / 'icons/bob').read_bytes(), b'PICTURE')

    def test_picture_below_a_linked_directory_is_never_read(self):
        elsewhere = self.outside / 'pictures'
        elsewhere.mkdir()
        (elsewhere / 'secret.png').write_bytes(b'SECRET')
        self.pictures.rmdir()
        self.pictures.symlink_to(elsewhere, target_is_directory=True)
        result = self.apply()
        self.assertEqual(result['applied'], [])
        self.assertFalse((self.home / '.face').exists())
        self.assertFalse((self.accounts / 'icons/bob').exists())


class HomeOwnerCredentials(unittest.TestCase):
    def setUp(self):
        loader = SourceFileLoader('wootc_identity', str(SCRIPT))
        spec = importlib.util.spec_from_loader('wootc_identity', loader)
        self.identity = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        loader.exec_module(self.identity)

    def test_root_takes_the_home_owner_credentials_for_the_write_and_returns(self):
        calls = []
        account = SimpleNamespace(pw_uid=1001, pw_gid=1002)
        with patch.object(os, 'geteuid', return_value=0), \
                patch.object(os, 'getegid', return_value=0), \
                patch.object(os, 'getgroups', return_value=[0, 10]), \
                patch.object(self.identity.pwd, 'getpwnam', return_value=account), \
                patch.object(os, 'setgroups', side_effect=lambda value: calls.append(('groups', value))), \
                patch.object(os, 'setegid', side_effect=lambda value: calls.append(('gid', value))), \
                patch.object(os, 'seteuid', side_effect=lambda value: calls.append(('uid', value))):
            with self.identity._as_home_owner('bob'):
                calls.append('write')
        self.assertEqual(calls, [('groups', []), ('gid', 1002), ('uid', 1001), 'write',
                                 ('uid', 0), ('gid', 0), ('groups', [0, 10])])

    def test_root_without_a_matching_account_does_not_write(self):
        with patch.object(os, 'geteuid', return_value=0), \
                patch.object(self.identity.pwd, 'getpwnam', side_effect=KeyError('bob')), \
                patch.object(os, 'setgroups') as setgroups:
            with self.assertRaises(KeyError):
                with self.identity._as_home_owner('bob'):
                    self.fail('wrote below a home without its owner credentials')
        setgroups.assert_not_called()

    def test_a_home_owned_by_someone_else_is_refused(self):
        with tempfile.TemporaryDirectory() as home:
            picture = os.open(__file__, os.O_RDONLY)
            self.addCleanup(os.close, picture)
            with patch.object(os, 'geteuid', return_value=os.geteuid() + 1):
                with self.assertRaises(OSError):
                    self.identity._write_face(picture, home, 'bob')
            self.assertEqual(os.listdir(home), [])


if __name__ == '__main__':
    unittest.main()
