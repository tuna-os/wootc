#!/usr/bin/env python3
"""Check an installed TunaOS against what was seeded on Windows.

usage: migration-check.py <phase2|native> <manifest.tsv>

Runs as root inside the installed system: through the guest agent in Phase 2,
and from wootc-e2e-native-migration.service on the Phase-3 native disk (the
confined agent there cannot read homes). Everything a user owns is read in a
child that has become that user, so "the bytes exist" and "the user can open
them" are one observation.

The manifest is written on Windows by tests/e2e/oem/seed-profile.ps1
("#key=value" header, then category<TAB>profile path<TAB>size<TAB>sha256<TAB>
mtime rows); the harness appends the keys only it knows (linuxUser, password,
hostname, wifi, flatpaksSelected/Deselected, windowsLook, slurp,
slurpWallpaperSha256, renderedWallpaperSha256/Source, seededBeforeInstall,
ippResponder, actions it ran).

Output, one line per observation:
    RESULT<TAB>PASS|FAIL|SKIP<TAB><category><TAB><message>
SKIP is an observation this cell cannot make (named in the message), never a
pass. The last line is "MIGRATION_CHECK_DONE"; its absence means the check
did not run to completion. Exit status is 0 when it completed, whatever it
found.
"""
import base64
import configparser
import contextlib
import ctypes
import ctypes.util
import grp
import hashlib
import json
import os
import pty
import pwd
import re
import select
import shutil
import socket
import subprocess
import sys
import time
import traceback

PHASE = sys.argv[1] if len(sys.argv) > 1 else ""
MANIFEST = sys.argv[2] if len(sys.argv) > 2 else ""
HOST_PRIVATE = "/run/initramfs/wootc-host"
HOST_VIEW = "/run/wootc/host"
NM_CONNECTIONS = "/etc/NetworkManager/system-connections"


def emit(verdict, category, message):
    message = " ".join(str(message).split())
    print(f"RESULT\t{verdict}\t{category}\t{message}", flush=True)


def read_manifest(path):
    header, rows = {}, []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.rstrip("\n").rstrip("\r")
            if not line:
                continue
            if line.startswith("#"):
                key, _, value = line[1:].partition("=")
                header.setdefault(key, []).append(value)
                continue
            category, relative, size, digest, mtime = line.split("\t")
            rows.append({"category": category, "path": relative, "size": int(size),
                         "sha256": digest, "mtime": int(mtime)})
    return {k: v[-1] for k, v in header.items()}, header, rows


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def as_user(account, function, *args):
    """Run function(*args) as the account (uid, gid, supplementary groups)
    in a forked child; return its JSON-serialisable result."""
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        code = 0
        try:
            if os.getuid() != account.pw_uid:  # already the user: nothing to drop
                groups = [g.gr_gid for g in grp.getgrall() if account.pw_name in g.gr_mem]
                os.setgroups(groups)
                os.setgid(account.pw_gid)
                os.setuid(account.pw_uid)
            os.environ.update(HOME=account.pw_dir, USER=account.pw_name, LOGNAME=account.pw_name)
            payload = {"ok": function(*args)}
        except BaseException as error:  # reported to the parent, never raised there
            payload = {"error": f"{type(error).__name__}: {error}"}
            code = 1
        with os.fdopen(write_fd, "w") as stream:
            json.dump(payload, stream)
        os._exit(code)
    os.close(write_fd)
    with os.fdopen(read_fd) as stream:
        raw = stream.read()
    os.waitpid(pid, 0)
    payload = json.loads(raw or '{"error": "child produced nothing"}')
    if "error" in payload:
        raise RuntimeError("as " + account.pw_name + ": " + payload["error"])
    return payload["ok"]


def observe_files(paths):
    """In the user's context: size, sha256, whole-second mtime, owner."""
    seen = {}
    for path in paths:
        try:
            info = os.stat(path)
            seen[path] = {"size": info.st_size, "sha256": sha256(path),
                          "mtime": int(info.st_mtime), "uid": info.st_uid}
        except OSError as error:
            seen[path] = {"error": f"{type(error).__name__}: {error.strerror or error}"}
    return seen


def compare(category, expected, observed, path, check_mtime=True, owner=None):
    got = observed.get(path, {})
    if "error" in got:
        return f"{path}: {got['error']}"
    problems = []
    if got["size"] != expected["size"]:
        problems.append(f"size {got['size']} != {expected['size']}")
    if got["sha256"] != expected["sha256"]:
        problems.append("content differs")
    if check_mtime and got["mtime"] != expected["mtime"]:
        problems.append(f"mtime {got['mtime']} != {expected['mtime']}")
    if owner is not None and got["uid"] != owner:
        problems.append(f"owner uid {got['uid']} != {owner}")
    return f"{path}: " + ", ".join(problems) if problems else None


def run(argv, timeout=120, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kwargs)


def check_rows(category, rows, account, destination, check_mtime=True, owner=None, label=""):
    """Each row's Linux destination (destination(row) → path or list of
    candidate paths) must hold the seeded bytes."""
    if not rows:
        emit("SKIP", category, "nothing seeded for this category")
        return False
    resolved = []
    for row in rows:
        candidates = destination(row)
        candidates = candidates if isinstance(candidates, list) else [candidates]
        resolved.append((row, candidates))
    observed = as_user(account, observe_files, [p for _, c in resolved for p in c])
    failures = []
    for row, candidates in resolved:
        errors = [compare(category, row, observed, c, check_mtime, owner) for c in candidates]
        if all(errors):
            failures.append(errors[0] if len(candidates) == 1 else
                            f"{row['path']}: no candidate matches ({'; '.join(errors)})")
    if failures:
        emit("FAIL", category, f"{len(failures)}/{len(rows)} {label}items differ: " + " | ".join(failures[:6]))
        return False
    emit("PASS", category, f"{len(rows)} {label}items byte-identical"
         + (" with original mtimes" if check_mtime else "") + (" and owned by the user" if owner is not None else ""))
    return True


