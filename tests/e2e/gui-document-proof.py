#!/usr/bin/env python3
"""Gate Documents persistence on an ordinary user's real GUI editor save."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def normalized(text):
    return text.replace("\r\n", "\n")


class Proof:
    def __init__(self, transport, seed, marker, evidence, pause=time.sleep, clock=time.monotonic):
        self.transport, self.seed, self.marker = transport, seed, marker
        self.evidence, self.pause, self.clock = evidence, pause, clock
        self.pid = None

    def record(self, stage, value):
        with self.evidence.open("a") as output:
            output.write(json.dumps({"stage": stage, "observed": value}) + "\n")

    def wait(self, stage, action, predicate, seconds=60):
        deadline = self.clock() + seconds
        last = None
        while self.clock() < deadline:
            try:
                last = self.transport.observe(action)
                if predicate(last):
                    self.record(stage, last)
                    return last
            except (RuntimeError, ValueError) as error:
                last = str(error)
            self.pause(1)
        self.record(stage + "-failed", last)
        raise RuntimeError(f"{stage}: required observation absent: {last}")

    def opened(self, stage, edited):
        self.record(stage + "-launch", self.transport.observe("launch"))
        observed = self.wait(stage, "probe", lambda value:
                             value.get("showing") and value.get("editable") and
                             self.seed in value.get("buffer", "") and
                             ((self.marker in value["buffer"]) == edited))
        p = observed["process"]
        if not p["uid"] or Path(p["exe"]).name != "gnome-text-editor":
            raise RuntimeError("Document was not opened by the ordinary user's GNOME editor")
        self.pid = p["pid"]
        self.transport.screenshot(stage)
        return observed

    def focus(self):
        self.record("focus-request", self.transport.observe("focus"))
        self.wait("focused-buffer", "probe", lambda value: value.get("focused") and
                  value.get("process", {}).get("pid") == self.pid and self.seed in value.get("buffer", ""))

    def close(self, stage):
        self.focus()
        self.transport.keys(["ctrl-q"])
        self.wait(stage, "closed", lambda value: not value.get("processes"))
        self.transport.screenshot(stage)

    def run(self, phase):
        tools = self.transport.observe("tooling")
        self.record("actual-guest-tooling", tools)
        if not tools.get("nativeEditor") and "org.gnome.TextEditor" not in tools.get("installedFlatpaks", []):
            raise RuntimeError("Guest lacks an installed GNOME Text Editor; GUI acceptance dependency missing")
        if not tools.get("libatspi"):
            raise RuntimeError("Guest lacks libatspi; GUI accessibility dependency missing")
        self.record("prepare", self.transport.observe("prepare"))
        self.wait("ordinary-user-desktop", "desktop", lambda value:
                  value.get("Active") == "yes" and value.get("Type") in ("x11", "wayland") and
                  value.get("Name") == "wootc" and value.get("uid", 0) > 0, 120)
        before = self.transport.observe("disk")
        self.record("disk-before", before)
        if self.seed not in before["text"]:
            raise RuntimeError("This run's imported document is absent")
        if phase == "edit":
            if self.marker in before["text"]:
                raise RuntimeError("A stale GUI edit marker cannot prove a save")
            self.opened("initial-open", False)
            self.focus()
            keys = ["ctrl-end", "ret"] + ["minus" if ch == "-" else ch for ch in self.marker]
            self.transport.keys(keys)
            self.wait("unsaved-editor-buffer", "probe", lambda value: self.marker in value.get("buffer", ""))
            unsaved = self.transport.observe("disk")
            self.record("disk-before-save", unsaved)
            if unsaved["sha256"] != before["sha256"]:
                raise RuntimeError("Document changed before the GUI Save action")
            self.transport.screenshot("unsaved-buffer")
            self.transport.keys(["ctrl-s"])
            saved = self.wait("saved-file", "disk", lambda value:
                              self.seed in value.get("text", "") and self.marker in value.get("text", "") and
                              value.get("sha256") != before["sha256"])
            buffer = self.wait("saved-editor-buffer", "probe", lambda value:
                               normalized(value.get("buffer", "")) == normalized(saved["text"]))
            self.record("saved-buffer-match", buffer)
            self.transport.screenshot("saved-buffer")
            self.close("editor-closed")
            reopened = self.opened("saved-file-reopened", True)
            if normalized(reopened["buffer"]) != normalized(saved["text"]):
                raise RuntimeError("Reopened GUI buffer does not match the saved bytes")
            self.close("reopened-editor-closed")
            return saved["sha256"]
        reopened = self.opened("restart-file-reopened", True)
        if normalized(reopened["buffer"]) != normalized(before["text"]):
            raise RuntimeError("Restarted GUI buffer does not match the persisted bytes")
        self.close("restart-editor-closed")
        return before["sha256"]


class Transport:
    def __init__(self, runtime, container, path, seed, output):
        self.runtime, self.container, self.path, self.seed, self.output = runtime, container, path, seed, output
        self.guest = "/run/wootc-e2e-gui-document.py"

    def command(self, args, seconds=45):
        result = subprocess.run(args, text=True, capture_output=True, timeout=seconds)
        if result.returncode:
            raise RuntimeError(f"command exited {result.returncode}: {result.stderr.strip()}")
        return result.stdout

    def qga(self, *args):
        return self.command([self.runtime, "exec", self.container, "python3", "/tmp/qga.py", *args])

    def stage(self):
        source = Path(__file__).with_name("gui-document-guest.py")
        local = "/tmp/wootc-e2e-gui-document.py"
        self.command([self.runtime, "cp", str(source), f"{self.container}:{local}"])
        self.qga("write", local, self.guest)
        self.qga("exec", "/bin/chmod", "0644", self.guest)
        identity = self.qga("exec", "/usr/bin/uname", "-s").strip()
        if identity != "Linux":
            raise RuntimeError("GUI editor gate requires positive Linux identity")

    def observe(self, action):
        args = ["/usr/bin/python3", self.guest, action, "--path", self.path, "--seed", self.seed]
        if action in ("probe", "focus"):
            args = ["/usr/sbin/runuser", "-u", "wootc", "--", "/bin/sh", "-c",
                    'u=$(id -u); exec env "XDG_RUNTIME_DIR=/run/user/$u" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$u/bus" "$@"',
                    "sh", *args]
        return json.loads(self.qga("exec", *args))

    def hmp(self, commands):
        code = ('import socket,time,json,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); '
                's.connect("/run/shm/monitor.sock"); time.sleep(.2); s.recv(4096); '
                '\nfor command in json.loads(sys.argv[1]):\n'
                ' s.sendall((command+"\\n").encode()); time.sleep(.1); response=s.recv(4096).decode(errors="replace")\n'
                ' if "error" in response.lower() or "unknown command" in response.lower(): raise RuntimeError(response)\n'
                's.close()')
        self.command([self.runtime, "exec", self.container, "python3", "-c", code, json.dumps(commands)])

    def keys(self, keys):
        if any(not re.fullmatch(r"[a-z0-9-]+", key) for key in keys):
            raise RuntimeError("Unsupported proof keyboard input")
        self.hmp([f"sendkey {key} 40" for key in keys])

    def screenshot(self, stage):
        remote = f"/run/shm/wootc-editor-{stage}.ppm"
        self.command([self.runtime, "exec", self.container, "python3", "-c",
                      "import os,sys; p=sys.argv[1]; os.path.exists(p) and os.unlink(p)", remote])
        self.hmp([f"screendump {remote}"])
        self.command([self.runtime, "cp", f"{self.container}:{remote}", str(self.output / f"{stage}.ppm")])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["edit", "reopen"])
    parser.add_argument("--runtime", default=os.environ.get("WOOTC_CONTAINER_RUNTIME", "podman"))
    parser.add_argument("--container", default="wootc-e2e-windows")
    parser.add_argument("--path", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9-]+", args.run_id):
        raise RuntimeError("Unsupported run identifier")
    args.output.mkdir(parents=True, exist_ok=True)
    marker = "wootc-e2e-gui-edit-" + args.run_id.lower()
    seed = "wootc-e2e-userdata " + args.run_id
    transport = Transport(args.runtime, args.container, args.path, seed, args.output)
    proof = Proof(transport, seed, marker, args.output / "observations.jsonl")
    try:
        transport.stage()
        digest = proof.run(args.phase)
    except Exception as error:
        proof.record("gate-failed", str(error))
        try:
            transport.screenshot("failure")
        except Exception as capture_error:
            proof.record("failure-screenshot-error", str(capture_error))
        raise
    print(json.dumps({"phase": args.phase, "marker": marker, "sha256": digest, "guiProof": True}))


if __name__ == "__main__":
    try:
        main()
    except Exception as failure:
        print(f"GUI Documents proof failed: {failure}", file=sys.stderr)
        sys.exit(1)
