#!/usr/bin/env python3
"""Small QEMU Guest Agent client used by the Windows E2E runner.

QGA speaks newline-delimited JSON on its virtio-serial socket.  This client
intentionally uses only the standard library so it can run inside Dockur's
container without adding another dependency.
"""

import argparse
import base64
import json
import socket
import sys
import time

SOCKET = "/run/shm/qga.sock"


class GuestAgent:
    def __init__(self, path=SOCKET, timeout=10.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.file = self.sock.makefile("rwb")

    def close(self):
        try:
            self.file.close()
        finally:
            self.sock.close()

    def request(self, execute, arguments=None):
        message = {"execute": execute}
        if arguments is not None:
            message["arguments"] = arguments
        self.file.write((json.dumps(message) + "\n").encode("utf-8"))
        self.file.flush()
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("QGA socket closed")
            response = json.loads(line)
            # QGA can emit asynchronous events; the command response has a
            # return or error member and is the only response callers need.
            if "return" in response:
                return response["return"]
            if "error" in response:
                error = response["error"]
                raise RuntimeError(
                    f"{error.get('class', 'QGA error')}: {error.get('desc', error)}"
                )

    def exec(self, path, args):
        result = self.request(
            "guest-exec",
            {
                "path": path,
                "arg": args,
                "capture-output": True,
            },
        )
        pid = result["pid"]
        while True:
            status = self.request("guest-exec-status", {"pid": pid})
            if status.get("exited"):
                stdout = base64.b64decode(status.get("out-data", ""))
                stderr = base64.b64decode(status.get("err-data", ""))
                return status.get("exitcode", 1), stdout, stderr
            time.sleep(0.25)

    def read_file(self, path):
        handle = self.request("guest-file-open", {"path": path, "mode": "r"})
        chunks = []
        try:
            while True:
                result = self.request(
                    "guest-file-read", {"handle": handle, "count": 1024 * 1024}
                )
                chunks.append(base64.b64decode(result.get("buf-b64", "")))
                if result.get("eof"):
                    break
        finally:
            self.request("guest-file-close", {"handle": handle})
        return b"".join(chunks)

    def write_file(self, local_path, guest_path):
        """Copy a local file to the guest through QGA in bounded chunks."""
        handle = self.request("guest-file-open", {"path": guest_path, "mode": "w"})
        try:
            with open(local_path, "rb") as source:
                while True:
                    chunk = source.read(256 * 1024)
                    if not chunk:
                        break
                    self.request(
                        "guest-file-write",
                        {
                            "handle": handle,
                            "buf-b64": base64.b64encode(chunk).decode("ascii"),
                        },
                    )
        finally:
            self.request("guest-file-close", {"handle": handle})


def powershell(agent, command):
    return agent.exec(
        r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=SOCKET)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ping")
    sub.add_parser("info")
    sub.add_parser("freeze")
    sub.add_parser("thaw")
    ps = sub.add_parser("powershell")
    ps.add_argument("script")
    execute = sub.add_parser("exec")
    execute.add_argument("path")
    execute.add_argument("args", nargs=argparse.REMAINDER)
    read = sub.add_parser("read")
    read.add_argument("path")
    write = sub.add_parser("write")
    write.add_argument("local_path")
    write.add_argument("guest_path")
    args = parser.parse_args()

    agent = GuestAgent(args.socket)
    try:
        if args.command == "ping":
            agent.request("guest-ping")
            return 0
        if args.command == "info":
            print(json.dumps(agent.request("guest-info"), sort_keys=True))
            return 0
        if args.command == "freeze":
            print(agent.request("guest-fsfreeze-freeze"))
            return 0
        if args.command == "thaw":
            print(agent.request("guest-fsfreeze-thaw"))
            return 0
        if args.command == "read":
            sys.stdout.buffer.write(agent.read_file(args.path))
            return 0
        if args.command == "write":
            agent.write_file(args.local_path, args.guest_path)
            return 0
        if args.command == "powershell":
            code, stdout, stderr = powershell(agent, args.script)
            sys.stdout.buffer.write(stdout)
            sys.stderr.buffer.write(stderr)
            return code
        if args.command == "exec":
            code, stdout, stderr = agent.exec(args.path, args.args)
            sys.stdout.buffer.write(stdout)
            sys.stderr.buffer.write(stderr)
            return code
        raise AssertionError(args.command)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"QGA: {error}", file=sys.stderr)
        return 1
    finally:
        agent.close()


if __name__ == "__main__":
    raise SystemExit(main())
