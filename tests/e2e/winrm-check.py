#!/usr/bin/env python3
"""Probe WinRM — exit 0 if working, 1 if not."""
import winrm, sys, os

host = os.environ.get("WINRM_HOST", "127.0.0.1")
user = os.environ.get("WINRM_USER", "wootc")
passwd = os.environ.get("WINRM_PASS", "wootc-test-123!")

try:
    s = winrm.Session(
        host,
        auth=(user, passwd),
        transport="basic",
        server_cert_validation="ignore",
    )
    r = s.run_ps("Write-Host ok; $PSVersionTable.PSVersion")
    print("WinRM OK, status:", r.status_code)
    print(r.std_out.decode())
    sys.exit(r.status_code)
except Exception as e:
    print(f"WinRM FAILED: {e}")
    sys.exit(1)
