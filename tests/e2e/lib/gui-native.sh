# shellcheck shell=bash
# Native shell staging for the GUI E2E (WOOTC_E2E_GUI_FRONTEND=native, #344).
#
# The native shell runs only from a protected package: the shell and the
# engine each refuse a package whose directory a non-administrator could
# change, or whose files differ from native-package.json
# (shell/Wootc.Shell.Native/ProtectedPackage.cs, app/native_package_windows.go).
# So the package is installed where the preview installer puts it
# (shell/packaging/preview.iss: {autopf}\wootc Native Preview\<brand>\bundle),
# inheriting the Program Files ACLs a real install has. The Inno installer
# itself is not run here; winui-preview.yml installs and removes it.
#
# Elevation mirrors the Wails path: launch-gui.cmd runs from a /RL HIGHEST
# task as the autologged administrator, so the shell starts elevated, the
# same-user context its hosted UI tests use. The shell still asks for the
# engine with ShellExecute "runas" once per session (startup, then one
# install-purpose session per plan check). ConsentPromptBehaviorAdmin=0 keeps
# each of those non-interactive. The elevated engine is a fresh process
# whose environment need not be the shell's, so its two switches are set
# machine-wide, not only in launch-gui.cmd. None of this proves the
# unelevated shell or interactive consent.
#
# Needs qga_powershell, step/info/pass/warn/fail/infra_fail, deadline_in,
# past_deadline (run-e2e.sh) and NATIVE_BRAND.

GUI_NATIVE_COPY_BUDGET="${GUI_NATIVE_COPY_BUDGET:-900}"

# PowerShell that sets $bundle to the package directory. ProgramW6432 is the
# 64-bit Program Files even when the guest agent runs as a 32-bit process.
gui_native_bundle_ps() {
    [[ "${NATIVE_BRAND:-}" =~ ^[a-z]+$ ]] || return 1
    # shellcheck disable=SC2016
    printf '%s\n' '$pf = $env:ProgramW6432' \
        'if (-not $pf) { $pf = $env:ProgramFiles }' \
        "\$bundle = Join-Path \$pf \"wootc Native Preview\\$NATIVE_BRAND\\bundle\""
}

# robocopy's exit code: 0-7 copied (bits for extra/mismatched files), 8+ failed.
# Prints ok, failed or pending.
gui_native_copy_verdict() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/}"
    case "$raw" in
        rc=[0-7]) echo ok ;;
        rc=[0-9]|rc=[0-9][0-9]) echo failed ;;
        *) echo pending ;;
    esac
}

# Positive evidence only: the package landed whole, both binaries match the
# manifest, and the engine's switches and non-interactive UAC are in place.
gui_native_installed_proven() {
    local out="${1:-}" recorded present
    out="${out//$'\r'/}"
    printf '%s\n' "$out" | grep -qx 'native-package-installed' || return 1
    printf '%s\n' "$out" | grep -q '^PACKAGE-' && return 1
    recorded=$(printf '%s\n' "$out" | sed -n 's/^package-files: recorded=\([0-9]*\) present=[0-9]*$/\1/p')
    present=$(printf '%s\n' "$out" | sed -n 's/^package-files: recorded=[0-9]* present=\([0-9]*\)$/\1/p')
    [ -n "$recorded" ] && [ "$recorded" -gt 0 ] && [ "$recorded" = "$present" ] || return 1
    printf '%s\n' "$out" | grep -qx 'package-digests: Wootc.Shell.exe wootc-engine.exe' || return 1
    printf '%s\n' "$out" | grep -qx "package-brand: ${NATIVE_BRAND:-?}" || return 1
    printf '%s\n' "$out" | grep -qx 'machine-env: WOOTC_E2E_DRIVE=1 WOOTC_PRELOAD=0' || return 1
    printf '%s\n' "$out" | grep -qx 'uac: ConsentPromptBehaviorAdmin=0' || return 1
}

# The one running shell must be the installed package's, not a stray copy.
gui_native_shell_path_proven() {
    local out="${1:-}"
    out="${out//$'\r'/}"
    printf '%s\n' "$out" | grep -qiE "^native-shell-path: [A-Z]:\\\\Program Files\\\\wootc Native Preview\\\\${NATIVE_BRAND:-?}\\\\bundle\\\\Wootc\\.Shell\\.exe$"
}

