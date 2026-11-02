# shellcheck shell=bash
# Strict native full-cycle evidence. Caller supplies the existing QGA wrappers,
# GUI session helpers, ARTIFACT_DIR/SCRIPT_DIR/REPO_ROOT, and fail().
native_proof_enabled() { [ "${WOOTC_E2E_NATIVE_PROOF:-0}" = 1 ]; }

native_proof_stage_file() {
    local source="$1" destination="$2"
    "$DOCKER" cp "$source" "$CONTAINER_NAME:/tmp/wootc-native-proof-transfer" &&
        qga_call write /tmp/wootc-native-proof-transfer "$destination"
}

native_proof_schedule() {
    local mode="$1"
    [[ "$mode" = install || "$mode" = return ]] || return 1
    # IDs are numeric GitHub identities, never arbitrary PowerShell fragments.
    qga_powershell '$ErrorActionPreference = "Stop"
$d = "'"$NATIVE_PROOF_GUEST"'"
$c = Get-Content -LiteralPath (Join-Path $d "context.json") -Raw | ConvertFrom-Json
$lines = @("@echo off", "start `"`" /b powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$d\observer.ps1`" -Mode '"$mode"' -Directory `"$d`"")
if ("'"$mode"'" -eq "return") {
    $lines += "set WOOTC_E2E_DRIVE=0"
    $lines += "set WOOTC_PRELOAD=0"
    $lines += ("start `"`" `"" + $c.packagePath + "`"")
}
$launcher = Join-Path $d "'"$mode"'.cmd"
$lines | Set-Content -LiteralPath $launcher -Encoding ascii
$who = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $who) { throw "Native proof has no interactive session" }
$start = (Get-Date).AddMinutes(-1).ToString("HH:mm")
$task = "'"$NATIVE_PROOF_TASK"'"
$output = cmd.exe /d /c "schtasks /Create /TN $task /SC ONCE /ST $start /TR $launcher /RU $who /IT /RL HIGHEST /F 2>&1"
if ($LASTEXITCODE -ne 0) { throw ("Native observer scheduling failed: " + ($output -join " ")) }
$output = cmd.exe /d /c "schtasks /Run /TN $task 2>&1"
if ($LASTEXITCODE -ne 0) { throw "Native observer did not start" }
Write-Output "native-observer-scheduled"' > "$NATIVE_PROOF_DIR/$mode-launch.log"
}

native_proof_stage_observer() {
    qga_powershell '$ErrorActionPreference = "Stop"
'"$(gui_native_bundle_ps)"'
$d = "'"$NATIVE_PROOF_GUEST"'"
if (Test-Path -LiteralPath $d) { throw "Native observer directory already exists; refusing stale proof" }
New-Item -ItemType Directory -Path $d | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetSecurityDescriptorSddlForm("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)")
Set-Acl -LiteralPath $d -AclObject $acl
Join-Path $bundle "Wootc.Shell.exe"' > "$NATIVE_PROOF_DIR/package-path.txt" || return 1
    python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); c=json.loads(p.read_text()); c["packagePath"]=pathlib.Path(sys.argv[2]).read_text().strip(); p.write_text(json.dumps(c))' \
        "$NATIVE_PROOF_DIR/context.json" "$NATIVE_PROOF_DIR/package-path.txt" || return 1
    native_proof_stage_file "$NATIVE_PROOF_DIR/context.json" "$NATIVE_PROOF_GUEST\\context.json" || return 1
    native_proof_stage_file "$SCRIPT_DIR/native-proof-observer.ps1" "$NATIVE_PROOF_GUEST\\observer.ps1" || return 1
}

native_proof_prepare() {
    native_proof_enabled || return 0
    [ "${GUI_FRONTEND:-}" = native ] && [ "${RUN_PHASE3:-false}" != true ] || {
        fail "Native semantic proof requires the full-cycle native GUI lane (not Phase 3)"; return 1;
    }
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ && "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || {
        fail "Native semantic proof requires explicit GitHub source/run/attempt identity"; return 1;
    }
    NATIVE_PROOF_DIR="$ARTIFACT_DIR/native-proof"
    NATIVE_PROOF_GUEST="C:\\ProgramData\\wootc-native-proof-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    NATIVE_PROOF_TASK="wootc-native-proof-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    python3 "$SCRIPT_DIR/native-proof.py" init "$NATIVE_PROOF_DIR" "$NATIVE_PACKAGE_DIR" || return 1
    native_proof_stage_observer || return 1
    native_proof_schedule install
}

