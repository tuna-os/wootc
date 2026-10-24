#!/usr/bin/env python3
"""Observe a real GNOME editor through AT-SPI. Never write the document."""
import argparse
import configparser
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import time

USER = "wootc"


def run(args):
    return subprocess.check_output(args, text=True, timeout=20).strip()


def user_command(args):
    uid = pwd.getpwnam(USER).pw_uid
    if not uid:
        raise RuntimeError("Desktop user must not be root")
    return ["runuser", "-u", USER, "--", "env", f"XDG_RUNTIME_DIR=/run/user/{uid}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus"] + args


def desktop():
    for line in run(["loginctl", "list-sessions", "--no-legend"]).splitlines():
        session = line.split()[0]
        values = dict(line.split("=", 1) for line in run([
            "loginctl", "show-session", session, "-p", "Name", "-p", "Active", "-p", "Type", "-p", "Class"
        ]).splitlines())
        if (values.get("Name") == USER and values.get("Active") == "yes" and
                values.get("Class") == "user" and values.get("Type") in ("wayland", "x11")):
            return {"session": session, **values, "uid": pwd.getpwnam(USER).pw_uid}
    raise RuntimeError("No active ordinary-user graphical desktop")


def prepare():
    if not Path("/etc/gdm").is_dir():
        raise RuntimeError("GNOME GDM fixture required for this editor gate")
    try:
        desktop()
    except RuntimeError:
        conf = configparser.ConfigParser()
        conf.optionxform = str
        path = Path("/etc/gdm/custom.conf")
        conf.read(path)
        if not conf.has_section("daemon"):
            conf.add_section("daemon")
        conf.set("daemon", "AutomaticLoginEnable", "True")
        conf.set("daemon", "AutomaticLogin", USER)
        with path.open("w") as output:
            conf.write(output)
        run(["systemctl", "restart", "display-manager"])
    return {"prepared": True}


def process(pid):
    path = Path(f"/proc/{pid}")
    def lifetime():
        fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            raise RuntimeError("Editor process has exited")
        return fields[19]
    started = lifetime()
    value = {"pid": pid, "uid": path.stat().st_uid, "startTicks": started,
             "exe": os.readlink(path / "exe"),
             "command": (path / "cmdline").read_bytes().replace(b"\0", b" ").decode()}
    if lifetime() != started:
        raise RuntimeError("Process identity changed during observation")
    return value


def opaque_process(pid):
    path = Path(f"/proc/{pid}")
    started = (path / "stat").read_text().rsplit(")", 1)[1].split()[19]
    name = next(line.split(None, 1)[1].strip() for line in (path / "status").read_text().splitlines()
                if line.startswith("Name:"))
    return {"pid": pid, "uid": path.stat().st_uid, "startTicks": started, "exe": None, "name": name}


def process_name(snapshot):
    return Path(snapshot["exe"]).name if snapshot.get("exe") else snapshot.get("name", "")


def verify_process(snapshot):
    if snapshot.get("exe") is None and "name" in snapshot:
        current = opaque_process(snapshot["pid"])
        if any(current[key] != snapshot[key] for key in ("pid", "uid", "startTicks", "name")):
            raise RuntimeError("Editor process exited or changed during observation")
        return
    current = process(snapshot["pid"])
    if any(current[key] != snapshot[key] for key in ("pid", "uid", "startTicks", "exe")):
        raise RuntimeError("Editor process exited or changed during observation")



def editor_processes():
    uid = pwd.getpwnam(USER).pw_uid
    result = []
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            p = process(int(path.name))
            if p["uid"] == uid and Path(p["exe"]).name == "gnome-text-editor":
                result.append(p)
        except (OSError, ProcessLookupError, RuntimeError):
            pass
    return result


def ancestors(pid):
    result = []
    for _ in range(32):
        if pid <= 1:
            break
        try:
            item = process(pid)
        except PermissionError:
            # A non-dumpable ancestor (a sandbox wrapper, or the user's
            # systemd manager, which dropped root) hides its exe. Its pid,
            # start time, owner and name stay readable, and a shared wrapper
            # is matched on the exact (pid, start time) instance anyway.
            if not result:
                raise
            item = opaque_process(pid)
        result.append(item)
        status = Path(f"/proc/{pid}/status").read_text()
        verify_process(item)
        pid = int(next(line.split()[1] for line in status.splitlines() if line.startswith("PPid:")))
    return result


def flatpak_app(pid):
    info = configparser.ConfigParser()
    info.read(f"/proc/{pid}/root/.flatpak-info")
    return info.get("Application", "name", fallback="")