# ── account ─────────────────────────────────────────────────────────────────
def crypt_verify(password, stored):
    library = ctypes.util.find_library("crypt") or "libcrypt.so.2"
    libcrypt = ctypes.CDLL(library)
    libcrypt.crypt.restype = ctypes.c_char_p
    libcrypt.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    result = libcrypt.crypt(password.encode(), stored.encode())
    return result is not None and result.decode() == stored


def su_login(user, password, nonce):
    """A real PAM password login: an unprivileged process runs su, which
    must authenticate the password through PAM before running anything."""
    su = shutil.which("su") or "/usr/bin/su"
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
            os.execv(su, [su, "-", user, "-c", f"echo {nonce}"])
        finally:
            os._exit(127)
    output, sent, deadline = b"", False, time.monotonic() + 60
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 1)
        if fd in ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if not sent and re.search(rb"assword[^\n]*:\s*$", output):
                os.write(fd, password.encode() + b"\n")
                sent = True
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    return sent and nonce.encode() in output, output.decode(errors="replace")[-300:]


def check_account(header, account):
    category = "account"
    problems = []
    if account.pw_uid < 1000:
        problems.append(f"uid {account.pw_uid} is a system uid")
    home = account.pw_dir
    if not os.path.isdir(home):
        problems.append(f"home {home} missing")
    elif os.stat(home).st_uid != account.pw_uid:
        problems.append(f"home {home} not owned by the user")
    groups = {g.gr_name for g in grp.getgrall() if account.pw_name in g.gr_mem}
    if "wheel" not in groups and "sudo" not in groups:
        problems.append(f"not an administrator (groups: {sorted(groups)})")
    sudo = run(["sudo", "-l", "-U", account.pw_name]) if shutil.which("sudo") else None
    if sudo is None:
        problems.append("sudo missing")
    elif not re.search(r"\(ALL(\s*:\s*ALL)?\)\s+(NOPASSWD:\s*)?ALL", sudo.stdout):
        problems.append("sudo does not grant ALL: " + sudo.stdout.strip()[-160:])
    password = header.get("password", "")
    stored = ""
    with open("/etc/shadow") as stream:
        for line in stream:
            fields = line.split(":")
            if fields[0] == account.pw_name:
                stored = fields[1]
    if not password:
        problems.append("harness gave no password to verify")
    elif not stored.startswith("$"):
        problems.append(f"no usable password hash (shadow field starts {stored[:2]!r})")
    elif not crypt_verify(password, stored):
        problems.append("the Windows-chosen password does not match the account's hash")
    else:
        nonce = "WOOTC_LOGIN_" + os.urandom(6).hex()
        ok, transcript = su_login(account.pw_name, password, nonce)
        if not ok:
            problems.append("PAM login with the chosen password failed: " + transcript)
        bad_ok, _ = su_login(account.pw_name, password + "-wrong", nonce)
        if bad_ok:
            problems.append("PAM accepted a WRONG password: the login check proves nothing")
    if problems:
        emit("FAIL", category, "; ".join(problems))
    else:
        emit("PASS", category, f"{account.pw_name} (uid {account.pw_uid}) is an administrator; "
             "the password chosen on Windows logs in through PAM and a wrong one is refused")
    wanted = header.get("hostname", "")
    if wanted:
        actual = run(["hostnamectl", "hostname", "--static"]).stdout.strip() if shutil.which("hostnamectl") else ""
        if not actual:
            with open("/etc/hostname") as stream:
                actual = stream.read().strip()
        emit("PASS" if actual == wanted else "FAIL", "hostname",
             f"static hostname {actual!r}" + ("" if actual == wanted else f", chosen on Windows {wanted!r}"))
    check_fullname(header, account)


def check_fullname(header, account):
    """The Windows account's full name is the Linux account's GECOS name."""
    wanted = header.get("fullName", "")
    if header.get("seededBeforeInstall") != "1":
        emit("SKIP", "account-fullname", "this cell seeds after the installer collected the account (OEM path)")
        return
    if not wanted:
        emit("FAIL", "account-fullname", "the seed recorded no Windows full name")
        return
    actual = account.pw_gecos.split(",", 1)[0]
    emit("PASS" if actual == wanted else "FAIL", "account-fullname",
         f"GECOS name {actual!r}" + ("" if actual == wanted else f", Windows full name {wanted!r}"))


