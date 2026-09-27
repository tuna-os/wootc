"""Exact hosted Windows Go controls; retain native bytes and execution identity."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
output = repo / "out" / "native-configuration"
output.mkdir(parents=True, exist_ok=False)
go = Path(shutil.which("go") or "")
if not go.is_file():
    raise SystemExit("Go tool unavailable")
source_paths = ["app/app.go", "app/catalog.go", "app/native_configuration.go", "app/native_configuration_root_windows.go", "app/native_configuration_root_other.go", "app/native_configuration_windows.go", "app/native_configuration_test.go", "app/native_configuration_rpc_test.go", "app/native_storage_windows.go", "app/native_storage_windows_test.go", "app/native_storage_query.ps1", "app/status_location_windows.go", "app/serve.go", "app/native_serve_windows.go", "app/state_trust_windows.go", "app/go.mod", "app/go.sum", "tests/native_configuration_controls.py", ".github/workflows/native-configuration.yml"]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
receipt = {"schemaVersion": 1, "scope": "hosted Windows read-only system query and private Go fixtures; no installation", "runId": os.environ.get("GITHUB_RUN_ID"), "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"), "testedHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(), "checkoutSources": {p: digest(repo/p) for p in source_paths}, "tools": {"go": {"path": str(go), "sha256": digest(go)}, "python": {"path": sys.executable, "sha256": digest(Path(sys.executable))}}, "returnCode": None, "tests": []}
args = [str(go), "test", "-count=1", "-json", "-timeout", "90s", "-run", "^TestNativeConfiguration", "."]
receipt["gitSources"] = {p: hashlib.sha256(subprocess.check_output(["git", "show", "HEAD:"+p],cwd=repo)).hexdigest() for p in source_paths}
receipt["arguments"] = args
try:
    with (output/"stdout.raw").open("wb") as stdout, (output/"stderr.raw").open("wb") as stderr:
        environment=dict(os.environ, WOOTC_NATIVE_QUERY_PROOF_DIR=str(output/"system-query"))
        completed = subprocess.run(args, cwd=repo/"app", stdout=stdout, stderr=stderr, env=environment, timeout=180, check=False)
    receipt["returnCode"] = completed.returncode
    for line in (output/"stdout.raw").read_bytes().splitlines():
        event = json.loads(line)
        if event.get("Action") in ("pass", "fail", "skip") and event.get("Test"):
            receipt["tests"].append({"name": event["Test"], "outcome": event["Action"]})
    required = {"TestNativeConfigurationActualSystemStorageQueryAndSerialReadOnly", "TestNativeConfigurationStorageIgnoresInheritedModuleShadow",
        "TestNativeConfigurationStorageIgnoresInheritedWindowsDirectory", "TestNativeConfigurationStorageReobservesSameLetterPhysicalIdentity", "TestNativeConfigurationRPCRequiresTrustedCapabilityAndNoParameters", "TestNativeConfigurationActualTrustedModuleManifestInventory"}
    passed = {test["name"] for test in receipt["tests"] if test["outcome"] == "pass"}
    receipt["accepted"] = completed.returncode == 0 and required <= passed and all(test["outcome"] == "pass" for test in receipt["tests"])
finally:
    receipt["rawFiles"] = {str(p.relative_to(output)): {"sha256": digest(p), "size": p.stat().st_size} for p in output.rglob("*.raw")}
    receipt["diagnosticRecords"] = {str(p.relative_to(output)): {"sha256": digest(p), "size": p.stat().st_size} for p in (output/"system-query").rglob("*") if p.is_file()}
    (output/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n", encoding="utf-8")
if not receipt.get("accepted"):
    raise SystemExit("Actual native controls failed or skipped; retained raw bytes and receipt")
print("Actual native configuration controls PASS; no skipped controls")
