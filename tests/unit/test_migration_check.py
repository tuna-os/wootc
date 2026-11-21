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
from unittest import mock

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

def account_for(home, gecos=""):
    me = pwd.getpwuid(os.getuid())
    return pwd.struct_passwd((me.pw_name, "x", me.pw_uid, me.pw_gid, gecos, home, "/bin/sh"))


class FullName(unittest.TestCase):
    header = {"fullName": "Zo\u00eb O'Brien-\u00c5berg 1a2b3c", "seededBeforeInstall": "1"}

    def verdict(self, gecos, header=None):
        return results(check.check_fullname, header or self.header, account_for("/nonexistent", gecos))[0]

    def test_windows_full_name_is_the_gecos_name(self):
        self.assertEqual(self.verdict("Zo\u00eb O'Brien-\u00c5berg 1a2b3c,,,")[0], "PASS")

    def test_missing_or_mangled_name_fails(self):
        for gecos in ("", "Zo O'Brien-berg 1a2b3c", "Zo\u00eb O\\'Brien-\u00c5berg 1a2b3c"):
            self.assertEqual(self.verdict(gecos)[0], "FAIL", gecos)

    def test_oem_cell_skips(self):
        self.assertEqual(self.verdict("", {"fullName": "x"})[0], "SKIP")


class Developer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.account = account_for(self.home)
        ssh = Path(self.home, ".ssh")
        ssh.mkdir(mode=0o700)
        files = {"ssh-pub": (".ssh/id_ed25519.pub", b"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA wootc-e2e\n", 0o644),
                 "ssh-config": (".ssh/config", b"Host wootc-e2e-git\n  HostName git.example.org\n  User git\n", 0o600),
                 "ssh-known-hosts": (".ssh/known_hosts", b"git.example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA\n", 0o644)}
        self.rows = []
        for category, (relative, data, mode) in files.items():
            path = Path(self.home, relative)
            path.write_bytes(data)
            path.chmod(mode)
            self.rows.append({"category": category, "path": relative, "size": len(data),
                              "sha256": check.sha256(path), "mtime": 0})
        Path(self.home, ".gitconfig").write_text("[user]\n\tname = Zo\u00eb\n\temail = z@example.org\n", encoding="utf-8")
        Path(self.home, ".config/wootc").mkdir(parents=True)
        Path(self.home, ".config/wootc/bridge-developer.json").write_text(
            json.dumps({"status": "success", "leftOnWindows": [{"path": ".ssh/id_ed25519", "reason": "private key"}]}))
        self.header = {"sshPrivate": ".ssh/id_ed25519", "sshHostAlias": "wootc-e2e-git",
                       "sshHostName": "git.example.org", "gitName": "Zo\u00eb", "gitEmail": "z@example.org"}
        # Real ssh finds ~/.ssh/config through the passwd home, which a test
        # cannot point at a temp tree; this stand-in reads $HOME (set by
        # as_user) and refuses a group/world-writable config as ssh does.
        bin_dir = Path(self.home, "bin")
        bin_dir.mkdir()
        fake = bin_dir / "ssh"
        fake.write_text("#!/bin/sh\n[ \"$1\" = -G ] || exit 2\ncfg=\"$HOME/.ssh/config\"\n"
                        "[ -r \"$cfg\" ] || exit 255\n"
                        "case $(stat -c %a \"$cfg\") in *[2367]?|*[2367]) echo \"Bad owner or permissions on $cfg\" >&2; exit 255;; esac\n"
                        "awk -v h=\"$2\" '$1==\"Host\"{m=($2==h)} m&&$1==\"HostName\"{print \"hostname \"$2}' \"$cfg\"\n")
        fake.chmod(0o755)
        path = os.environ["PATH"]
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{path}"
        self.addCleanup(os.environ.__setitem__, "PATH", path)

    def verdicts(self):
        found = results(check.check_developer, self.header, self.rows, self.account)
        return {category: verdict for verdict, category, _ in found}

    def test_public_material_and_identity_pass(self):
        self.assertEqual(self.verdicts(), {"dev-ssh-files": "PASS", "dev-ssh": "PASS", "dev-git": "PASS"})

    def test_copied_private_key_fails(self):
        Path(self.home, ".ssh/id_ed25519").write_bytes(b"-----BEGIN OPENSSH PRIVATE KEY-----\n")
        self.assertEqual(self.verdicts()["dev-ssh"], "FAIL")

    def test_ntfs_modes_fail(self):
        # A copy that kept NTFS's permissive modes: ssh refuses the config.
        Path(self.home, ".ssh/config").chmod(0o666)
        self.assertEqual(self.verdicts()["dev-ssh"], "FAIL")
        Path(self.home, ".ssh/config").chmod(0o600)
        Path(self.home, ".ssh").chmod(0o755)
        self.assertEqual(self.verdicts()["dev-ssh"], "FAIL")

    def test_windows_only_git_settings_fail(self):
        Path(self.home, ".gitconfig").write_text(
            "[user]\n\tname = Zo\u00eb\n\temail = z@example.org\n[credential]\n\thelper = manager\n", encoding="utf-8")
        self.assertEqual(self.verdicts()["dev-git"], "FAIL")
        Path(self.home, ".gitconfig").unlink()
        self.assertEqual(self.verdicts()["dev-git"], "FAIL")


