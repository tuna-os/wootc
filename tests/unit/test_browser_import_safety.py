#!/usr/bin/env python3
"""Actual private-file browser copies; identity/mount mocks are not login proof."""
import configparser
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "payload/migration/wootc-import-browser"


class BrowserImportSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wootc browser safety ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.host = self.base / "host"
        self.user = self.host / "Users" / "alice"
        self.home = self.base / "home"
        self.firefox = self.home / ".mozilla/firefox"
        self.chrome = self.home / ".config/google-chrome/Default"
        self.firefox.mkdir(parents=True)
        self.chrome.mkdir(parents=True)
        self.user.mkdir(parents=True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.command("mountpoint", "exit 0")
        account = f"alice:x:{os.getuid()}:{os.getgid()}::{self.home}:/bin/sh"
        self.command("getent", "printf '%s\\n' " + shlex.quote(account))
        self.command("wootc-selection", "exit 0")
        self.env = dict(os.environ, WOOTC_HOST=str(self.host), HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", os.defpath))
        self.ledger = self.home / ".config/wootc/bridge-browser.json"

    def command(self, name, body):
        command = self.bin / name
        command.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        command.chmod(0o755)

    def seed_firefox(self):
        source = self.user / "AppData/Roaming/Mozilla/Firefox"
        profile = source / "Profiles/example.default"
        profile.mkdir(parents=True)
        self.firefox_ini = source / "profiles.ini"
        self.firefox_ini.write_text(
            "[Install0]\nDefault=Profiles/example.default\n"
            "[Profile0]\nIsRelative=1\nPath=Profiles/example.default\n",
            encoding="utf-8")
        (profile / "places.sqlite").write_bytes(b"synthetic Firefox history\n")
        (profile / "logins.json").write_bytes(b'{"synthetic":true}\n')
        (profile / "cache2").mkdir()
        (profile / "cache2/discard").write_bytes(b"excluded cache")
        (profile / "lock").symlink_to("missing process lock")
        return profile

    def seed_chromium(self, app="chrome"):
        vendor = "Google/Chrome" if app == "chrome" else "Microsoft/Edge"
        source = self.user / f"AppData/Local/{vendor}/User Data/Default"
        source.mkdir(parents=True)
        (source / "Bookmarks").write_bytes(app.encode() + b" synthetic bookmarks\n")
        (source / "History").write_bytes(app.encode() + b" synthetic history\n")
        return source

    def source_snapshot(self):
        return {
            str(path.relative_to(self.host)):
                ("link", os.readlink(path)) if path.is_symlink() else
                ("file", path.read_bytes()) if path.is_file() else ("directory",)
            for path in self.host.rglob("*")
        }

    def run_import(self, prelude=None, selected=("firefox", "chrome", "edge")):
        before = self.source_snapshot()
        if prelude is None:
            command = ["bash", str(SCRIPT), "alice"]
        else:
            # Exercise the exact embedded implementation with syscall fault
            # injection; the copier and filesystem operations remain real.
            engine = SCRIPT.read_text(encoding="utf-8").split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
            command = [sys.executable, "-c", textwrap.dedent(prelude) + "\n" + engine,
                       str(self.host), "alice", str(self.home),
                       str(os.getuid()), str(os.getgid()), *selected]
        result = subprocess.run(command, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(self.source_snapshot(), before, "Windows originals changed")
        return result

    def result(self):
        return json.loads(self.ledger.read_text(encoding="utf-8"))

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        ledger = self.result()
        self.assertEqual(ledger["state"], "failed")
        self.assertNotEqual(ledger["status"], "success")
        self.assertFalse(ledger["verified"])
        self.assertTrue(ledger["errors"])
        return ledger

    def test_fresh_firefox_copy_and_registration_then_repeat_preserves_linux_edits(self):
        self.seed_firefox()
        first = self.run_import()
        self.assertEqual(first.returncode, 0, first.stderr)
        destination = self.firefox / "windows-import.wootc"
        self.assertTrue((destination / "places.sqlite").is_file())
        self.assertTrue((destination / "logins.json").is_file())
        self.assertFalse((destination / "cache2").exists())
        self.assertFalse((destination / "lock").is_symlink())
        parser = configparser.RawConfigParser()
        parser.read(self.firefox / "profiles.ini")
        self.assertEqual(parser.get("Profile0", "Path"), "windows-import.wootc")
        self.assertEqual(self.result()["state"], "native")
        self.assertEqual(self.result()["imported"], ["firefox"])
        (destination / "places.sqlite").write_bytes(b"new Linux edits\n")
        metadata = (self.firefox / "profiles.ini").read_bytes()
        self.assert_failed(self.run_import())
        self.assertEqual((destination / "places.sqlite").read_bytes(), b"new Linux edits\n")
        self.assertEqual((self.firefox / "profiles.ini").read_bytes(), metadata)

    def test_existing_firefox_metadata_is_preserved_and_registration_reports_failure(self):
        self.seed_firefox()
        original = b"[Profile9]\nName=Native work\nPath=native.default\nIsRelative=1\n"
        (self.firefox / "profiles.ini").write_bytes(original)
        ledger = self.assert_failed(self.run_import())
        self.assertEqual((self.firefox / "profiles.ini").read_bytes(), original)
        self.assertTrue((self.firefox / "windows-import.wootc/places.sqlite").is_file())
        self.assertEqual(ledger["imported"], ["firefox"])
        self.assertIn("Register windows-import.wootc manually", ledger["errors"][0])

    def test_unsafe_firefox_profile_paths_refuse_before_install(self):
        self.seed_firefox()
        for path in ("../outside", "Profiles/../../outside", "/tmp/outside",
                     "C:\\Users\\other", "Profiles\\..\\outside", "Profiles//example.default"):
            with self.subTest(path=path):
                self.firefox_ini.write_text("[Install0]\nDefault=" + path + "\n", encoding="utf-8")
                self.assert_failed(self.run_import())
                self.assertFalse((self.firefox / "windows-import.wootc").exists())
        self.firefox_ini.write_text(
            "[Profile0]\nPath=Profiles/example.default\nIsRelative=0\n", encoding="utf-8")
        self.assert_failed(self.run_import())

    def test_firefox_profile_symlink_is_not_followed(self):
        profile = self.seed_firefox()
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "private").write_bytes(b"do not import")
        (profile.parent / "linked").symlink_to(outside, target_is_directory=True)
        self.firefox_ini.write_text("[Install0]\nDefault=Profiles/linked\n", encoding="utf-8")
        self.assert_failed(self.run_import())
        self.assertFalse((self.firefox / "windows-import.wootc").exists())
        self.assertEqual((outside / "private").read_bytes(), b"do not import")

    def test_nested_profile_symlink_refuses_whole_profile(self):
        profile = self.seed_firefox()
        outside = self.base / "private"
        outside.write_bytes(b"private original")
        (profile / "unsafe-link").symlink_to(outside)
        self.assert_failed(self.run_import())
        self.assertFalse((self.firefox / "windows-import.wootc").exists())
        self.assertEqual(outside.read_bytes(), b"private original")
        self.assertTrue(list(self.firefox.glob(".wootc-firefox-*.partial")))

    def test_reparse_attribute_on_profile_directory_refuses(self):
        profile = self.seed_firefox()
        try:
            os.setxattr(profile, "user.ntfs.reparse_data", b"synthetic reparse marker")
        except OSError as error:
            self.skipTest("fixture filesystem does not support reparse-marker xattrs: " + str(error))
        self.assert_failed(self.run_import())
        self.assertFalse((self.firefox / "windows-import.wootc").exists())
        self.assertEqual(os.getxattr(profile, "user.ntfs.reparse_data"), b"synthetic reparse marker")

    def test_source_ancestor_symlink_refuses(self):
        source = self.seed_chromium()
        original = source.parent
        relocated = original.with_name("relocated")
        original.rename(relocated)
        original.symlink_to(relocated, target_is_directory=True)
        self.assert_failed(self.run_import())
        self.assertFalse((self.chrome / "Bookmarks").exists())

    def test_chromium_files_copy_exclusively_and_existing_file_is_preserved(self):
        source = self.seed_chromium()
        first = self.run_import()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual((self.chrome / "Bookmarks").read_bytes(), (source / "Bookmarks").read_bytes())
        self.assertEqual(self.result()["state"], "native")
        (self.chrome / "Bookmarks").write_bytes(b"native bookmarks edits\n")
        self.assert_failed(self.run_import())
        self.assertEqual((self.chrome / "Bookmarks").read_bytes(), b"native bookmarks edits\n")

    def test_destination_symlink_preserves_external_data(self):
        self.seed_chromium()
        outside = self.base / "external-target"
        outside.mkdir()
        (outside / "Bookmarks").write_bytes(b"external work")
        self.chrome.rmdir()
        self.chrome.symlink_to(outside, target_is_directory=True)
        self.assert_failed(self.run_import())
        self.assertEqual((outside / "Bookmarks").read_bytes(), b"external work")
        self.assertFalse((outside / "History").exists())

    def test_chrome_edge_destination_collision_is_partial_not_success(self):
        source = self.seed_chromium("chrome")
        self.seed_chromium("edge")
        ledger = self.assert_failed(self.run_import())
        self.assertEqual(ledger["status"], "partial")
        self.assertEqual(ledger["imported"], ["chrome-bookmarks", "chrome-history"])
        self.assertEqual((self.chrome / "Bookmarks").read_bytes(), (source / "Bookmarks").read_bytes())

    def test_file_appearing_at_publication_is_not_overwritten(self):
        self.seed_chromium()
        target = self.chrome / "Bookmarks"
        prelude = f"""
            import os
            from pathlib import Path
            original_link = os.link
            def racing_link(source, destination, **kwargs):
                if destination == "Bookmarks":
                    Path({str(target)!r}).write_bytes(b"racing native work")
                return original_link(source, destination, **kwargs)
            os.link = racing_link
        """
        self.assert_failed(self.run_import(prelude, selected=("chrome",)))
        self.assertEqual(target.read_bytes(), b"racing native work")
        self.assertFalse((self.chrome / "History").exists())

    def test_changed_destination_parent_is_reported_failed(self):
        self.seed_chromium()
        prelude = f"""
            import os
            from pathlib import Path
            original_link = os.link
            def racing_link(source, destination, **kwargs):
                if destination == "Bookmarks":
                    parent = Path({str(self.chrome)!r})
                    parent.rename(parent.with_name("Default-old"))
                    parent.mkdir()
                    (parent / "native-work").write_bytes(b"racing directory")
                return original_link(source, destination, **kwargs)
            os.link = racing_link
        """
        self.assert_failed(self.run_import(prelude, selected=("chrome",)))
        self.assertEqual((self.chrome / "native-work").read_bytes(), b"racing directory")
        self.assertFalse((self.chrome / "Bookmarks").exists())

    def test_firefox_directory_appearing_at_rename_is_not_replaced_or_nested(self):
        self.seed_firefox()
        destination = self.firefox / "windows-import.wootc"
        prelude = f"""
            import ctypes
            from pathlib import Path
            original_library = ctypes.CDLL
            def library(*args, **kwargs):
                result = original_library(*args, **kwargs)
                original_rename = result.renameat2
                original_rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
                original_rename.restype = ctypes.c_int
                def racing_rename(*arguments):
                    target = Path({str(destination)!r})
                    target.mkdir()
                    (target / "native-work").write_bytes(b"racing Firefox work")
                    return original_rename(*arguments)
                result.renameat2 = racing_rename
                return result
            ctypes.CDLL = library
        """
        self.assert_failed(self.run_import(prelude, selected=("firefox",)))
        self.assertEqual((destination / "native-work").read_bytes(), b"racing Firefox work")
        self.assertFalse((destination / "places.sqlite").exists())
        self.assertTrue(list(self.firefox.glob(".wootc-firefox-*.partial")))

    def test_partial_write_retains_stage_and_replaces_stale_success_with_failure(self):
        self.seed_firefox()
        self.ledger.parent.mkdir(parents=True)
        self.ledger.write_text('{"state":"native","imported":["firefox"]}', encoding="utf-8")
        prelude = """
            import errno
            import os
            original_write = os.write
            def interrupted_write(fd, data):
                if os.readlink('/proc/self/fd/' + str(fd)).endswith('/places.sqlite'):
                    original_write(fd, data[:3])
                    raise OSError(errno.ENOSPC, 'injected full destination')
                return original_write(fd, data)
            os.write = interrupted_write
        """
        ledger = self.assert_failed(self.run_import(prelude, selected=("firefox",)))
        self.assertEqual(ledger["imported"], [])
        self.assertFalse((self.firefox / "windows-import.wootc").exists())
        stages = list(self.firefox.glob(".wootc-firefox-*.partial"))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / "places.sqlite").read_bytes(), b"syn")

    def test_category_selection_clears_stale_result_without_copying(self):
        self.seed_firefox()
        self.ledger.parent.mkdir(parents=True)
        self.ledger.write_text('{"state":"native","imported":["firefox"]}', encoding="utf-8")
        self.command("wootc-selection", "exit 1")
        result = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.result()["state"], "unchanged")
        self.assertEqual(self.result()["imported"], [])
        self.assertFalse((self.firefox / "windows-import.wootc").exists())


if __name__ == "__main__":
    unittest.main()