# ── known folders ───────────────────────────────────────────────────────────
def check_folders(header, rows, account):
    home = account.pw_dir
    files = [r for r in rows if r["category"] == "file"]
    owner = account.pw_uid if PHASE == "native" else None
    # BitLocker: Documents is a persistent copy under ~/Documents/<subdir>.
    subdir = header.get("documentsSubdir", "")

    def destination(row):
        path = row["path"]
        if subdir and path.startswith("Documents/"):
            path = "Documents/" + subdir + path[len("Documents"):]
        return os.path.join(home, path)
    check_rows("folders", files, account, destination, check_mtime=True, owner=owner, label="known-folder ")
    if PHASE == "phase2":
        # The bridge is the user's live Windows folders (SPEC §4.1): binds of
        # the Windows profile, writable by the user.
        unbound = []
        for folder in ("Documents", "Pictures", "Downloads", "Music", "Videos", "Desktop"):
            if folder == header.get("convertedFolder") or (subdir and folder == "Documents"):
                continue
            target = os.path.join(home, folder)
            source = run(["findmnt", "-n", "-o", "SOURCE", "--mountpoint", target]).stdout.strip()
            if not source:
                unbound.append(folder)
        if unbound:
            emit("FAIL", "folders-bridge", "not bridged from Windows: " + ", ".join(unbound))
        else:
            probe = os.path.join(home, "Documents", ".wootc-e2e-write-" + os.urandom(4).hex())

            def write_probe(path):
                with open(path, "w") as stream:
                    stream.write("probe")
                os.unlink(path)
                return True
            try:
                as_user(account, write_probe, probe)
                emit("PASS", "folders-bridge", "all six known folders are bound from the Windows profile and the user can write to Documents")
            except RuntimeError as error:
                emit("FAIL", "folders-bridge", f"the user cannot write to the bridged Documents: {error}")
        # Read-only Windows volume view with the installer's state masked.
        options = run(["findmnt", "-n", "-o", "OPTIONS", "--mountpoint", HOST_VIEW]).stdout.strip()
        problems = []
        if not options:
            problems.append(f"{HOST_VIEW} not mounted")
        elif "ro" not in options.split(","):
            problems.append(f"{HOST_VIEW} is not read-only ({options})")
        masked = os.path.join(HOST_VIEW, "wootc")
        if os.path.isdir(masked) and os.listdir(masked):
            problems.append(f"{masked} exposes installer state: {sorted(os.listdir(masked))[:5]}")
        # A BitLocker profile lives on the encrypted C:, not the storage
        # volume the view shows.
        canary = os.path.join(HOST_VIEW, "Users", header.get("windowsUser", account.pw_name), "Documents", "wootc-e2e-userdata.txt")
        try:
            if not subdir:
                with open(canary) as stream:
                    if header.get("runId", "") not in stream.read():
                        problems.append("the Windows drive view shows a different canary")
        except OSError as error:
            problems.append(f"the Windows drive view cannot read the canary: {error}")
        emit("FAIL" if problems else "PASS", "windows-volume",
             "; ".join(problems) or f"Windows drive readable at {HOST_VIEW}, read-only, installer state masked")
    if header.get("convertedFolder"):
        folder = header["convertedFolder"]
        target = os.path.join(home, folder)
        mounted = run(["findmnt", "-n", "--mountpoint", target]).stdout.strip()
        marker = os.path.join(home, ".config", "wootc", "converted-" + folder)
        problems = []
        if mounted:
            problems.append(f"~/{folder} is still a mount ({mounted.split()[1] if len(mounted.split()) > 1 else mounted})")
        if not os.path.exists(marker):
            problems.append(f"no conversion marker {marker}")
        emit("FAIL" if problems else "PASS", "convert",
             "; ".join(problems) or f"~/{folder} converted to native storage (marker present, no bind); its files are checked under folders")


# ── office, fonts ───────────────────────────────────────────────────────────
def check_office(header, rows, account):
    home = account.pw_dir
    lo = os.path.join(home, ".config/libreoffice/4/user")
    check_rows("office-templates", [r for r in rows if r["category"] == "template"], account,
               lambda r: os.path.join(lo, "template", os.path.basename(r["path"])), check_mtime=False)
    words = [w for w in header.get("dictionary", "").split(",") if w]

    def read_text(path):
        with open(path, encoding="utf-8", errors="replace") as stream:
            return stream.read()
    try:
        text = as_user(account, read_text, os.path.join(lo, "wordbook/standard.dic"))
        missing = [w for w in words if w not in text.split()]
        emit("FAIL" if missing else "PASS", "office-dictionary",
             f"missing words {missing}" if missing else f"all {len(words)} custom dictionary words in LibreOffice standard.dic")
    except RuntimeError as error:
        emit("FAIL", "office-dictionary", str(error))
    try:
        text = as_user(account, read_text, os.path.join(lo, "wootc-office-autocorrect.txt"))
        emit("PASS" if "tehm" in text and "them" in text else "FAIL", "office-autocorrect",
             "AutoCorrect pairs recovered for review" if "tehm" in text else "AutoCorrect review file lacks the seeded pairs")
    except RuntimeError as error:
        emit("FAIL", "office-autocorrect", str(error))
    fonts = [r for r in rows if r["category"] == "font"]
    if check_rows("fonts", fonts, account,
                  lambda r: os.path.join(home, ".local/share/fonts", os.path.basename(r["path"])), check_mtime=False):
        if shutil.which("fc-list"):
            def fc_files():
                return subprocess.run(["fc-list", "--format", "%{file}\n"], capture_output=True, text=True, timeout=120).stdout
            listed = as_user(account, fc_files)
            missing = [r["path"] for r in fonts if os.path.join(home, ".local/share/fonts", os.path.basename(r["path"])) not in listed]
            emit("FAIL" if missing else "PASS", "fonts-usable",
                 f"fontconfig does not list {missing}" if missing else "fontconfig lists the migrated font for the user")
        else:
            emit("SKIP", "fonts-usable", "fc-list not in the image")


