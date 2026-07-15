#!/usr/bin/env python3
"""
fix-winrm.py — Enable WinRM inside the running Windows VM via QEMU monitor.

Run via: podman exec wootc-e2e-windows python3 /tmp/fix-winrm.py
Or:      just fix-winrm    (which copies and runs this automatically)

Use when the Windows VM is running but WinRM is not enabled (e.g. the disk was
created before the autounattend.xml WinRM commands were added).

What it does:
  1. Opens an elevated PowerShell via Win+R → Ctrl+Shift+Enter (UAC: Left+Enter)
  2. Types PowerShell commands to:
     - Set all network adapters to Private (the #1 WinRM blocker on QEMU)
     - Enable PSRemoting with SkipNetworkProfileCheck
     - Allow Basic auth + AllowUnencrypted
     - Add firewall rule with profile=any
     - Set WinRM to Automatic start
  3. Takes screenshots at each stage to /tmp/fix-winrm-*.ppm

Takes approximately 60-90 seconds.
"""

import socket
import time
import sys

MONITOR = "/run/shm/monitor.sock"


def q(s, cmd, wait=0.3):
    s.send(cmd.encode() + b"\n")
    time.sleep(wait)
    resp = b""
    s.settimeout(0.5)
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
    except Exception:
        pass
    s.settimeout(None)
    return resp.decode("utf-8", errors="replace")


def key(s, k, d=0.1):
    return q(s, f"sendkey {k}", wait=d)


def type_text(s, text, d=0.07):
    """Type a string using QEMU sendkey commands."""
    km = {
        " ": "spc", "-": "minus", "_": "shift-minus",
        "(": "shift-9", ")": "shift-0",
        '"': "shift-apostrophe", "'": "apostrophe",
        "/": "slash", "\\": "backslash", ".": "dot",
        ",": "comma", ":": "shift-semicolon", ";": "semicolon",
        "=": "equal", "+": "shift-equal",
        "!": "shift-1", "@": "shift-2", "#": "shift-3", "$": "shift-4",
        "%": "shift-5", "^": "shift-6", "&": "shift-7", "*": "shift-8",
        "<": "shift-comma", ">": "shift-dot", "?": "shift-slash",
        "{": "shift-bracket_left", "}": "shift-bracket_right",
        "[": "bracket_left", "]": "bracket_right",
        "|": "shift-backslash", "~": "shift-grave_accent", "`": "grave_accent",
    }
    for ch in text:
        if ch in km:
            key(s, km[ch], d)
        elif ch.isupper():
            key(s, f"shift-{ch.lower()}", d)
        elif ch.isdigit() or ch.isalpha():
            key(s, ch.lower(), d)
        else:
            print(f"  [warn] unhandled char {repr(ch)}", flush=True)
        time.sleep(d * 0.4)


def snap(s, name):
    path = f"/tmp/fix-winrm-{name}.ppm"
    q(s, f"screendump {path}", wait=2.0)
    print(f"  [screenshot] {path}", flush=True)


def run_ps_line(s, cmd):
    """Type a PowerShell command line and press Enter, then wait."""
    print(f"  [ps] {cmd[:70]}{'...' if len(cmd) > 70 else ''}", flush=True)
    type_text(s, cmd, d=0.06)
    key(s, "ret", 0.3)
    time.sleep(4.0)


def main():
    # Connect to QEMU monitor
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(MONITOR)
    except FileNotFoundError:
        print(f"ERROR: QEMU monitor not found at {MONITOR}", file=sys.stderr)
        print("Is the container running? (podman ps)", file=sys.stderr)
        sys.exit(1)

    time.sleep(0.3)
    sock.settimeout(0.5)
    try:
        sock.recv(4096)  # drain banner
    except Exception:
        pass
    sock.settimeout(None)

    status = q(sock, "info status").strip()
    print(f"[qemu] {status}", flush=True)
    if "running" not in status:
        print("ERROR: VM is not running", file=sys.stderr)
        sys.exit(1)

    # Step 1: dismiss any open menus
    print("[step 1] Dismissing any open menus...", flush=True)
    key(sock, "esc", 0.5)
    time.sleep(0.5)

    # Step 2: Open Run dialog (Win+R)
    print("[step 2] Opening Run dialog (Win+R)...", flush=True)
    key(sock, "meta_l-r", 0.3)
    time.sleep(2.5)
    snap(sock, "01-run-dialog")

    # Step 3: Type 'powershell' + Ctrl+Shift+Enter (run as admin)
    print("[step 3] Typing powershell + Ctrl+Shift+Enter...", flush=True)
    type_text(sock, "powershell")
    time.sleep(0.5)
    print("  [key] Ctrl+Shift+Enter (elevate)...", flush=True)
    key(sock, "ctrl-shift-ret", 0.3)
    time.sleep(6.0)  # UAC prompt appears
    snap(sock, "02-uac")

    # Step 4: Accept UAC (Left = Yes, Enter = confirm)
    print("[step 4] Accepting UAC (Left + Enter)...", flush=True)
    key(sock, "left", 0.3)
    key(sock, "ret", 0.3)
    time.sleep(6.0)  # PowerShell window opens
    snap(sock, "03-elevated-ps")
    print("  Elevated PowerShell should now be open.", flush=True)

    # Step 5: Type WinRM enable commands
    print("[step 5] Enabling WinRM...", flush=True)

    ps_commands = [
        # CRITICAL: set network to Private BEFORE enabling WinRM
        # QEMU virtio-net shows as Unidentified/Public by default
        "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private",
        # Enable WinRM (creates listener, firewall rule, starts service)
        "Enable-PSRemoting -Force -SkipNetworkProfileCheck",
        # Allow Basic auth over HTTP (required by pywinrm default transport)
        "Set-Item WSMan:\\localhost\\Service\\AllowUnencrypted -Value $true",
        "Set-Item WSMan:\\localhost\\Service\\Auth\\Basic -Value $true",
        "Set-Item WSMan:\\localhost\\Client\\TrustedHosts -Value * -Force",
        # Belt-and-suspenders: explicit firewall rule for all profiles
        'netsh advfirewall firewall add rule name="WinRM 5985" dir=in action=allow protocol=TCP localport=5985 profile=any',
        # Ensure WinRM survives reboot
        "Set-Service WinRM -StartupType Automatic; Restart-Service WinRM -Force",
        # Sentinel
        'Write-Host "WINRM-READY"; netstat -an | Select-String 5985',
    ]

    for cmd in ps_commands:
        run_ps_line(sock, cmd)

    snap(sock, "04-winrm-done")

    print("", flush=True)
    print("[done] WinRM commands sent.", flush=True)
    print("       Screenshots saved to /tmp/fix-winrm-*.ppm inside container.", flush=True)
    print("       Next: run  just fix-routing && just winrm-check", flush=True)

    sock.close()


if __name__ == "__main__":
    main()