class Printers(unittest.TestCase):
    header = {"printerOffice": "Office Laser 1a2b3c", "printerLab": "Lab Printer 1a2b3c",
              "printerLabel": "Label Printer 1a2b3c", "printerVirtual": "Microsoft Print to PDF"}

    def report(self, **changes):
        entries = {
            "Office Laser 1a2b3c": {"status": "added", "queue": "Office_Laser_1a2b3c", "uri": "ipp://127.0.0.2:631/ipp/print"},
            "Lab Printer 1a2b3c": {"status": "waiting", "reason": "no driverless printer answered at 192.0.2.44"},
            "Label Printer 1a2b3c": {"status": "not-migrated", "reason": "connected by cable"},
            "Microsoft Print to PDF": {"status": "not-migrated", "reason": "Windows-only virtual printer"},
        }
        for name, entry in changes.items():
            entries[name.replace("_", " ")] = entry
        return entries

    def test_expected_statuses_pass(self):
        problems, office = check.judge_printers(self.header, self.report())
        self.assertEqual(problems, [])
        self.assertEqual(office["queue"], "Office_Laser_1a2b3c")

    def test_unmigrated_network_printer_fails(self):
        problems, _ = check.judge_printers(self.header, self.report(
            Office_Laser_1a2b3c={"status": "waiting", "reason": "unreachable"}))
        self.assertTrue(problems)

    def test_silent_or_dropped_printers_fail(self):
        entries = self.report(Label_Printer_1a2b3c={"status": "not-migrated"})
        self.assertTrue(check.judge_printers(self.header, entries)[0])
        entries = self.report()
        del entries["Microsoft Print to PDF"]
        self.assertTrue(check.judge_printers(self.header, entries)[0])

    def test_wrong_address_fails(self):
        problems, _ = check.judge_printers(self.header, self.report(
            Office_Laser_1a2b3c={"status": "added", "queue": "q", "uri": "ipp://192.0.2.1:631/ipp/print"}))
        self.assertTrue(problems)


class SuLogin(unittest.TestCase):
    """The PAM login runs su on a guest seeded in German (probe 44889931801)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.su = os.path.join(self.dir, "su")
        # Prompts like pam_unix in the caller's locale, then runs the command
        # only for the right password.
        Path(self.su).write_text(
            "#!/bin/sh\n"
            'case "${LC_ALL:-${LC_MESSAGES:-$LANG}}" in de*) printf "Passwort: " ;; *) printf "Password: " ;; esac\n'
            "read -r pw\n"
            '[ "$pw" = right ] && /bin/sh -c "$4"\n'
            "exit 0\n")
        os.chmod(self.su, 0o755)
        self.saved = {k: os.environ.get(k) for k in ("LANG", "LC_ALL", "LC_MESSAGES")}
        os.environ.update(LANG="de_DE.UTF-8", LC_ALL="de_DE.UTF-8", LC_MESSAGES="de_DE.UTF-8")

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_german_guest_locale_still_logs_in(self):
        ok, transcript = check.su_login("wootc", "right", "NONCE_1", su=self.su, drop_privileges=False)
        self.assertTrue(ok, transcript)

    def test_wrong_password_is_still_refused(self):
        ok, transcript = check.su_login("wootc", "wrong", "NONCE_2", su=self.su, drop_privileges=False)
        self.assertFalse(ok, transcript)

class Look(unittest.TestCase):
    """The wallpaper half of look-collected, with probe 44889931801's hashes:
    the seed wrote 485e… as TranscodedWallpaper, Windows re-rendered it at
    the autologon that followed, and the installer collected 544b…."""
    seeded = "485e817d6e234b9e8ddbd2db0cd5f88c8c9b5f5d377cebc0686de462ec2669f8"
    rendered = "544bc5e2d86b77ddade28307a46890e55405c20b1b2b833cf1cbafd5cf2db70a"
    source = "C:\\Users\\wootc\\Pictures\\wootc-e2e-wallpaper.jpg"
    rows = [{"category": "wallpaper", "path": "AppData/Roaming/Microsoft/Windows/Themes/TranscodedWallpaper",
             "size": 7434, "sha256": seeded, "mtime": 1795258649}]

    def verdict(self, collected, **header):
        header = {"windowsLook": "1", "wallpaperSource": self.source, "slurpWallpaperSha256": collected, **header}
        with mock.patch.object(check, "PHASE", "phase2"), mock.patch.object(check, "check_apply_look"):
            out = results(check.check_look, header, self.rows, account_for("/nonexistent"))
        return next(r for r in out if r[1] == "look-collected")

    def test_wallpaper_windows_rerendered_from_the_seed_is_the_reference(self):
        self.assertEqual(self.verdict(self.rendered, renderedWallpaperSha256=self.rendered,
                                      renderedWallpaperSource=self.source.upper())[0], "PASS")

    def test_rerendered_from_another_image_fails(self):
        for source in ("C:\\Windows\\Web\\Wallpaper\\Windows\\img0.jpg", ""):
            verdict = self.verdict(self.rendered, renderedWallpaperSha256=self.rendered, renderedWallpaperSource=source)
            self.assertEqual(verdict[0], "FAIL", source)
            self.assertIn("re-rendered", verdict[2])

    def test_collected_bytes_must_be_what_windows_rendered(self):
        for collected in (self.seeded, "0" * 64, ""):
            self.assertEqual(self.verdict(collected, renderedWallpaperSha256=self.rendered,
                                          renderedWallpaperSource=self.source)[0], "FAIL", collected)

    def test_without_a_rerender_the_seeded_bytes_are_the_reference(self):
        self.assertEqual(self.verdict(self.seeded)[0], "PASS")
        self.assertEqual(self.verdict(self.seeded, renderedWallpaperSha256=self.seeded)[0], "PASS")
        self.assertEqual(self.verdict(self.rendered)[0], "FAIL")
        self.assertEqual(self.verdict("")[2], "no wallpaper was collected")


if __name__ == "__main__":
    unittest.main()