# ── apps ────────────────────────────────────────────────────────────────────
def check_apps(header, rows, account):
    home = account.pw_dir

    def read_json(path):
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)
    expected = {"com.visualstudio.code", "org.telegram.desktop", "com.obsproject.Studio", "org.gimp.GIMP",
                "org.videolan.VLC", "com.discordapp.Discord", "com.spotify.Client", "com.slack.Slack",
                "com.valvesoftware.Steam", "org.inkscape.Inkscape", "org.audacityteam.Audacity"}
    try:
        report = as_user(account, read_json, os.path.join(home, ".config/wootc/bridge-apps.json"))
        found = {a.get("flatpak") for a in report.get("apps", [])}
        missing = sorted(expected - found)
        emit("FAIL" if missing else "PASS", "apps-detected",
             f"Windows apps not mapped to Flatpaks: {missing}" if missing else f"{len(expected)} seeded Windows apps mapped to their Flathub IDs")
    except RuntimeError as error:
        emit("FAIL", "apps-detected", f"no app-detection report: {error}")
    check_rows("apps-vscode", [r for r in rows if r["category"] == "vscode"], account,
               lambda r: os.path.join(home, ".config/Code/User", r["path"].split("Code/User/", 1)[1]), check_mtime=False)
    try:
        listed = as_user(account, lambda p: open(p).read().split(), os.path.join(home, ".config/wootc/vscode-extensions.txt"))
        wanted = [e for e in header.get("vscodeExtensions", "").split(",") if e]
        missing = [e for e in wanted if e not in listed]
        emit("FAIL" if missing else "PASS", "apps-vscode-extensions",
             f"extension inventory lacks {missing}" if missing else f"extension inventory lists {wanted}")
    except RuntimeError as error:
        emit("FAIL", "apps-vscode-extensions", str(error))
    check_rows("apps-telegram", [r for r in rows if r["category"] == "telegram"], account,
               lambda r: os.path.join(home, ".var/app/org.telegram.desktop/data/TelegramDesktop/tdata",
                                      r["path"].split("tdata/", 1)[1]), check_mtime=False)
    check_rows("apps-obs", [r for r in rows if r["category"] == "obs"], account,
               lambda r: os.path.join(home, ".var/app/com.obsproject.Studio/config/obs-studio",
                                      r["path"].split("obs-studio/", 1)[1]), check_mtime=False)
    check_flatpaks(header, account)


def check_flatpaks(header, account):
    selected = [x for x in header.get("flatpaksSelected", "").split(",") if x]
    deselected = [x for x in header.get("flatpaksDeselected", "").split(",") if x]
    if not selected and not deselected:
        emit("SKIP", "apps-flatpak-install",
             "this cell chose no apps on Windows (only the native GUI directive keeps and unchecks detected apps)")
        return
    if not shutil.which("flatpak"):
        emit("FAIL", "apps-flatpak-install", "flatpak is not installed in the image")
        return
    problems, ok = [], []
    for app in selected:
        info = run(["flatpak", "info", "--system", app])
        if info.returncode != 0:
            problems.append(f"{app} not installed system-wide ({info.stderr.strip()[-120:]})")
            continue

        def launch(app_id):
            uid = os.getuid()
            env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{uid}") if os.path.isdir(f"/run/user/{uid}") else dict(os.environ)
            result = subprocess.run(["flatpak", "run", "--command=true", app_id], capture_output=True,
                                    text=True, timeout=300, env=env)
            return [result.returncode, result.stderr[-300:]]
        code, stderr = as_user(account, launch, app)
        if code != 0:
            problems.append(f"{app} installed but `flatpak run --command=true` exits {code}: {stderr.strip()}")
        else:
            ok.append(app)
    for app in deselected:
        if run(["flatpak", "info", "--system", app]).returncode == 0:
            problems.append(f"{app} was deselected on Windows but is installed")
    receipt = "/etc/wootc/flatpak-install.json"
    if PHASE == "phase2":
        try:
            with open(receipt) as stream:
                data = json.load(stream)
            unclaimed = [a for a in selected if a not in data.get("installed", [])]
            if unclaimed:
                problems.append(f"install receipt does not list {unclaimed} as installed")
        except (OSError, ValueError) as error:
            problems.append(f"no install receipt {receipt}: {error}")
    emit("FAIL" if problems else "PASS", "apps-flatpak-install",
         "; ".join(problems) or f"{ok} installed system-wide and launch headless for the user; deselected {deselected} absent")


# ── identity, steam ─────────────────────────────────────────────────────────
def check_identity(rows, account):
    home = account.pw_dir
    face = [r for r in rows if r["category"] == "face"]
    check_rows("identity-picture", face, account, lambda r: os.path.join(home, ".face"), check_mtime=False)
    if PHASE == "phase2" and face:
        users = f"/var/lib/AccountsService/users/{account.pw_name}"
        try:
            parser = configparser.RawConfigParser()
            parser.read(users)
            icon = parser.get("User", "Icon", fallback="")
            ok = bool(icon) and os.path.exists(icon) and sha256(icon) == face[0]["sha256"]
            emit("PASS" if ok else "FAIL", "identity-accountsservice",
                 f"login-screen icon {icon} is the Windows account picture" if ok else f"AccountsService Icon={icon!r} is not the Windows picture")
        except (OSError, configparser.Error) as error:
            emit("FAIL", "identity-accountsservice", str(error))


def check_steam(header, account):
    def read_json(path):
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)
    try:
        report = as_user(account, read_json, os.path.join(account.pw_dir, ".config/wootc/bridge-steam.json"))
    except RuntimeError as error:
        emit("FAIL", "steam", f"no Steam bridge report: {error}")
        return
    paths = [lib.get("path", "") for lib in report.get("libraries", [])]
    wanted = [w for w in header.get("steamLibraries", "").split(",") if w]
    missing = [w for w in wanted if not any(p.endswith("/" + w) for p in paths)]
    if missing:
        emit("FAIL", "steam", f"Steam libraries not found on the Windows drive: {missing} (saw {paths})")
    else:
        emit("PASS", "steam", f"both Windows Steam libraries found; registered={report.get('registered')}")
    # Registration needs Linux Steam's own metadata, which exists only after
    # Steam's first start (and then is never rewritten): the bridge record
    # and the chooser the user sees must say how to add each library instead
    # of claiming the games appear (docs/SPEC.md §4.1).
    if report.get("registered"):
        return
    problems = []
    failed = report.get("failed", [])
    if not failed or any("Settings > Storage" not in json.dumps(f) for f in failed):
        problems.append("unregistered libraries without Add Library guidance in bridge-steam.json: " + json.dumps(failed)[:200])
    if PHASE == "phase2":
        def chooser():
            result = subprocess.run(["/var/usrlocal/bin/wootc-manifest", "scan", "--all"], capture_output=True,
                                    text=True, timeout=120, env=dict(os.environ, WOOTC_HOST=HOST_VIEW))
            return result.stdout
        try:
            catalog = json.loads(as_user(account, chooser))
            games = [i for u in catalog.get("users", []) for c in u.get("categories", [])
                     if c.get("id") == "games" for i in c.get("items", [])]
            if not any("Settings > Storage" in i.get("detail", "") for i in games):
                problems.append(f"the migration chooser's Steam entry gives no Add Library step: {json.dumps(games)[:200]}")
        except (RuntimeError, ValueError) as error:
            problems.append(f"migration chooser unreadable: {error}")
    emit("FAIL" if problems else "PASS", "steam-guidance",
         "; ".join(problems) or f"Steam not initialised yet: the bridge record and the migration chooser tell the user "
         f"to add the {len(failed)} Windows libraries in Steam Settings > Storage")


