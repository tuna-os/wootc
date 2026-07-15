#!/usr/bin/env python3
"""Run a PowerShell command via WinRM and print output."""
import winrm, sys, os

host = os.environ.get("WINRM_HOST", "127.0.0.1")
user = os.environ.get("WINRM_USER", "wootc")
passwd = os.environ.get("WINRM_PASS", "wootc-test-123!")
cmd = sys.argv[1] if len(sys.argv) > 1 else "hostname"

s = winrm.Session(
    host,
    auth=(user, passwd),
    transport="basic",
    server_cert_validation="ignore",
)
r = s.run_ps(cmd)
sys.stdout.buffer.write(r.std_out)
if r.std_err:
    sys.stderr.buffer.write(r.std_err)
sys.exit(r.status_code)
