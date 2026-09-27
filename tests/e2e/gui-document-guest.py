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
    return {"pid": pid, "uid": path.stat().st_uid,
            "exe": os.readlink(path / "exe"),
            "command": (path / "cmdline").read_bytes().replace(b"\0", b" ").decode()}


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
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return result


def ancestors(pid):
    result = []
    for _ in range(32):
        if pid <= 1:
            break
        item = process(pid)
        result.append(item)
        status = Path(f"/proc/{pid}/status").read_text()
        pid = int(next(line.split()[1] for line in status.splitlines() if line.startswith("PPid:")))
    return result


def flatpak_app(pid):
    info = configparser.ConfigParser()
    info.read(f"/proc/{pid}/root/.flatpak-info")
    return info.get("Application", "name", fallback="")


def editor_identity(peer_pid, uid):
    peer = process(peer_pid)
    if peer["uid"] != uid:
        return None
    if Path(peer["exe"]).name == "gnome-text-editor":
        return peer
    if Path(peer["exe"]).name != "xdg-dbus-proxy":
        return None
    # Flatpak accessibility connections belong to its D-Bus proxy. Require
    # the real editor in the same specific sandbox wrapper, never merely a
    # shared systemd/session ancestor or an application name in the tree.
    wrappers = {p["pid"] for p in ancestors(peer_pid) if Path(p["exe"]).name in ("flatpak", "bwrap")}
    matches = []
    for candidate in editor_processes():
        if candidate["uid"] != uid or flatpak_app(candidate["pid"]) != "org.gnome.TextEditor":
            continue
        shared = wrappers.intersection(p["pid"] for p in ancestors(candidate["pid"]))
        if shared:
            matches.append({**candidate, "accessibilityPeer": peer,
                            "flatpakApp": "org.gnome.TextEditor", "sharedWrapperPids": sorted(shared)})
    if len(matches) != 1:
        return None
    return matches[0]


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
        candidates, summary = [], []
        deadline = time.monotonic() + 15
        apps = min(self.call("atspi_accessible_get_child_count", root), 64)
        for index in range(apps):
            app = self.call("atspi_accessible_get_child_at_index", root, index)
            pid = self.call("atspi_accessible_get_process_id", app)
            try:
                p = editor_identity(pid, uid)
            except (OSError, ProcessLookupError):
                continue
            if not p:
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
            raise RuntimeError(f"Expected one visible editable document buffer; found {len(candidates)}; tree={summary}")
        return candidates[0]


def disk(path):
    source = Path(path)
    data = source.read_bytes()
    if len(data) > 8192:
        raise RuntimeError("Unexpected fixture document size")
    return {"text": data.decode(), "sha256": hashlib.sha256(data).hexdigest(), "uid": source.stat().st_uid}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["tooling", "prepare", "desktop", "launch", "probe", "focus", "disk", "closed"])
    parser.add_argument("--path", required=True)
    parser.add_argument("--seed", required=True)
    args = parser.parse_args()
    actions = {"tooling": tooling, "prepare": prepare, "desktop": desktop, "launch": lambda: launch(args.path),
               "disk": lambda: disk(args.path), "closed": lambda: {"processes": editor_processes()},
               "probe": lambda: Accessibility().inspect(args.seed), "focus": lambda: Accessibility().inspect(args.seed, True)}
    print(json.dumps(actions[args.action]()))


if __name__ == "__main__":
    main()