def unix_socket_peers(pid_a, pid_b):
    """Connected Unix socket pairs with one end in pid_a and the other in pid_b.

    Read from the kernel's socket table (`ss -xpn`), so a pair is a real
    established connection between those two exact processes.
    """
    owners, peer_of = {}, {}
    for line in run(["ss", "-xpnH"]).splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[5].isdigit() or not fields[7].isdigit():
            continue
        inode, peer = int(fields[5]), int(fields[7])
        if peer:
            peer_of[inode] = peer
        owners[inode] = {int(m) for m in re.findall(r"pid=(\d+)", " ".join(fields[8:]))}
    return sorted((inode, peer) for inode, peer in peer_of.items()
                  if pid_a in owners.get(inode, ()) and pid_b in owners.get(peer, ()))


def editor_identity(peer_pid, uid, why=None):
    # why, when given, collects the reason a peer is rejected. It is
    # diagnostic only: it never relaxes a check.
    note = why.append if why is not None else (lambda _reason: None)
    peer = process(peer_pid)
    if peer["uid"] != uid:
        note(f"peer uid {peer['uid']} is not {uid}")
        return None
    if Path(peer["exe"]).name == "gnome-text-editor":
        verify_process(peer)
        return peer
    if Path(peer["exe"]).name != "xdg-dbus-proxy":
        note(f"peer exe {peer['exe']} is neither the editor nor xdg-dbus-proxy")
        return None
    # Flatpak accessibility connections belong to its D-Bus proxy. Require
    # the real editor bound to that exact proxy: either both inside the same
    # specific sandbox wrapper instance, or the editor holding an established
    # Unix socket whose other end is the proxy. Never merely a shared
    # systemd/session ancestor or an application name in the tree.
    wrappers = {(p["pid"], p["startTicks"]) for p in ancestors(peer_pid) if process_name(p) in ("flatpak", "bwrap")}
    matches = []
    editors = editor_processes()
    if not editors:
        note("proxy peer, but no readable gnome-text-editor process for the desktop user")
    for candidate in editors:
        app = flatpak_app(candidate["pid"])
        if candidate["uid"] != uid or app != "org.gnome.TextEditor":
            note(f"editor pid {candidate['pid']} has flatpak app {app!r}")
            continue
        shared = wrappers.intersection((p["pid"], p["startTicks"]) for p in ancestors(candidate["pid"]))
        sockets = [] if shared else unix_socket_peers(candidate["pid"], peer_pid)
        if shared or sockets:
            matches.append({**candidate, "accessibilityPeer": peer, "flatpakApp": "org.gnome.TextEditor",
                            "sharedWrapperIdentities": sorted(shared), "proxySocketPairs": sockets[:8]})
    if len(matches) != 1:
        note(f"proxy peer wrappers {sorted(wrappers)} and socket pairs matched {len(matches)} editor sandboxes")
        return None
    verify_process(peer)
    verify_process(matches[0])
    return matches[0]


def a11y_context():
    """Diagnostic facts for a probe that found no editor on the AT-SPI desktop."""
    uid = pwd.getpwnam(USER).pw_uid
    facts = {"proxies": [], "editors": []}
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            if path.stat().st_uid != uid:
                continue
            argv = (path / "cmdline").read_bytes().split(b"\0")
            name = Path(argv[0].decode(errors="replace")).name
        except OSError:
            continue
        if name == "xdg-dbus-proxy":
            facts["proxies"].append([a.decode(errors="replace") for a in argv if b"a11y" in a or b"at-spi" in a or a.startswith(b"unix:")][:6])
        elif name == "gnome-text-editor":
            entry = {"pid": int(path.name)}
            try:
                env = dict(item.split(b"=", 1) for item in (path / "environ").read_bytes().split(b"\0") if b"=" in item)
                entry.update({key: env.get(key.encode(), b"").decode(errors="replace")
                              for key in ("AT_SPI_BUS_ADDRESS", "GTK_A11Y", "NO_AT_BRIDGE", "DBUS_SESSION_BUS_ADDRESS")})
            except OSError as error:
                entry["environ"] = f"{type(error).__name__}: {error}"
            try:
                entry["flatpakApp"] = flatpak_app(int(path.name))
            except OSError as error:
                entry["flatpakApp"] = f"{type(error).__name__}: {error}"
            facts["editors"].append(entry)
    return facts


def tooling():
    apps = run(user_command(["flatpak", "list", "--app", "--columns=application"])) if shutil.which("flatpak") else ""
    try:
        C.CDLL("libatspi.so.0")
        accessibility = True
    except OSError:
        accessibility = False
    return {"nativeEditor": Path("/usr/bin/gnome-text-editor").is_file(),
            "installedFlatpaks": apps.splitlines(), "libatspi": accessibility,
            "gdm": Path("/etc/gdm").is_dir()}