# ── browsers ────────────────────────────────────────────────────────────────
def check_browsers(header, rows, account):
    # The Phase-2 boot bridge imports browsers once per user (no harness step).
    home = account.pw_dir
    chromium = [os.path.join(home, ".config/google-chrome/Default"),
                os.path.join(home, ".var/app/com.google.Chrome/config/google-chrome/Default")]
    check_rows("browsers-chrome", [r for r in rows if r["category"] == "chrome"], account,
               lambda r: [os.path.join(d, os.path.basename(r["path"])) for d in chromium], check_mtime=False)
    edge_rows = [r for r in rows if r["category"] == "edge"]
    edge_targets = chromium + [os.path.join(home, ".config/microsoft-edge/Default"),
                               os.path.join(home, ".var/app/com.microsoft.Edge/config/microsoft-edge/Default")]
    check_rows("browsers-edge", edge_rows, account,
               lambda r: [os.path.join(d, os.path.basename(r["path"])) for d in edge_targets], check_mtime=False)
    firefox = [os.path.join(home, ".mozilla/firefox/windows-import.wootc"),
               os.path.join(home, ".var/app/org.mozilla.firefox/.mozilla/firefox/windows-import.wootc")]
    check_rows("browsers-firefox", [r for r in rows if r["category"] == "firefox"], account,
               lambda r: [os.path.join(d, os.path.basename(r["path"])) for d in firefox], check_mtime=False)


# ── Wi-Fi ───────────────────────────────────────────────────────────────────
def keyfiles():
    found = {}
    directory = NM_CONNECTIONS
    for name in os.listdir(directory) if os.path.isdir(directory) else []:
        parser = configparser.RawConfigParser(interpolation=None)
        parser.optionxform = str
        try:
            parser.read(os.path.join(directory, name), encoding="utf-8")
        except configparser.Error:
            continue
        ssid = parser.get("wifi", "ssid", fallback=None)
        if ssid is not None:
            found[ssid] = {"file": name, "keyMgmt": parser.get("wifi-security", "key-mgmt", fallback="none"),
                           "psk": parser.get("wifi-security", "psk", fallback=""),
                           "mode": os.stat(os.path.join(directory, name)).st_mode & 0o777}
    return found


def check_wifi(header, raw_header):
    profiles = [json.loads(base64.b64decode(v)) for v in raw_header.get("wifi", [])]
    if not profiles:
        emit("SKIP", "wifi", "no Wi-Fi profiles were seeded")
        return
    have = keyfiles()
    known = run(["nmcli", "-t", "-f", "NAME", "connection", "show"]).stdout.splitlines() if shutil.which("nmcli") else []
    problems = []
    for profile in profiles:
        ssid, expect = profile["ssid"], profile["expect"]
        got = have.get(ssid)
        if expect == "skip":
            if got:
                problems.append(f"{ssid!r} ({profile['auth']}) should need a fresh sign-in but was imported")
            continue
        if not got:
            problems.append(f"{ssid!r} not imported")
            continue
        if got["keyMgmt"] != expect:
            problems.append(f"{ssid!r} key-mgmt {got['keyMgmt']} != {expect}")
        if profile.get("key") and got["psk"] != profile["key"]:
            problems.append(f"{ssid!r} passphrase differs")
        if got["mode"] & 0o077:
            problems.append(f"{ssid!r} keyfile is mode {oct(got['mode'])}, readable beyond root")
        if known and got["file"].rsplit(".", 1)[0] not in known and ssid not in known:
            problems.append(f"NetworkManager has not loaded {ssid!r}")
    imported = [p["ssid"] for p in profiles if p["expect"] != "skip"]
    emit("FAIL" if problems else "PASS", "wifi",
         "; ".join(problems) or f"{len(imported)} personal networks with their passphrases are NetworkManager connections; enterprise left for sign-in")
    if PHASE == "phase2":
        leftovers = [p for p in ("/var/lib/wootc/wifi-import",) if os.path.isdir(p) and any(n.endswith(".xml") for n in os.listdir(p))]
        ntfs = os.path.join(HOST_PRIVATE, "wootc/install/wifi")
        if os.path.isdir(ntfs):
            leftovers += [os.path.join(ntfs, n) for n in os.listdir(ntfs) if n.endswith(".xml")]
        emit("FAIL" if leftovers else "PASS", "wifi-cleartext",
             f"cleartext Wi-Fi exports with passphrases remain after import: {leftovers[:4]}" if leftovers
             else "no cleartext Wi-Fi export remains on Linux or the Windows drive")
        if run(["modinfo", "mac80211_hwsim"]).returncode != 0:
            emit("SKIP", "wifi-connect", "association not testable: the VM has no radio and the image lacks mac80211_hwsim")


