#!/usr/bin/env python3
"""Private-file controls for the detector's actual app-data publication engine."""
import configparser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "payload/migration/wootc-detect-apps"
LIBRARY = ROOT / "payload/migration/lib/wootc_import_safety.py"
SOURCES = {
    "vscode": "AppData/Roaming/Code/User",
    "telegram": "AppData/Roaming/Telegram Desktop/tdata",
    "signal": "AppData/Roaming/Signal",
    "obs": "AppData/Roaming/obs-studio",
    "thunderbird": "AppData/Roaming/Thunderbird",
}
DESTINATIONS = {
    "telegram": ".var/app/org.telegram.desktop/data/TelegramDesktop/tdata",
    "signal": ".var/app/org.signal.Signal/config/Signal",
    "obs": ".var/app/com.obsproject.Studio/config/obs-studio",
    "thunderbird": ".thunderbird",
}


class AppImportSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wootc app import safety ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.host = self.base / "host"
        self.user = self.host / "Users/alice"
        self.home = self.base / "home"
        self.user.mkdir(parents=True)
        self.home.mkdir()
        self.ledger = self.home / ".config/wootc/bridge-apps.json"

    def seed(self, app):
        source = self.user / SOURCES[app]
        source.mkdir(parents=True)
        if app == "vscode":
            (source / "settings.json").write_bytes(b'{"editor.fontSize":14}\n')
            (source / "keybindings.json").write_bytes(b"[]\n")
            (source / "snippets").mkdir()
            (source / "snippets/python.json").write_bytes(b"{}\n")
            (self.user / ".vscode/extensions/ms-python.python-2024.1.0").mkdir(parents=True)
        elif app == "thunderbird":
            (source / "Profiles/example.default").mkdir(parents=True)
            (source / "Profiles/example.default/prefs.js").write_bytes(b"synthetic mail settings\n")
            (source / "profiles.ini").write_text(
                "[Profile0]\nIsRelative=1\nPath=Profiles/example.default\n", encoding="utf-8")
        else:
            (source / "data").write_bytes(app.encode() + b" synthetic profile\n")
            if app == "signal":
                (source / "config.json").write_text('{"key":"synthetic legacy key"}', encoding="utf-8")
        return source

    def snapshot_source(self):
        return {
            str(path.relative_to(self.host)):
                ("link", os.readlink(path)) if path.is_symlink() else
                ("file", path.read_bytes()) if path.is_file() else ("directory",)
            for path in self.host.rglob("*")
        }

    def run_engine(self, apps, prelude="", hook=""):
        source = SCRIPT.read_text(encoding="utf-8")
        engine = source.split("<<'PY' || copy_status=$?\n", 1)[1].rsplit("\nPY", 1)[0]
        if hook:
            engine = engine.replace("\nhome = None\n", "\n" + textwrap.dedent(hook) + "\nhome = None\n", 1)
        entries = [json.dumps({"app": app, "flatpak": "fixture." + app,
                               "session": "relink" if app == "signal" else "portable",
                               "copied": False, "note": "Source data detected."}) for app in apps]
        before = self.snapshot_source()
        command = [sys.executable, "-c", textwrap.dedent(prelude) + "\n" + engine,
                   str(LIBRARY), str(self.host), "alice", str(self.home),
                   str(os.getuid()), str(os.getgid()), *entries]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(self.snapshot_source(), before, "Windows originals changed")
        return result

    def result(self):
        return json.loads(self.ledger.read_text(encoding="utf-8"))

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        value = self.result()
        self.assertEqual(value["status"], "failed")
        self.assertTrue(value["failed"])
        self.assertTrue(any(app.get("state") == "failed" for app in value["apps"]))
        return value

    def test_vscode_preserves_settings_snippets_and_extension_inventory_on_repeat(self):
        self.seed("vscode")
        result = self.run_engine(["vscode"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.result()["status"], "success")
        settings = self.home / ".config/Code/User/settings.json"
        snippets = self.home / ".config/Code/User/snippets/python.json"
        extensions = self.home / ".config/wootc/vscode-extensions.txt"
        self.assertEqual(extensions.read_text(), "ms-python.python\n")
        for path in (settings, snippets, extensions):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        settings.write_bytes(b"Linux settings edits\n")
        snippets.write_bytes(b"Linux snippet edits\n")
        extensions.write_bytes(b"native.extension\n")
        result = self.run_engine(["vscode"])
        self.assertEqual(result.returncode, 0, result.stderr)
        value = self.result()
        self.assertEqual(value["status"], "partial")
        self.assertFalse(value["apps"][0]["copied"])
        self.assertTrue(value["preserved"])
        self.assertEqual(settings.read_bytes(), b"Linux settings edits\n")
        self.assertEqual(snippets.read_bytes(), b"Linux snippet edits\n")
        self.assertEqual(extensions.read_bytes(), b"native.extension\n")

    def test_complete_profiles_publish_once_and_preserve_native_edits_on_repeat(self):
        apps = ("telegram", "signal", "obs", "thunderbird")
        for app in apps:
            self.seed(app)
        first = self.run_engine(apps)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.result()["status"], "success")
        for app in apps:
            with self.subTest(app=app):
                destination = self.home / DESTINATIONS[app]
                self.assertTrue(destination.is_dir())
                (destination / "native-work").write_bytes(b"Linux edits\n")
        parser = configparser.RawConfigParser()
        parser.read(self.home / ".thunderbird/profiles.ini")
        self.assertEqual(parser.get("Profile0", "Path"), "windows-import.wootc")
        second = self.run_engine(apps)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.result()["status"], "partial")
        for app in self.result()["apps"]:
            self.assertFalse(app["copied"])
            self.assertEqual(app["state"], "unchanged")
            self.assertNotIn("opens signed in", app["note"])
            self.assertEqual((self.home / DESTINATIONS[app["app"]] / "native-work").read_bytes(), b"Linux edits\n")

    def test_existing_thunderbird_profile_metadata_is_never_replaced(self):
        self.seed("thunderbird")
        destination = self.home / ".thunderbird"
        destination.mkdir()
        metadata = destination / "profiles.ini"
        metadata.write_bytes(b"native Thunderbird metadata\n")
        result = self.run_engine(["thunderbird"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.result()["status"], "partial")
        self.assertEqual(metadata.read_bytes(), b"native Thunderbird metadata\n")
        self.assertFalse((destination / "windows-import.wootc").exists())

    def test_thunderbird_source_traversal_refuses_before_install(self):
        source = self.seed("thunderbird")
        (source / "profiles.ini").write_text("[Profile0]\nPath=../../outside\nIsRelative=1\n", encoding="utf-8")
        self.assert_failed(self.run_engine(["thunderbird"]))
        self.assertFalse((self.home / ".thunderbird").exists())

    def test_nested_profile_symlink_refuses_and_retains_stage(self):
        source = self.seed("telegram")
        private = self.base / "private-original"
        private.write_bytes(b"private data\n")
        (source / "unsafe-link").symlink_to(private)
        self.assert_failed(self.run_engine(["telegram"]))
        self.assertFalse((self.home / DESTINATIONS["telegram"]).exists())
        self.assertEqual(private.read_bytes(), b"private data\n")
        parent = (self.home / DESTINATIONS["telegram"]).parent
        self.assertTrue(list(parent.glob(".wootc-app-*.partial")))

    def test_vscode_destination_symlink_never_changes_external_file(self):
        self.seed("vscode")
        destination = self.home / ".config/Code/User"
        destination.mkdir(parents=True)
        private = self.base / "native-original"
        private.write_bytes(b"native original\n")
        (destination / "settings.json").symlink_to(private)
        self.assert_failed(self.run_engine(["vscode"]))
        self.assertEqual(private.read_bytes(), b"native original\n")

    def test_encrypted_signal_and_registry_only_apps_do_not_claim_copied_state(self):
        source = self.seed("signal")
        (source / "config.json").write_text('{"encryptedKey":"synthetic"}', encoding="utf-8")
        result = self.run_engine(["signal", "vscode", "thunderbird"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.result()["status"], "unchanged")
        for app in self.result()["apps"]:
            self.assertFalse(app["copied"])
            self.assertEqual(app["state"], "unchanged")
        self.assertFalse((self.home / DESTINATIONS["signal"]).exists())

    def test_failed_later_file_does_not_publish_partial_profile_or_stale_success(self):
        source = self.seed("obs")
        (source / "z-later").write_bytes(b"later file\n")
        self.ledger.parent.mkdir(parents=True)
        self.ledger.write_text('{"status":"success","apps":[{"app":"obs","copied":true}]}')
        hook = """
            original_publish = safety.Home.publish
            def fail_later(self, relative, *args, **kwargs):
                if relative.endswith('/z-later'):
                    raise OSError('injected later file failure')
                return original_publish(self, relative, *args, **kwargs)
            safety.Home.publish = fail_later
        """
        value = self.assert_failed(self.run_engine(["obs"], hook=hook))
        self.assertFalse(value["apps"][0]["copied"])
        self.assertEqual(value["migrated"], [])
        destination = self.home / DESTINATIONS["obs"]
        self.assertFalse(destination.exists())
        stages = list(destination.parent.glob(".wootc-app-*.partial"))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / "data").read_bytes(), b"obs synthetic profile\n")

    def test_profile_directory_appearing_at_rename_is_not_replaced(self):
        self.seed("telegram")
        destination = self.home / DESTINATIONS["telegram"]
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
                    (target / 'native-work').write_bytes(b'racing native work')
                    return original_rename(*arguments)
                result.renameat2 = racing_rename
                return result
            ctypes.CDLL = library
        """
        self.assert_failed(self.run_engine(["telegram"], prelude=prelude))
        self.assertEqual((destination / "native-work").read_bytes(), b"racing native work")
        self.assertFalse((destination / "data").exists())


if __name__ == "__main__":
    unittest.main()