EDITOR_APP = "org.gnome.TextEditor"
EDITOR_REMOTE = "flathub"
INSTALL_UNIT = "wootc-e2e-editor-install"


def system_flatpaks():
    return run(["flatpak", "list", "--system", "--app", "--columns=application"]).splitlines()


def provision():
    """Install GNOME Text Editor as a system Flatpak when the image ships none.

    The catalog GNOME images that reach Phase 2 ship no editor in /usr; their
    own system-flatpaks list names this app, but nothing installs it on a
    bootc install. This only provides the dependency: every observation the
    gate makes afterwards is unchanged.
    """
    if Path("/usr/bin/gnome-text-editor").is_file():
        return {"started": False, "source": "image"}
    if not shutil.which("flatpak"):
        raise RuntimeError("Guest has no flatpak; the editor cannot be installed")
    if EDITOR_APP in system_flatpaks():
        return {"started": False, "source": "flatpak"}
    remotes = run(["flatpak", "remotes", "--system", "--columns=name"]).splitlines()
    if EDITOR_REMOTE not in remotes:
        raise RuntimeError(f"Guest has no system {EDITOR_REMOTE} remote; the editor cannot be installed")
    # A oneshot unit started without blocking: the download outlives one
    # guest-agent request, and its result stays observable afterwards.
    run(["systemd-run", "--no-block", f"--unit={INSTALL_UNIT}", "--property=Type=oneshot",
         "--property=RemainAfterExit=yes",
         "flatpak", "install", "--system", "--noninteractive", "--assumeyes", EDITOR_REMOTE, EDITOR_APP])
    return {"started": True, "unit": INSTALL_UNIT, "remote": EDITOR_REMOTE, "app": EDITOR_APP}


def provisioned():
    state = dict(line.split("=", 1) for line in run([
        "systemctl", "show", INSTALL_UNIT, "-p", "ActiveState", "-p", "SubState", "-p", "Result",
        "-p", "ExecMainStatus"
    ]).splitlines() if "=" in line)
    return {"unit": state, "installed": EDITOR_APP in system_flatpaks(),
            "finished": state.get("ActiveState") in ("active", "failed")}


def launch(path):
    desktop()
    if editor_processes():
        raise RuntimeError("An existing editor process would make the document proof ambiguous")
    run(user_command(["gsettings", "set", "org.gnome.desktop.interface", "toolkit-accessibility", "true"]))
    run(user_command(["gsettings", "set", "org.gnome.desktop.input-sources", "sources", "[('xkb', 'us')]"]))
    if Path("/usr/bin/gnome-text-editor").is_file():
        editor = ["/usr/bin/gnome-text-editor", path]
    else:
        installed = run(user_command(["flatpak", "list", "--app", "--columns=application"]))
        if "org.gnome.TextEditor" not in installed.splitlines():
            raise RuntimeError("No installed GNOME Text Editor; editor gate cannot run")
        editor = ["flatpak", "run", "--env=GTK_A11Y=atspi", "org.gnome.TextEditor", path]
    unit = f"wootc-gui-document-{time.monotonic_ns()}"
    run(user_command(["systemd-run", "--user", "--collect", f"--unit={unit}",
                      "--setenv=GTK_A11Y=atspi", *editor]))
    return {"launched": editor, "unit": unit, "desktop": desktop()}


class GError(C.Structure):
    _fields_ = [("domain", C.c_uint), ("code", C.c_int), ("message", C.c_char_p)]