# ── look, time zone, locale, keyboard ───────────────────────────────────────
def wallpaper_reference(header, rows):
    """The bytes of the wallpaper the Windows user saw → (sha256, problem).

    The seed writes its image as TranscodedWallpaper, but Windows re-renders
    that file from the WallPaper value at the next logon (a JPEG re-encode),
    and the GUI path logs the user on between the seed and the installer.
    The harness re-hashes TranscodedWallpaper when it reads the handoff
    (renderedWallpaperSha256) together with the source Windows recorded for
    it in TranscodedImageCache (renderedWallpaperSource). A re-rendered file
    counts only when Windows rendered it from the seeded image
    (wallpaperSource); without the re-hash the seed's own bytes are the
    reference."""
    seeded = [r for r in rows if r["category"] == "wallpaper"]
    if not seeded:
        return "", ""
    rendered = header.get("renderedWallpaperSha256", "")
    if not rendered or rendered == seeded[0]["sha256"]:
        return seeded[0]["sha256"], ""
    source, wanted = header.get("renderedWallpaperSource", ""), header.get("wallpaperSource", "")
    if not wanted or source.lower() != wanted.lower():
        return "", (f"Windows re-rendered TranscodedWallpaper from {source or 'an unrecorded source'!r}, "
                    f"not the seeded {wanted or 'wallpaper'!r}")
    return rendered, ""


def check_look(header, rows, account):
    if header.get("windowsLook") != "1":
        emit("SKIP", "look", "Windows-Style Mode was not selected on Windows (native shell default: off)")
        return
    slurp = {}
    if header.get("slurp"):
        slurp = json.loads(base64.b64decode(header["slurp"]))
    # Windows-side collection, judged against what the seed set.
    problems = []
    for key, wanted in (("timezone", header.get("timezone")), ("darkMode", header.get("darkMode")),
                        ("accentColor", header.get("accentColor")), ("language", header.get("language"))):
        if wanted and str(slurp.get(key, "")).lower() != wanted.lower():
            problems.append(f"{key}: collected {slurp.get(key)!r}, Windows had {wanted!r}")
    reference, unseeded = wallpaper_reference(header, rows)
    collected = header.get("slurpWallpaperSha256", "")
    if unseeded:
        problems.append(unseeded)
    elif reference and collected != reference:
        problems.append("collected wallpaper is not the Windows wallpaper" if collected else "no wallpaper was collected")
    if PHASE == "phase2":
        emit("FAIL" if problems else "PASS", "look-collected",
             "; ".join(problems) or "Windows time zone, language, dark mode, accent and wallpaper collected")
    zone = os.path.realpath("/etc/localtime")
    wanted = header.get("timezone", "")
    emit("PASS" if zone.endswith("/" + wanted) else "FAIL", "timezone",
         f"/etc/localtime -> {zone}" + ("" if zone.endswith("/" + wanted) else f", Windows used {wanted}"))
    language = header.get("language", "")
    lang = language.replace("-", "_") + ".UTF-8" if language else ""
    current = ""
    if os.path.exists("/etc/locale.conf"):
        with open("/etc/locale.conf") as stream:
            for line in stream:
                if line.startswith("LANG="):
                    current = line.split("=", 1)[1].strip().strip('"')
    emit("PASS" if current == lang else "FAIL", "locale",
         f"LANG={current!r}" + ("" if current == lang else f", Windows language {language} wants {lang}"))
    layout = language.split("-")[0].lower() if language else ""
    keyboard = run(["localectl", "status"]).stdout if shutil.which("localectl") else ""
    vconsole = open("/etc/vconsole.conf").read() if os.path.exists("/etc/vconsole.conf") else ""
    has = re.search(r"X11 Layout:\s*" + re.escape(layout) + r"\b", keyboard) or re.search(r"KEYMAP=\"?" + re.escape(layout), vconsole)
    emit("PASS" if has else "FAIL", "keyboard",
         f"system keyboard layout {layout}" if has else f"system keyboard is not {layout!r}: {' '.join(keyboard.split())[:160]}")
    if PHASE == "phase2":
        check_apply_look(header, rows, account, slurp)


def check_apply_look(header, rows, account, slurp):
    """Run the first-login autostart entry the way a session would, in the
    user's systemd manager, then read the user's settings back."""
    desktop = "/etc/xdg/autostart/wootc-apply-look.desktop"
    try:
        parser = configparser.RawConfigParser(interpolation=None)
        parser.read(desktop)
        command = parser.get("Desktop Entry", "Exec")
    except (configparser.Error, OSError) as error:
        emit("FAIL", "look-applied", f"no autostart entry {desktop}: {error}")
        return
    user = account.pw_name
    run(["loginctl", "enable-linger", user])
    machine = f"{user}@.host"
    for _ in range(30):
        if run(["systemctl", "--user", "-M", machine, "is-system-running"]).stdout.strip() in ("running", "degraded"):
            break
        time.sleep(2)
    env = ["--setenv=XDG_CURRENT_DESKTOP=GNOME"]
    applied = run(["systemd-run", "-M", machine, "--user", "--wait", "--pipe", "--quiet", *env, "/bin/sh", "-c", command], timeout=300)

    def gsettings(schema, key):
        out = run(["systemd-run", "-M", machine, "--user", "--wait", "--pipe", "--quiet", "gsettings", "get", schema, key])
        return out.stdout.strip()
    uri = gsettings("org.gnome.desktop.background", "picture-uri")
    scheme = gsettings("org.gnome.desktop.interface", "color-scheme")
    sources = gsettings("org.gnome.desktop.input-sources", "sources")
    problems = []
    path = uri.strip("'").replace("file://", "")
    reference, unseeded = wallpaper_reference(header, rows)
    if unseeded:
        problems.append(unseeded)
    if not path or not os.path.exists(path) or (reference and sha256(path) != reference):
        problems.append(f"wallpaper {uri} is not the Windows wallpaper")
    if header.get("darkMode") == "true" and "dark" not in scheme:
        problems.append(f"color-scheme {scheme}")
    layout = header.get("language", "-").split("-")[0].lower()
    if f"'{layout}'" not in sources:
        problems.append(f"input sources {sources} lack {layout}")
    if not os.path.exists(os.path.join(account.pw_dir, ".config/wootc/look-applied")):
        problems.append("apply-look left no look-applied marker")
    emit("FAIL" if problems else "PASS", "look-applied",
         "; ".join(problems) + f" (apply-look rc={applied.returncode}: {applied.stdout[-160:]} {applied.stderr[-160:]})" if problems
         else "first-login autostart applied the Windows wallpaper, dark mode and keyboard layout")


