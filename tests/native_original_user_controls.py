#!/usr/bin/env python3
"""Actual Windows token reads only; no operation session or installation."""
import hashlib
import json
import os
import secrets
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=False)
sources = ["app/native_peer_windows.go", "app/native_pipe_windows.go", "app/native_original_user_windows.go", "app/native_original_user_windows_test.go", "app/native_knownfolders_windows.go", "app/native_install_authorization_windows.go", "app/install_contract.go", "app/native_handshake.go", "app/knownfolders_contract.go", "app/knownfolders_windows.go", "app/go.mod", "app/go.sum", "tests/native_original_user_controls.py", ".github/workflows/native-original-user.yml"]
sha = lambda data: hashlib.sha256(data).hexdigest()
go = Path(shutil.which("go"))
receipt = {"schemaVersion": 1, "scope": "actual retained token/profile/binding reads and refusal controls; same-user elevated interactive capture and token-owned folder consumption; alternative-administrator pipe capture with a disposable standard user in the same interactive session (no UAC prompt); no shell-driven UAC journey, operation authorization or installation proof", "runId": os.environ["GITHUB_RUN_ID"], "runAttempt": os.environ["GITHUB_RUN_ATTEMPT"], "testedHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(), "checkoutSources": {p: sha((root / p).read_bytes()) for p in sources}, "gitSources": {p: sha(subprocess.check_output(["git", "show", "HEAD:" + p], cwd=root)) for p in sources}, "tools": {"go": sha(go.read_bytes()), "python": sha(Path(sys.executable).read_bytes())}, "accepted": False, "tests": []}
# A disposable standard user is the original person for the alternative-
# administrator control. Its secret travels only through process environments.
account = "wootc_alt_" + secrets.token_hex(4)
fixture_env = dict(os.environ, WOOTC_ALT_NAME=account, WOOTC_ALT_SECRET=secrets.token_hex(16) + "aA1!")
powershell = shutil.which("powershell")
def ps(script):
    return subprocess.run([powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], env=fixture_env, capture_output=True, text=True, timeout=120)
created = ps("$ErrorActionPreference='Stop';$c=[ADSI]\"WinNT://$env:COMPUTERNAME,computer\";$u=$c.Create('User',$env:WOOTC_ALT_NAME);$u.SetPassword($env:WOOTC_ALT_SECRET);$u.Put('Description','wootc disposable original-user fixture');$u.SetInfo();([Security.Principal.NTAccount]::new($env:WOOTC_ALT_NAME)).Translate([Security.Principal.SecurityIdentifier]).Value")
if created.returncode != 0:
    raise SystemExit("Disposable standard-user fixture refused: " + created.stderr)
fixture_env.update(WOOTC_ORIGINAL_ALT_USER=account, WOOTC_ORIGINAL_ALT_PASSWORD=fixture_env["WOOTC_ALT_SECRET"], WOOTC_ORIGINAL_ALT_SID=created.stdout.strip().splitlines()[-1])
receipt["fixtureAccountSid"] = fixture_env["WOOTC_ORIGINAL_ALT_SID"]
try:
    completed = subprocess.run([str(go), "test", "-json", "-count=1", "-timeout=90s", "native_peer_windows.go", "native_pipe_windows.go", "native_original_user_windows.go", "native_original_user_windows_test.go", "native_knownfolders_windows.go", "knownfolders_contract.go", "native_install_authorization_windows.go", "install_contract.go", "native_handshake.go"], cwd=root / "app", env=fixture_env, capture_output=True, timeout=180)
    for name, data in [("stdout.raw", completed.stdout), ("stderr.raw", completed.stderr)]:
        (out / name).write_bytes(data)
        receipt[name] = sha(data)
    receipt["exitCode"] = completed.returncode
    for line in completed.stdout.splitlines():
        event = json.loads(line)
        if event.get("Test") and event.get("Action") in ("pass", "fail", "skip"):
            receipt["tests"].append({"name": event["Test"], "outcome": event["Action"]})
    required = {"TestNativeOriginalUserRejectsMissingClosedOrAlternativeAdministrator", "TestNativeOriginalUserCannotReplaceObservedTokenWithPeerFields", "TestNativeOriginalUserActualTokenProfileAndBindingReadOnly", "TestNativeOriginalUserActualInteractiveCapture", "TestNativeOriginalUserActualRestrictedInteractiveCriterion", "TestNativeOriginalUserActualKnownFolderCollector", "TestNativeOriginalUserActualOneShotInstallConsent", "TestNativeOriginalUserActualAlternativeAdministratorPipe"}
    passed = {test["name"] for test in receipt["tests"] if test["outcome"] == "pass"}
    receipt["accepted"] = completed.returncode == 0 and required <= passed and all(t["outcome"] == "pass" for t in receipt["tests"])
finally:
    removed = ps("$ErrorActionPreference='Stop';$sid=([Security.Principal.NTAccount]::new($env:WOOTC_ALT_NAME)).Translate([Security.Principal.SecurityIdentifier]).Value;([ADSI]\"WinNT://$env:COMPUTERNAME,computer\").Delete('User',$env:WOOTC_ALT_NAME);Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid | Remove-CimInstance")
    receipt["fixtureAccountRemoved"] = removed.returncode == 0
    if removed.returncode != 0:
        receipt["accepted"] = False
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
if not receipt["accepted"]:
    raise SystemExit("Actual token binding controls refused; inspect retained raw evidence")
print("Actual token binding reads/refusals passed; no install authorization")
