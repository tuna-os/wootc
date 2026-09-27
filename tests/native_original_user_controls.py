#!/usr/bin/env python3
"""Actual Windows token reads only; no operation session or installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=False)
sources = ["app/native_peer_windows.go", "app/native_original_user_windows.go", "app/native_original_user_windows_test.go", "app/native_knownfolders_windows.go", "app/knownfolders_contract.go", "app/knownfolders_windows.go", "app/go.mod", "app/go.sum", "tests/native_original_user_controls.py", ".github/workflows/native-original-user.yml"]
sha = lambda data: hashlib.sha256(data).hexdigest()
go = Path(shutil.which("go"))
receipt = {"schemaVersion": 1, "scope": "actual retained token/profile/binding reads and refusal controls; same-user elevated interactive capture and token-owned folder consumption; no unelevated caller/UAC/alternate-admin journey, operation authorization or installation proof", "runId": os.environ["GITHUB_RUN_ID"], "runAttempt": os.environ["GITHUB_RUN_ATTEMPT"], "testedHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(), "checkoutSources": {p: sha((root / p).read_bytes()) for p in sources}, "gitSources": {p: sha(subprocess.check_output(["git", "show", "HEAD:" + p], cwd=root)) for p in sources}, "tools": {"go": sha(go.read_bytes()), "python": sha(Path(sys.executable).read_bytes())}, "accepted": False, "tests": []}
try:
    completed = subprocess.run([str(go), "test", "-json", "-count=1", "-timeout=45s", "native_peer_windows.go", "native_original_user_windows.go", "native_original_user_windows_test.go", "native_knownfolders_windows.go", "knownfolders_contract.go"], cwd=root / "app", capture_output=True, timeout=120)
    for name, data in [("stdout.raw", completed.stdout), ("stderr.raw", completed.stderr)]:
        (out / name).write_bytes(data)
        receipt[name] = sha(data)
    receipt["exitCode"] = completed.returncode
    for line in completed.stdout.splitlines():
        event = json.loads(line)
        if event.get("Test") and event.get("Action") in ("pass", "fail", "skip"):
            receipt["tests"].append({"name": event["Test"], "outcome": event["Action"]})
    required = {"TestNativeOriginalUserRejectsMissingClosedOrAlternativeAdministrator", "TestNativeOriginalUserCannotReplaceObservedTokenWithPeerFields", "TestNativeOriginalUserActualTokenProfileAndBindingReadOnly", "TestNativeOriginalUserActualInteractiveCapture", "TestNativeOriginalUserActualRestrictedInteractiveCriterion", "TestNativeOriginalUserActualKnownFolderCollector"}
    passed = {test["name"] for test in receipt["tests"] if test["outcome"] == "pass"}
    receipt["accepted"] = completed.returncode == 0 and required <= passed and all(t["outcome"] == "pass" for t in receipt["tests"])
finally:
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
if not receipt["accepted"]:
    raise SystemExit("Actual token binding controls refused; inspect retained raw evidence")
print("Actual token binding reads/refusals passed; no install authorization")