# ── developer setup (SSH, git) ──────────────────────────────────────────────
def gitconfig(text):
    """git-config(1) sections → {"section.key": value}, enough to read a
    migrated identity without git (bluefin ships no git package)."""
    values, section = {}, ""
    for line in text.lstrip("\ufeff").splitlines():
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("["):
            section = line.strip("[]").split()[0].lower()
            continue
        key, _, value = line.partition("=")
        values[f"{section}.{key.strip().lower()}"] = value.strip()
    return values


def judge_git(text, header):
    """Problems with a migrated ~/.gitconfig: the Windows identity must be
    there, the Windows-only settings must not."""
    if text is None:
        return ["no ~/.gitconfig"]
    values = gitconfig(text)
    problems = []
    for key, want in (("user.name", header.get("gitName", "")), ("user.email", header.get("gitEmail", ""))):
        if values.get(key) != want:
            problems.append(f"{key} {values.get(key)!r} != {want!r}")
    carried = [k for k in ("credential.helper", "core.autocrlf") if k in values]
    if carried:
        problems.append(f"Windows-only settings carried: {carried}")
    return problems


def check_developer(header, rows, account):
    home = account.pw_dir
    ssh_rows = [r for r in rows if r["category"] in ("ssh-pub", "ssh-config", "ssh-known-hosts")]
    if not ssh_rows:
        emit("SKIP", "dev-ssh", "no SSH files were seeded")
        return
    ssh = os.path.join(home, ".ssh")

    def observe(paths, private):
        seen = {p: os.stat(p).st_mode & 0o777 for p in paths if os.path.exists(p)}
        seen["private-present"] = os.path.exists(private)
        alias = header.get("sshHostAlias", "")
        result = subprocess.run(["ssh", "-G", alias], capture_output=True, text=True, timeout=60)
        seen["ssh-G"] = [result.returncode, result.stdout, result.stderr[-300:]]
        try:
            with open(os.path.join(home, ".gitconfig"), encoding="utf-8") as stream:
                seen["gitconfig"] = stream.read()
        except FileNotFoundError:
            seen["gitconfig"] = None
        return seen
    destinations = [os.path.join(home, r["path"]) for r in ssh_rows]
    private = os.path.join(home, header.get("sshPrivate", ".ssh/id_ed25519"))
    problems = []
    # Bytes, as the user (a file the user cannot open is not migrated).
    check_rows("dev-ssh-files", ssh_rows, account, lambda r: os.path.join(home, r["path"]),
               check_mtime=False, owner=account.pw_uid)
    try:
        seen = as_user(account, observe, [ssh] + destinations, private)
    except RuntimeError as error:
        emit("FAIL", "dev-ssh", str(error))
        emit("FAIL", "dev-git", str(error))
        return
    if os.stat(ssh).st_uid != account.pw_uid or seen.get(ssh, 0o777) & 0o077:
        problems.append(f"~/.ssh is mode {oct(seen.get(ssh, 0))}, not private to the user")
    for row, path in zip(ssh_rows, destinations):
        mode = seen.get(path)
        limit = 0o077 if row["category"] == "ssh-config" else 0o022
        if mode is not None and mode & limit:
            problems.append(f"{row['path']} is mode {oct(mode)}")
    if seen["private-present"]:
        problems.append(f"the private key {header.get('sshPrivate')} was copied (SPEC §4.6: never)")
    code, out, err = seen["ssh-G"]
    wanted = header.get("sshHostName", "")
    if code != 0 or f"hostname {wanted}" not in out.splitlines():
        problems.append(f"`ssh -G {header.get('sshHostAlias')}` as the user does not resolve {wanted} (rc {code}: {err.strip()})")
    if os.path.exists("/sys/fs/selinux/enforce"):
        try:
            label = os.getxattr(ssh, "security.selinux").decode(errors="replace").rstrip("\0")
        except OSError as error:
            label = f"unreadable ({error})"
        if ":ssh_home_t:" not in label:
            problems.append(f"~/.ssh SELinux label {label}, not ssh_home_t")
    try:
        with open(os.path.join(home, ".config/wootc/bridge-developer.json"), encoding="utf-8") as stream:
            record = json.load(stream)
        left = json.dumps(record.get("leftOnWindows", []))
        if os.path.basename(private) not in left:
            problems.append(f"bridge-developer.json does not report the private key left on Windows ({left[:160]})")
    except (OSError, ValueError) as error:
        problems.append(f"no developer bridge record: {error}")
    emit("FAIL" if problems else "PASS", "dev-ssh",
         "; ".join(problems) or "public key, ssh config and known_hosts in ~/.ssh with private modes, ssh resolves the "
         "Windows host alias, the private key stayed on Windows and is reported")
    problems = judge_git(seen["gitconfig"], header)
    emit("FAIL" if problems else "PASS", "dev-git",
         "; ".join(problems) or "~/.gitconfig carries the Windows git identity and none of the Windows-only settings")


# ── printers ────────────────────────────────────────────────────────────────
PRINTER_REPORT = "/var/lib/wootc/printers.json"
IPP_LISTEN = ("127.0.0.2", 631)