class Accessibility:
    # Official at-spi2-core API; the states are AtspiStateType enum values.
    EDITABLE, FOCUSED, SHOWING = 7, 12, 25

    def __init__(self):
        self.lib = C.CDLL("libatspi.so.0")
        self.glib = C.CDLL("libglib-2.0.so.0")
        self.glib.g_free.argtypes = [C.c_void_p]
        self.glib.g_error_free.argtypes = [C.POINTER(GError)]
        self.fn("atspi_init", C.c_int, [])
        self.fn("atspi_set_timeout", None, [C.c_int, C.c_int])
        if self.lib.atspi_init() != 0:
            raise RuntimeError("Accessibility bus could not initialize")
        self.lib.atspi_set_timeout(1000, 1000)
        ptr, err = C.c_void_p, C.POINTER(C.POINTER(GError))
        for name, result, args in [
            ("atspi_get_desktop", ptr, [C.c_int]),
            ("atspi_accessible_get_child_count", C.c_int, [ptr, err]),
            ("atspi_accessible_get_child_at_index", ptr, [ptr, C.c_int, err]),
            ("atspi_accessible_get_name", ptr, [ptr, err]),
            ("atspi_accessible_get_process_id", C.c_uint, [ptr, err]),
            ("atspi_accessible_get_text_iface", ptr, [ptr]),
            ("atspi_text_get_text", ptr, [ptr, C.c_int, C.c_int, err]),
            ("atspi_accessible_get_state_set", ptr, [ptr]),
            ("atspi_state_set_contains", C.c_int, [ptr, C.c_int]),
            ("atspi_accessible_get_component_iface", ptr, [ptr]),
            ("atspi_component_grab_focus", C.c_int, [ptr, err]),
        ]:
            self.fn(name, result, args)

    def fn(self, name, result, args):
        f = getattr(self.lib, name)
        f.restype, f.argtypes = result, args

    def call(self, name, *args):
        error = C.POINTER(GError)()
        value = getattr(self.lib, name)(*args, C.byref(error))
        if error:
            message = error.contents.message.decode(errors="replace")
            self.glib.g_error_free(error)
            raise RuntimeError(message)
        return value

    def string(self, name, *args):
        value = self.call(name, *args)
        if not value:
            return ""
        try:
            return C.string_at(value).decode()
        finally:
            self.glib.g_free(value)

    def inspect(self, seed, focus=False):
        root = self.lib.atspi_get_desktop(0)
        if not root:
            raise RuntimeError("Accessibility desktop absent")
        uid = os.getuid()
        if not uid or uid != pwd.getpwnam(USER).pw_uid:
            raise RuntimeError("Accessibility probe is not the ordinary desktop user")
        candidates, summary, rejected = [], [], []
        deadline = time.monotonic() + 15
        apps = min(self.call("atspi_accessible_get_child_count", root), 64)
        for index in range(apps):
            app = self.call("atspi_accessible_get_child_at_index", root, index)
            pid = self.call("atspi_accessible_get_process_id", app)
            why = []
            try:
                p = editor_identity(pid, uid, why)
            except (OSError, ProcessLookupError) as error:
                p, why = None, why + [f"{type(error).__name__}: {error}"]
            if not p:
                rejected.append({"app": self.string("atspi_accessible_get_name", app), "pid": pid, "why": why})
                continue
            queue = [(app, [])]
            visited = 0
            while queue and visited < 256 and time.monotonic() < deadline:
                node, ancestors = queue.pop(0)
                visited += 1
                name = self.string("atspi_accessible_get_name", node)
                states = self.lib.atspi_accessible_get_state_set(node)
                flags = {key: bool(self.lib.atspi_state_set_contains(states, value))
                         for key, value in [("editable", self.EDITABLE), ("focused", self.FOCUSED), ("showing", self.SHOWING)]}
                summary.append({"name": name, **flags})
                if flags["editable"] and flags["showing"]:
                    text = self.lib.atspi_accessible_get_text_iface(node)
                    if text:
                        content = self.string("atspi_text_get_text", text, 0, -1)
                        if seed in content and len(content) <= 8192:
                            if focus:
                                component = self.lib.atspi_accessible_get_component_iface(node)
                                if not component or not self.call("atspi_component_grab_focus", component):
                                    raise RuntimeError("Editor buffer could not receive keyboard focus")
                            candidates.append({"process": p, "buffer": content, "ancestors": ancestors + [name], **flags})
                children = min(self.call("atspi_accessible_get_child_count", node), 64)
                queue += [(self.call("atspi_accessible_get_child_at_index", node, i), ancestors + [name]) for i in range(children)]
        if len(candidates) != 1:
            raise RuntimeError(f"Expected one visible editable document buffer; found {len(candidates)}; "
                               f"tree={summary}; rejected={rejected[:16]}; context={a11y_context()}")
        verify_process(candidates[0]["process"])
        if "accessibilityPeer" in candidates[0]["process"]:
            verify_process(candidates[0]["process"]["accessibilityPeer"])
        return candidates[0]


def disk(path):
    source = Path(path)
    data = source.read_bytes()
    if len(data) > 8192:
        raise RuntimeError("Unexpected fixture document size")
    return {"text": data.decode(), "sha256": hashlib.sha256(data).hexdigest(), "uid": source.stat().st_uid}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["tooling", "provision", "provisioned", "prepare", "desktop", "launch", "probe", "focus", "disk", "closed"])
    parser.add_argument("--path", required=True)
    parser.add_argument("--seed", required=True)
    args = parser.parse_args()
    actions = {"tooling": tooling, "provision": provision, "provisioned": provisioned, "prepare": prepare, "desktop": desktop, "launch": lambda: launch(args.path),
               "disk": lambda: disk(args.path), "closed": lambda: {"processes": editor_processes()},
               "probe": lambda: Accessibility().inspect(args.seed), "focus": lambda: Accessibility().inspect(args.seed, True)}
    print(json.dumps(actions[args.action]()))


if __name__ == "__main__":
    main()