native_proof_capture_linux() {
    native_proof_enabled || return 0
    # This command must succeed while the installed Phase-2 Linux is current.
    local script
    script=$(cat "$SCRIPT_DIR/native-proof-linux.py") || return 1
    qga_call exec /usr/bin/python3 -c "$script" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$GITHUB_SHA" \
        > "$NATIVE_PROOF_DIR/installed-boot-observation.json" \
        2> "$NATIVE_PROOF_DIR/linux-observer.stderr"
}

native_proof_capture_return() {
    native_proof_enabled || return 0
    [ -s "$NATIVE_PROOF_DIR/installed-boot-observation.json" ] || { fail "Native proof lacks prior Linux observation"; return 1; }
    qga_windows_probe && gui_wait_interactive_session || return 1
    native_proof_observe_return install-confirmation installed-boot-summary windows-return
}

native_proof_observe_return() {
    native_proof_schedule return || return 1
    local deadline state journey suffix
    deadline=$(deadline_in 240)
    state=""
    while ! past_deadline "$deadline"; do
        state=$(qga_powershell '$d="'"$NATIVE_PROOF_GUEST"'"; if (Test-Path "$d\return.error") { Get-Content "$d\return.error" -Raw; exit 1 }; if (Test-Path "$d\return.done") { "observed" }' 2>/dev/null) || {
            fail "Native return observer failed: $state"; return 1;
        }
        [ "${state//$'\r'/}" = observed ] && break
        sleep 2
    done
    [ "${state//$'\r'/}" = observed ] || { fail "Native return UIA/framebuffer observation timed out"; return 1; }
    for journey in "$@"; do
        for suffix in uia.json observation.json png; do
            qga_call read "$NATIVE_PROOF_GUEST\\$journey.$suffix" > "$NATIVE_PROOF_DIR/$journey.$suffix" || return 1
        done
    done
    qga_call read "$NATIVE_PROOF_GUEST\\windows-current-observation.json" > "$NATIVE_PROOF_DIR/windows-current-observation.json" || return 1
}

native_proof_cleanup() {
    [ -n "${NATIVE_PROOF_GUEST:-}" ] || return 0
    # Only this run's exact observer command line/task, no broad process kill.
    qga_powershell '$d="'"$NATIVE_PROOF_GUEST"'"; foreach ($mode in "install","return") { $errorFile=Join-Path $d ($mode+".error"); if (Test-Path -LiteralPath $errorFile) { Write-Output ($mode+" observer error:"); Get-Content -LiteralPath $errorFile -Raw } }; Get-CimInstance Win32_Process -Filter "Name = '\''powershell.exe'\''" | Where-Object { $_.CommandLine -like ("*" + $d + "\observer.ps1*") } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; cmd.exe /d /c "schtasks /Delete /TN '"$NATIVE_PROOF_TASK"' /F 2>&1" | Out-Null' >> "$NATIVE_PROOF_DIR/observer-cleanup.log" 2>&1 || true
}

native_proof_finalize() {
    native_proof_enabled || return 0
    python3 "$SCRIPT_DIR/native-proof.py" assemble "$NATIVE_PROOF_DIR" || { fail "Native semantic proof failed strict ledger validation"; return 1; }
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'NATIVE_PROOF_DIR=%s\n' "$NATIVE_PROOF_DIR" >> "$GITHUB_ENV"
    fi
    native_proof_cleanup
}

# Native non-soak runs still observe the real summary. Their harness run ID is
# kept as-is; no invented GitHub run/attempt and no soak artifact is emitted.
native_summary_capture() {
    [[ "$RUN_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { fail "Unsafe harness run identity"; return 1; }
    NATIVE_PROOF_DIR="$ARTIFACT_DIR/native-summary"
    NATIVE_PROOF_GUEST="C:\\ProgramData\\wootc-native-summary-$RUN_ID"
    NATIVE_PROOF_TASK="wootc-native-summary-$RUN_ID"
    python3 "$SCRIPT_DIR/native-proof.py" summary-init "$NATIVE_PROOF_DIR" "$NATIVE_PACKAGE_DIR" "$RUN_ID" "$NATIVE_BUILD" || return 1
    native_proof_stage_observer || return 1
    qga_windows_probe && gui_wait_interactive_session || return 1
    native_proof_observe_return installed-boot-summary windows-return || return 1
    python3 "$SCRIPT_DIR/native-proof.py" summary "$NATIVE_PROOF_DIR" "$FIRSTBOOT_RECORD_FILE" || {
        fail "Native installed summary differs from independently observed Linux"; return 1;
    }
    native_proof_cleanup
}
