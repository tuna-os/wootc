#!/usr/bin/env python3
"""Controls for the E2E migration checker (tests/e2e/migration-check.py).

The checker decides the gate's migration verdicts, so each comparison must go
red on the regression it exists for: changed bytes, a reset timestamp, a file
owned by the wrong account, a Wi-Fi passphrase that did not survive, an
enterprise network that was imported anyway.
"""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("migration_check", ROOT / "tests/e2e/migration-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def results(function, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        function(*args)
    return [line.split("\t")[1:] for line in out.getvalue().splitlines() if line.startswith("RESULT\t")]


class Manifest(unittest.TestCase):
    def test_header_rows_and_repeated_keys(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".tsv", delete=False) as stream:
            stream.write("#schema=1\n#runId=r1\n#wifi=a\n#wifi=b\n"
                         "file\tDocuments/wootc-e2e-corpus/R\u00e9sum\u00e9 \U0001F41F.txt\t3\tabc\t1552576166\n")
        try:
            header, raw, rows = check.read_manifest(stream.name)
        finally:
            os.unlink(stream.name)
        self.assertEqual(header["runId"], "r1")
        self.assertEqual(raw["wifi"], ["a", "b"])
        self.assertEqual(rows[0]["path"], "Documents/wootc-e2e-corpus/R\u00e9sum\u00e9 \U0001F41F.txt")
        self.assertEqual((rows[0]["size"], rows[0]["mtime"]), (3, 1552576166))


class Files(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        me = pwd.getpwuid(os.getuid())
        self.account = pwd.struct_passwd((me.pw_name, "x", me.pw_uid, me.pw_gid, "", self.home, "/bin/sh"))
        self.path = os.path.join(self.home, "Documents", "deep", "f.bin")
        os.makedirs(os.path.dirname(self.path))
        Path(self.path).write_bytes(b"seeded bytes")
        os.utime(self.path, (1552576166, 1552576166))
        self.row = {"category": "file", "path": "Documents/deep/f.bin", "size": 12,
                    "sha256": check.sha256(self.path), "mtime": 1552576166}

    def verdict(self, **kwargs):
        found = results(check.check_rows, "folders", [self.row], self.account,
                        lambda r: os.path.join(self.home, r["path"]), *kwargs.values())
        return found[0][0]

    def test_identical_file_passes(self):
        self.assertEqual(self.verdict(mtime=True), "PASS")

    def test_reset_timestamp_fails(self):
        os.utime(self.path, None)
        self.assertEqual(self.verdict(mtime=True), "FAIL")
        self.assertEqual(self.verdict(mtime=False), "PASS")

    def test_changed_content_fails(self):
        Path(self.path).write_bytes(b"seeded bytez")
        os.utime(self.path, (1552576166, 1552576166))
        self.assertEqual(self.verdict(mtime=True), "FAIL")

    def test_missing_file_fails(self):
        os.unlink(self.path)
        self.assertEqual(self.verdict(mtime=True), "FAIL")

    def test_wrong_owner_fails(self):
        self.assertEqual(self.verdict(mtime=True, owner=os.getuid() + 1), "FAIL")

    def test_candidate_destinations(self):
        found = results(check.check_rows, "browsers-chrome", [self.row], self.account,
                        lambda r: [os.path.join(self.home, "absent"), os.path.join(self.home, r["path"])])
        self.assertEqual(found[0][0], "PASS")


class WiFi(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp()
        check.NM_CONNECTIONS = self.directory
        self.profiles = [
            {"ssid": "Caf\u00e9 \u2615 5G", "auth": "WPA3SAE", "key": "sae-secret", "expect": "sae"},
            {"ssid": "Corp-Secure", "auth": "WPA2", "key": "", "expect": "skip"},
        ]
        self.header = {"wifi": [base64.b64encode(json.dumps(p).encode()).decode() for p in self.profiles]}

    def keyfile(self, ssid, keymgmt, psk, mode=0o600):
        path = os.path.join(self.directory, ssid + ".nmconnection")
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(f"[connection]\nid={ssid}\ntype=wifi\n\n[wifi]\nssid={ssid}\n\n"
                         f"[wifi-security]\nkey-mgmt={keymgmt}\npsk={psk}\n")
        os.chmod(path, mode)

    def verdict(self):
        return [r for r in results(check.check_wifi, {}, self.header) if r[1] == "wifi"][0]

    def test_imported_with_passphrase_passes(self):
        self.keyfile("Caf\u00e9 \u2615 5G", "sae", "sae-secret")
        self.assertEqual(self.verdict()[0], "PASS")

    def test_lost_passphrase_fails(self):
        self.keyfile("Caf\u00e9 \u2615 5G", "sae", "other")
        self.assertEqual(self.verdict()[0], "FAIL")

    def test_world_readable_keyfile_fails(self):
        self.keyfile("Caf\u00e9 \u2615 5G", "sae", "sae-secret", 0o644)
        self.assertEqual(self.verdict()[0], "FAIL")

    def test_enterprise_import_fails(self):
        self.keyfile("Caf\u00e9 \u2615 5G", "sae", "sae-secret")
        self.keyfile("Corp-Secure", "wpa-eap", "")
        self.assertEqual(self.verdict()[0], "FAIL")

    def test_missing_network_fails(self):
        self.assertEqual(self.verdict()[0], "FAIL")


if __name__ == "__main__":
    unittest.main()