def printer_report():
    with open(PRINTER_REPORT, encoding="utf-8") as stream:
        return {p.get("name"): p for p in json.load(stream).get("printers", [])}


def judge_printers(header, report):
    """The importer's per-printer verdicts against what Windows had."""
    expected = {header.get("printerOffice"): "added", header.get("printerLab"): "waiting",
                header.get("printerLabel"): "not-migrated", header.get("printerVirtual"): "not-migrated"}
    problems = []
    for name, status in expected.items():
        if not name:
            continue
        got = report.get(name)
        if not got:
            problems.append(f"{name!r} missing from {PRINTER_REPORT}")
        elif got.get("status") != status:
            problems.append(f"{name!r} is {got.get('status')} ({got.get('reason', '')}), expected {status}")
        elif status != "added" and not got.get("reason"):
            problems.append(f"{name!r} is {status} without a reason the user can read")
    office = report.get(header.get("printerOffice"), {})
    uri = f"ipp://{IPP_LISTEN[0]}:{IPP_LISTEN[1]}/ipp/print"
    if office.get("status") == "added" and office.get("uri") != uri:
        problems.append(f"office printer uri {office.get('uri')!r} != {uri}")
    return problems, office


def check_printer_queue(office):
    problems = []
    queue = office.get("queue", "")
    devices = run(["lpstat", "-v"]).stdout
    if not queue or f"{queue}: ipp://{IPP_LISTEN[0]}:{IPP_LISTEN[1]}/ipp/print" not in devices.replace("device for ", ""):
        problems.append(f"CUPS has no queue {queue!r} at the printer's IPP address: {' '.join(devices.split())[:200]}")
    default = run(["lpstat", "-d"]).stdout.strip()
    if not default.endswith(": " + queue):
        problems.append(f"Windows default printer is not the CUPS default ({default})")
    return problems


def check_printers(header):
    if header.get("seededBeforeInstall") != "1":
        emit("SKIP", "printers", "this cell seeds after the installer collected the printers (OEM path)")
        return
    if not header.get("printerOffice"):
        emit("FAIL", "printers", "the seed recorded no Windows printers")
        return
    responder = None
    spool = "/run/wootc-e2e-ipp-spool"
    try:
        if PHASE == "phase2" and not header.get("ippResponder"):
            emit("FAIL", "printers", "the harness staged no IPP Everywhere responder; the retry cannot be exercised")
            return
        if PHASE == "phase2":
            # A driverless printer at the address Windows used: the boot run
            # found nothing there, so this exercises the importer's retry.
            os.makedirs(spool, exist_ok=True)
            for name in os.listdir(spool):
                os.unlink(os.path.join(spool, name))
            responder = subprocess.Popen([sys.executable, header.get("ippResponder", ""), "--listen",
                                          f"{IPP_LISTEN[0]}:{IPP_LISTEN[1]}", "--spool", spool],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(30):
                with contextlib.suppress(OSError), socket.create_connection(IPP_LISTEN, timeout=1):
                    break
                time.sleep(1)
            retry = run(["systemctl", "start", "wootc-printer-import.service"], timeout=600)
            if retry.returncode != 0:
                emit("FAIL", "printers", f"wootc-printer-import.service failed: {retry.stderr.strip()[-200:]}")
        try:
            report = printer_report()
        except (OSError, ValueError) as error:
            emit("FAIL", "printers", f"no printer report: {error}")
            return
        problems, office = judge_printers(header, report)
        emit("FAIL" if problems else "PASS", "printers",
             "; ".join(problems) or "the network printer became a driverless CUPS queue; the unreachable one waits for a retry, "
             "the cable and virtual printers are reported as not migrated with reasons")
        problems = check_printer_queue(office)
        emit("FAIL" if problems else "PASS", "printers-queue",
             "; ".join(problems) or f"CUPS queue {office.get('queue')} at {office.get('uri')} is the default printer, as on Windows")
        if PHASE == "phase2" and office.get("queue"):
            job = run(["lp", "-d", office["queue"], "-t", "wootc-e2e", "/etc/os-release"], timeout=60)
            delivered = False
            for _ in range(90):
                if os.listdir(spool):
                    delivered = True
                    break
                time.sleep(2)
            emit("PASS" if delivered else "FAIL", "printers-print",
                 "a print job reached the printer through the migrated queue" if delivered
                 else f"no document reached the printer ({job.stdout.strip()} {job.stderr.strip()}; "
                      f"{' '.join(run(['lpstat', '-o', '-l']).stdout.split())[:200]})")
    finally:
        if responder is not None:
            responder.kill()
            responder.wait()


def main():
    if PHASE not in ("phase2", "native") or not MANIFEST:
        print(__doc__, file=sys.stderr)
        return 2
    header, raw_header, rows = read_manifest(MANIFEST)
    account = pwd.getpwnam(header.get("linuxUser", "wootc"))
    for name, check in (("account", lambda: check_account(header, account)),
                        ("folders", lambda: check_folders(header, rows, account)),
                        ("office", lambda: check_office(header, rows, account)),
                        ("apps", lambda: check_apps(header, rows, account)),
                        ("identity", lambda: check_identity(rows, account)),
                        ("steam", lambda: check_steam(header, account)),
                        ("browsers", lambda: check_browsers(header, rows, account)),
                        ("wifi", lambda: check_wifi(header, raw_header)),
                        ("look", lambda: check_look(header, rows, account)),
                        ("developer", lambda: check_developer(header, rows, account)),
                        ("printers", lambda: check_printers(header))):
        try:
            check()
        except Exception:  # one broken check must not hide the others
            emit("FAIL", name, "check crashed: " + traceback.format_exc().strip().splitlines()[-1])
    print("MIGRATION_CHECK_DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