gui_native_stage_package() {
    local bundle_ps out raw verdict deadline
    bundle_ps=$(gui_native_bundle_ps) || { fail "native package brand is invalid: '${NATIVE_BRAND:-}'"; return 1; }
    step "Installing the native shell package (brand $NATIVE_BRAND) in the guest..."
    # Kick off and poll: ~250 MB over SMB can outlast one 60 s QGA call, and a
    # client killed mid-command poisons the single-connection socket.
    # The batch file is written from a here-string so %ERRORLEVEL% reaches
    # cmd.exe untouched; the redirection comes first so "1>" is never read
    # as a handle number.
    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
'"$bundle_ps"'
$owner = Split-Path -Parent $bundle
if (Test-Path -LiteralPath $owner) { Remove-Item -LiteralPath $owner -Recurse -Force }
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
Remove-Item C:\Windows\Temp\wootc-native-copy.rc,C:\Windows\Temp\wootc-native-copy.log -Force -ErrorAction SilentlyContinue
@"
robocopy \\host.lan\Data\native-shell "$bundle" /E /R:3 /W:5 /NP /NFL /NDL /LOG:C:\Windows\Temp\wootc-native-copy.log
>C:\Windows\Temp\wootc-native-copy.rc echo rc=%ERRORLEVEL%
"@ | Set-Content -Path C:\Windows\Temp\wootc-native-copy.cmd -Encoding ascii
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c","C:\Windows\Temp\wootc-native-copy.cmd"
Write-Output ("native-copy-started: " + $bundle)' 2>&1) || true
    printf '%s\n' "$out" | sed 's/^/    native: /'
    printf '%s' "$out" | grep -q 'native-copy-started:' || {
        infra_fail "native package copy did not start in the guest"
        return 1
    }

    deadline=$(deadline_in "$GUI_NATIVE_COPY_BUDGET")
    verdict=pending
    while ! past_deadline "$deadline"; do
        raw=$(qga_powershell 'if (Test-Path C:\Windows\Temp\wootc-native-copy.rc) { (Get-Content C:\Windows\Temp\wootc-native-copy.rc -Raw).Trim() } else { "pending" }' 2>/dev/null || true)
        verdict=$(gui_native_copy_verdict "$raw")
        [ "$verdict" = pending ] || break
        sleep 10
    done
    if [ "$verdict" != ok ]; then
        infra_fail "native package copy into the guest ${verdict} (robocopy: ${raw:-no exit code})"
        qga_powershell 'Get-Content C:\Windows\Temp\wootc-native-copy.log -Tail 20 -ErrorAction SilentlyContinue' 2>&1 | sed 's/^/    robocopy: /' || true
        return 1
    fi
    info "  package copied (robocopy ${raw//$'\r'/})"

    # Verify what landed, then provision the engine's environment and UAC.
    # Registry writes, not [Environment]::SetEnvironmentVariable: no settings
    # broadcast to wait on, and a new process's environment block is built
    # from these keys when it is created.
    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
'"$bundle_ps"'
$m = Get-Content -LiteralPath (Join-Path $bundle "native-package.json") -Raw | ConvertFrom-Json
$recorded = @($m.files.PSObject.Properties).Count
$present = @(Get-ChildItem -LiteralPath $bundle -Recurse -File -Force | Where-Object { $_.Name -ne "native-package.json" }).Count
Write-Output ("package-files: recorded=" + $recorded + " present=" + $present)
foreach ($f in "Wootc.Shell.exe","wootc-engine.exe") {
    $h = (Get-FileHash -LiteralPath (Join-Path $bundle $f) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $m.files.$f) { Write-Output ("PACKAGE-DIGEST-MISMATCH: " + $f) }
}
Write-Output "package-digests: Wootc.Shell.exe wootc-engine.exe"
Write-Output ("package-brand: " + $m.brandId)
Write-Output ("package-build: " + $m.buildId)
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
Set-ItemProperty -LiteralPath $envKey -Name WOOTC_E2E_DRIVE -Value "1" -Type String
Set-ItemProperty -LiteralPath $envKey -Name WOOTC_PRELOAD -Value "0" -Type String
$e = Get-ItemProperty -LiteralPath $envKey
Write-Output ("machine-env: WOOTC_E2E_DRIVE=" + $e.WOOTC_E2E_DRIVE + " WOOTC_PRELOAD=" + $e.WOOTC_PRELOAD)
$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -LiteralPath $uacKey -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord
$u = Get-ItemProperty -LiteralPath $uacKey
Write-Output ("uac: ConsentPromptBehaviorAdmin=" + $u.ConsentPromptBehaviorAdmin)
Write-Output ("uac-lua: EnableLUA=" + $u.EnableLUA)
Write-Output "native-package-installed"' 2>&1) || true
    printf '%s\n' "$out" | sed 's/^/    native: /'
    if ! gui_native_installed_proven "$out"; then
        infra_fail "the native shell package is not provably installed and provisioned in the guest"
        return 1
    fi
    pass "Native shell package installed under Program Files (brand $NATIVE_BRAND); engine switches machine-wide; UAC non-interactive"
}
