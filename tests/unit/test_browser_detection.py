#!/usr/bin/env python3
"""Read-only browser discovery fixtures, not proof of authenticated sessions."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "payload" / "migration"
DETECTOR = MIGRATION / "wootc-detect-apps"
PLUGIN = MIGRATION / "plugins.d" / "browsers" / "bin" / "detect"
MANIFEST = MIGRATION / "wootc-manifest"
BROWSER_PATHS = {
    "firefox": "AppData/Roaming/Mozilla/Firefox",
    "chrome": "AppData/Local/Google/Chrome/User Data",
    "edge": "AppData/Local/Microsoft/Edge/User Data",
}


class BrowserDetectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.host = self.base / "host"
        self.user = self.host / "Users" / "alice"
        self.home = self.base / "home"
        self.user.mkdir(parents=True)
        self.home.mkdir()
        self.env = dict(os.environ, WOOTC_HOST=str(self.host),
                        WOOTC_WIN_USER="alice", WOOTC_WIN_USER_DIR=str(self.user),
                        HOME=str(self.home))
        self.env.pop("WOOTC_PLUGINS_DIR", None)

    def seed_browser(self, app):
        source = self.user / BROWSER_PATHS[app]
        source.mkdir(parents=True)
        if app == "firefox":
            (source / "profiles.ini").write_text(
                "[Profile0]\nIsRelative=1\nPath=Profiles/example.default\n",
                encoding="utf-8")
        else:
            # Presence must not require Default/Bookmarks: named profiles and
            # installations without bookmarks remain discoverable.
            profile = source / "Profile 2"
            profile.mkdir()
            (profile / "History").write_bytes(b"synthetic history")
        return source

    def seed_exports(self, entries, relative="wootc/install/slurp/session/exports.json"):
        ledger = self.host / relative
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(json.dumps(entries), encoding="utf-8")
        return ledger

    def run_json(self, command):
        result = subprocess.run(command, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def detect(self):
        canonical = self.run_json([str(DETECTOR), "--detect-browsers"])
        plugin = self.run_json([sys.executable, str(PLUGIN)])
        self.assertEqual(plugin, canonical)
        return canonical

    def snapshot(self):
        return {
            str(path.relative_to(self.base)):
                (path.stat().st_mode, path.stat().st_mtime_ns,
                 path.read_bytes() if path.is_file() else None)
            for path in self.base.rglob("*")
        }

    def test_absent_browsers(self):
        result = self.detect()
        self.assertEqual(result, {"detected": False, "items": [], "summary": ""})

    def test_firefox_directory_without_profiles_ini_is_absent(self):
        (self.user / BROWSER_PATHS["firefox"]).mkdir(parents=True)
        self.assertFalse(self.detect()["detected"])

    def test_each_browser_present_has_source_and_honest_session(self):
        for app in BROWSER_PATHS:
            with self.subTest(app=app):
                source = self.seed_browser(app)
                result = self.detect()
                items = {item["id"]: item for item in result["items"]}
                self.assertIn(app, items)
                item = items[app]
                self.assertEqual(item["source"], str(source))
                self.assertEqual(item["session"], "portable" if app == "firefox" else "signin")
                self.assertFalse(item["copied"])
                self.assertGreater(item["fileCount"], 0)
                self.assertGreater(item["sizeBytes"], 0)
        self.assertEqual([item["id"] for item in self.detect()["items"]],
                         ["firefox", "chrome", "edge"])

    def test_staged_chromium_is_not_portable(self):
        for app in BROWSER_PATHS:
            self.seed_browser(app)
        self.seed_exports([{"app": app, "state": "staged"} for app in ("chrome", "edge")])
        items = {item["id"]: item for item in self.detect()["items"]}
        self.assertEqual(items["firefox"]["session"], "portable")
        for app in ("chrome", "edge"):
            self.assertEqual(items[app]["session"], "staged")
            self.assertIn("until target import is verified", items[app]["note"])

    def test_source_imported_entries_never_establish_signed_in_state(self):
        for app in ("chrome", "edge"):
            self.seed_browser(app)
        self.seed_exports([{"app": app, "state": "imported"} for app in ("chrome", "edge")])
        for item in self.detect()["items"]:
            self.assertEqual(item["session"], "signin")
            self.assertNotIn("opens signed in", item["note"])

    def test_invalid_export_records_are_not_session_evidence(self):
        self.seed_browser("chrome")
        ledger = self.seed_exports([])
        for content in ("not json", "{}", '[null, "staged", {"app":"chrome","state":"portable"}]'):
            with self.subTest(content=content):
                ledger.write_text(content, encoding="utf-8")
                self.assertEqual(self.detect()["items"][0]["session"], "signin")

    def test_alternative_staging_path_and_existing_path_precedence(self):
        self.seed_browser("edge")
        self.seed_exports([{"app": "edge", "state": "staged"}],
                          "install/slurp/session/exports.json")
        self.assertEqual(self.detect()["items"][0]["session"], "staged")
        self.seed_exports([{"app": "edge", "state": "imported"}])
        self.assertEqual(self.detect()["items"][0]["session"], "signin")

    def test_registry_only_browser_coverage_uses_same_authoritative_path(self):
        registry = self.host / "wootc/install/programs.json"
        registry.parent.mkdir(parents=True)
        registry.write_text(json.dumps({"apps": [
            {"displayName": "Mozilla Firefox"}, {"displayName": "Google Chrome"},
            {"displayName": "Microsoft Edge"}, {"displayName": "Visual Studio Code"},
        ]}), encoding="utf-8")
        self.seed_exports([{"app": "chrome", "state": "staged"}])
        items = self.detect()["items"]
        self.assertEqual([item["id"] for item in items], ["firefox", "chrome", "edge"])
        for item in items:
            self.assertEqual(item["evidence"], "registry")
            self.assertEqual(item["session"], "signin")
            self.assertEqual(item["fileCount"], 0)
            self.assertFalse(item["copied"])
        self.seed_browser("firefox")
        self.assertEqual(self.detect()["items"][0]["evidence"], "profile")
        self.assertEqual(self.detect()["items"][0]["session"], "portable")

    def test_explicit_windows_profile_path_is_retained(self):
        self.user = self.base / "custom profile's directory"
        self.env["WOOTC_WIN_USER_DIR"] = str(self.user)
        source = self.seed_browser("chrome")
        self.assertEqual(self.detect()["items"][0]["source"], str(source))
        self.env.pop("WOOTC_WIN_USER_DIR")
        self.assertFalse(self.detect()["detected"])

    def test_detection_never_runs_mutating_importer_or_writes_state(self):
        for app in BROWSER_PATHS:
            self.seed_browser(app)
        for relative in ("AppData/Roaming/Code/User", "AppData/Roaming/Telegram Desktop/tdata",
                         "AppData/Roaming/obs-studio"):
            (self.user / relative).mkdir(parents=True)
        self.seed_exports([{"app": "chrome", "state": "staged"}])
        binaries = self.base / "bin"
        binaries.mkdir()
        marker = self.base / "forbidden-calls"
        for name in ("mountpoint", "getent", "cp", "chown", "install", "mkdir", "mv", "rm", "sort"):
            executable = binaries / name
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$WOOTC_FORBIDDEN_CALLS"\nexit 99\n',
                                  encoding="utf-8")
            executable.chmod(0o755)
        self.env["PATH"] = str(binaries) + os.pathsep + self.env.get("PATH", os.defpath)
        self.env["WOOTC_FORBIDDEN_CALLS"] = str(marker)
        before = self.snapshot()
        self.detect()
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(marker.exists())
        self.assertFalse((self.home / ".config").exists())

    def test_manifest_fallback_uses_identical_detector_records(self):
        self.seed_browser("edge")
        self.seed_exports([{"app": "edge", "state": "staged"}])
        expected = self.detect()
        with mock.patch.dict(os.environ, self.env, clear=True):
            manifest = runpy.run_path(str(MANIFEST))
            detected, items, summary = manifest["builtin_cat_browsers"]("alice")
        self.assertEqual((detected, items, summary),
                         (expected["detected"], expected["items"], expected["summary"]))

    def test_higher_precedence_browser_plugin_is_not_bypassed(self):
        self.seed_browser("chrome")
        plugins = self.base / "enterprise"
        plugin = plugins / "browsers"
        (plugin / "bin").mkdir(parents=True)
        (plugin / "plugin.json").write_text(json.dumps({
            "schemaVersion": 1, "id": "browsers", "name": "Enterprise browsers",
            "category": "browsers", "version": "1.0.0",
        }), encoding="utf-8")
        executable = plugin / "bin" / "detect"
        executable.write_text('#!/bin/sh\necho \'{"detected":false,"items":[],"summary":"enterprise policy"}\'\n',
                              encoding="utf-8")
        executable.chmod(0o755)
        self.env["WOOTC_PLUGINS_DIR"] = str(plugins)
        result = self.run_json([sys.executable, str(MANIFEST), "scan", "alice"])
        browsers = next(category for category in result["users"][0]["categories"]
                        if category["id"] == "browsers")
        self.assertFalse(browsers["present"])
        self.assertEqual(browsers["items"], [])
        self.assertEqual(browsers["summary"], "enterprise policy")


if __name__ == "__main__":
    unittest.main()
