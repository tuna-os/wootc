# shellcheck shell=bash
# Native shell staging for the GUI E2E (WOOTC_E2E_GUI_FRONTEND=native, #344).
#
# The native shell runs only from a protected package: the shell and the
# engine each refuse a package whose directory a non-administrator could
# change, or whose files differ from native-package.json
# (shell/Wootc.Shell.Native/ProtectedPackage.cs, app/native_package_windows.go).
#
# Installation (NATIVE_INSTALLER):
#   inno      the default. The real preview installer (shell/packaging/preview.iss),
#             compiled for this run's brand by e2e-hosted.yml's native-shell job,
#             runs silently in the guest. It puts the package at
#             {autopf}\wootc Native Preview\<brand>\bundle and registers its
#             uninstaller, which the verification below observes.
#   robocopy  a copy into the same directory. Only when the runner could not
#             obtain the pinned Inno compiler, and never silently: the run says
#             so and the native-shell assertion names the method.
#
# Elevation (NATIVE_UNELEVATED):
#   1  the default. launch-gui.cmd runs from a /RL LIMITED task as the
#      autologged administrator, so the shell starts at medium integrity, as a
#      real user's does. The shell asks for the engine with ShellExecute
#      "runas" once per session (startup, then one install-purpose session per
#      plan check); ConsentPromptBehaviorAdmin=0 elevates each of those without
#      a prompt. gui_native_observe_integrity records both levels.
#   0  the earlier mode: a /RL HIGHEST task, so the shell itself is elevated.
# Neither mode proves interactive consent on the secure desktop.
#
# The elevated engine is a fresh process whose environment need not be the
# shell's, so its two switches are set machine-wide, not only in
# launch-gui.cmd.
#
# Needs qga_powershell, step/info/pass/warn/fail/infra_fail/product_pass,
# deadline_in, past_deadline (run-e2e.sh), NATIVE_BRAND, NATIVE_INSTALLER,
# NATIVE_INSTALLER_FILE (inno) and NATIVE_UNELEVATED.

GUI_NATIVE_COPY_BUDGET="${GUI_NATIVE_COPY_BUDGET:-900}"
GUI_NATIVE_SHELL_UNELEVATED_PROVEN=false
GUI_NATIVE_ENGINE_ELEVATED_PROVEN=false
GUI_NATIVE_INTEGRITY_LAST=""

# Where launch-gui.cmd lives. C:\wootc carries the installer-state ACL
# (SYSTEM and Administrators only, tests/e2e/state-trust.ps1). A /RL LIMITED
# token holds Administrators deny-only, so it cannot read a launcher there:
# run 38888315334's task exited 1 (cmd.exe could not open the script) and
# Wootc.Shell.exe never started. The unelevated launch reads its launcher from
# a directory that Users can read and only SYSTEM and Administrators can change.
gui_launcher_path() {
    if [ "$(gui_task_runlevel)" = LIMITED ]; then
        echo 'C:\ProgramData\wootc-e2e-launch\launch-gui.cmd'
    else
        echo 'C:\wootc\launch-gui.cmd'
    fi
}

# PowerShell that sets $launcher and, for the unelevated launch, creates its
# directory with that ACL before anything is written into it.
gui_launcher_ps() {
    local path
    path=$(gui_launcher_path)
    printf '%s\n' "\$launcher = '$path'"
    if [ "$(gui_task_runlevel)" = LIMITED ]; then
        # shellcheck disable=SC2016
        printf '%s\n' '$launchDir = Split-Path -Parent $launcher' \
            'if (Test-Path -LiteralPath $launchDir) { Remove-Item -LiteralPath $launchDir -Recurse -Force }' \
            '$launchAcl = New-Object System.Security.AccessControl.DirectorySecurity' \
            '$launchAcl.SetSecurityDescriptorSddlForm("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)")' \
            '[IO.Directory]::CreateDirectory($launchDir, $launchAcl) | Out-Null' \
            'Write-Output ("launcher acl: " + (Get-Acl -LiteralPath $launchDir).Sddl)'
    fi
}

# Validates the two native options. Prints nothing; returns 1 on a bad value.
gui_native_options_valid() {
    case "${NATIVE_UNELEVATED:-}" in 0|1) ;; *) return 1 ;; esac
    case "${NATIVE_INSTALLER:-}" in inno|robocopy) ;; *) return 1 ;; esac
}

# The launch task's run level: LIMITED for an unelevated native shell,
# HIGHEST otherwise (the Wails app needs its elevation from the task).
gui_task_runlevel() {
    if [ "${GUI_FRONTEND:-}" = native ] && [ "${NATIVE_UNELEVATED:-}" = 1 ]; then
        echo LIMITED
    else
        echo HIGHEST
    fi
}

# The one installer this run installs: <brand>-native-preview-<build>.exe,
# which preview.iss names it, and the only executable in its directory.
gui_native_installer_file() {
    local dir="$1" brand="$2" build="$3" want count
    [[ "$brand" =~ ^[a-z]+$ ]] && [[ "$build" =~ ^[0-9a-f]{40}$ ]] || return 1
    want="$dir/$brand-native-preview-$build.exe"
    [ -f "$want" ] && [ ! -L "$want" ] && [ -s "$want" ] || return 1
    count=$(find "$dir" -maxdepth 1 -name '*.exe' | wc -l)
    [ "$count" -eq 1 ] || return 1
    printf '%s\n' "$want"
}

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

# A copy (cmd.exe copy) or an Inno Setup exit code: only 0 is success. Inno
# uses 1-8 for its failures (2 and 5 are cancellations, 7 and 8 a refusal by
# PrepareToInstall, e.g. an existing destination). Prints ok, failed or pending.
gui_native_exit_verdict() {
    local raw="${1:-}"
    raw="${raw//$'\r'/}"
    raw="${raw//$'\n'/}"
    if [ "$raw" = rc=0 ]; then
        echo ok
    elif [[ "$raw" =~ ^rc=-?[0-9]+$ ]]; then
        echo failed
    else
        echo pending
    fi
}

# Positive evidence only: the package landed whole by the stated method, both
# binaries match the manifest, and the engine's switches and non-interactive
# UAC are in place. An Inno install must also show the uninstall entry and
# the one uninstaller that only the real installer writes.
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
    case "${NATIVE_INSTALLER:-}" in
        inno)
            printf '%s\n' "$out" | grep -qx 'install-method: inno' || return 1
            printf '%s\n' "$out" | grep -qE "^inno-uninstall-entry: wootc-native-preview-${NATIVE_BRAND:-?}_is1 " || return 1
            printf '%s\n' "$out" | grep -qx 'inno-uninstallers: 1' || return 1
            ;;
        robocopy)
            printf '%s\n' "$out" | grep -qx 'install-method: robocopy' || return 1
            ;;
        *) return 1 ;;
    esac
}

# The one running shell must be the installed package's, not a stray copy.
gui_native_shell_path_proven() {
    local out="${1:-}"
    out="${out//$'\r'/}"
    printf '%s\n' "$out" | grep -qiE "^native-shell-path: [A-Z]:\\\\Program Files\\\\wootc Native Preview\\\\${NATIVE_BRAND:-?}\\\\bundle\\\\Wootc\\.Shell\\.exe$"
}

# Polls a guest rc file written by a detached cmd.exe until VERDICT_FN says
# ok or failed, or the budget runs out. Prints the last raw answer; returns
# 0 only for ok.
gui_native_wait_rc() {
    local rc_file="$1" budget="$2" verdict_fn="$3" deadline raw="" verdict=pending
    deadline=$(deadline_in "$budget")
    while ! past_deadline "$deadline"; do
        raw=$(qga_powershell "if (Test-Path $rc_file) { (Get-Content $rc_file -Raw).Trim() } else { 'pending' }" 2>/dev/null || true)
        verdict=$("$verdict_fn" "$raw")
        [ "$verdict" = pending ] || break
        sleep 10
    done
    printf '%s\n' "${raw//$'\r'/}"
    [ "$verdict" = ok ]
}

# Copies the robocopy fallback's package into the bundle directory.
gui_native_robocopy_package() {
    local bundle_ps="$1" out raw
    # Kick off and poll: ~250 MB over SMB can outlast one 60 s QGA call, and a
    # client killed mid-command poisons the single-connection socket.
    # The batch file is written from a here-string so %ERRORLEVEL% reaches
    # cmd.exe untouched; the redirection comes first so "1>" is never read
    # as a handle number.
    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
'"$bundle_ps"'
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
    if ! raw=$(gui_native_wait_rc 'C:\Windows\Temp\wootc-native-copy.rc' "$GUI_NATIVE_COPY_BUDGET" gui_native_copy_verdict); then
        infra_fail "native package copy into the guest did not succeed (robocopy: ${raw:-no exit code})"
        qga_powershell 'Get-Content C:\Windows\Temp\wootc-native-copy.log -Tail 20 -ErrorAction SilentlyContinue' 2>&1 | sed 's/^/    robocopy: /' || true
        return 1
    fi
    info "  package copied (robocopy $raw)"
}

# Runs the real preview installer silently. The installer is copied to the
# guest first and its digest compared with the host's, so a short copy is a
# refused copy rather than a corrupt install.
gui_native_inno_install() {
    local name digest out raw
    name=$(basename "$NATIVE_INSTALLER_FILE")
    [[ "$name" =~ ^[a-z]+-native-preview-[0-9a-f]{40}\.exe$ ]] || { fail "native installer name is invalid: $name"; return 1; }
    digest=$(sha256sum "$NATIVE_INSTALLER_FILE" | cut -d' ' -f1)
    # shellcheck disable=SC2016,SC1003
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
Remove-Item C:\Windows\Temp\wootc-native-setup.exe,C:\Windows\Temp\wootc-native-setup-copy.rc,C:\Windows\Temp\wootc-native-setup.rc,C:\Windows\Temp\wootc-native-setup.log -Force -ErrorAction SilentlyContinue
@"
copy /Y "\\host.lan\Data\native-installer\'"$name"'" C:\Windows\Temp\wootc-native-setup.exe
>C:\Windows\Temp\wootc-native-setup-copy.rc echo rc=%ERRORLEVEL%
"@ | Set-Content -Path C:\Windows\Temp\wootc-native-setup-copy.cmd -Encoding ascii
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c","C:\Windows\Temp\wootc-native-setup-copy.cmd"
Write-Output "native-installer-copy-started"' 2>&1) || true
    printf '%s\n' "$out" | sed 's/^/    native: /'
    printf '%s\n' "${out//$'\r'/}" | grep -qx 'native-installer-copy-started' || {
        infra_fail "native installer copy did not start in the guest"
        return 1
    }
    if ! raw=$(gui_native_wait_rc 'C:\Windows\Temp\wootc-native-setup-copy.rc' "$GUI_NATIVE_COPY_BUDGET" gui_native_exit_verdict); then
        infra_fail "native installer copy into the guest did not succeed (${raw:-no exit code})"
        return 1
    fi

    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
$h = (Get-FileHash -LiteralPath C:\Windows\Temp\wootc-native-setup.exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($h -ne "'"$digest"'") { Write-Output ("INSTALLER-DIGEST-MISMATCH: " + $h); exit 0 }
Write-Output ("installer-digest: " + $h)
@"
C:\Windows\Temp\wootc-native-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="C:\Windows\Temp\wootc-native-setup.log"
>C:\Windows\Temp\wootc-native-setup.rc echo rc=%ERRORLEVEL%
"@ | Set-Content -Path C:\Windows\Temp\wootc-native-setup.cmd -Encoding ascii
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c","C:\Windows\Temp\wootc-native-setup.cmd"
Write-Output "native-installer-started"' 2>&1) || true
    printf '%s\n' "$out" | sed 's/^/    native: /'
    out="${out//$'\r'/}"
    if ! printf '%s\n' "$out" | grep -qx "installer-digest: $digest" || ! printf '%s\n' "$out" | grep -qx 'native-installer-started'; then
        infra_fail "the native installer in the guest is not the one this run built, or it did not start"
        return 1
    fi
    if ! raw=$(gui_native_wait_rc 'C:\Windows\Temp\wootc-native-setup.rc' "$GUI_NATIVE_COPY_BUDGET" gui_native_exit_verdict); then
        product_fail "the native preview installer failed in the guest (Inno Setup ${raw:-no exit code})"
        qga_powershell 'Get-Content C:\Windows\Temp\wootc-native-setup.log -Tail 25 -ErrorAction SilentlyContinue' 2>&1 | sed 's/^/    inno: /' || true
        return 1
    fi
    info "  preview installer finished (Inno Setup $raw)"
}

gui_native_stage_package() {
    local bundle_ps out
    bundle_ps=$(gui_native_bundle_ps) || { fail "native package brand is invalid: '${NATIVE_BRAND:-}'"; return 1; }
    gui_native_options_valid || { fail "native options are invalid: installer '${NATIVE_INSTALLER:-}', unelevated '${NATIVE_UNELEVATED:-}'"; return 1; }
    step "Installing the native shell package (brand $NATIVE_BRAND, by $NATIVE_INSTALLER) in the guest..."
    # A fresh destination: preview.iss refuses an existing one, and a copy
    # must not merge into stale files.
    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
'"$bundle_ps"'
$owner = Split-Path -Parent $bundle
if (Test-Path -LiteralPath $owner) { Remove-Item -LiteralPath $owner -Recurse -Force }
if (Test-Path -LiteralPath $owner) { throw "stale native destination remains" }
Write-Output "native-destination-clear"' 2>&1) || true
    printf '%s' "$out" | grep -q 'native-destination-clear' || {
        printf '%s\n' "$out" | sed 's/^/    native: /'
        infra_fail "could not clear the native package destination in the guest"
        return 1
    }
    if [ "$NATIVE_INSTALLER" = inno ]; then
        gui_native_inno_install || return 1
    else
        warn "  NOT the preview installer: the package is copied with robocopy because the runner could not obtain the pinned Inno compiler"
        gui_native_robocopy_package "$bundle_ps" || return 1
    fi

    # Verify what landed, then provision the engine's environment and UAC.
    # Registry writes, not [Environment]::SetEnvironmentVariable: no settings
    # broadcast to wait on, and a new process's environment block is built
    # from these keys when it is created.
    # shellcheck disable=SC2016
    out=$(qga_powershell '$ErrorActionPreference = "Stop"
'"$bundle_ps"'
$owner = Split-Path -Parent $bundle
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
Write-Output "install-method: '"$NATIVE_INSTALLER"'"
$appId = "wootc-native-preview-" + $m.brandId + "_is1"
$hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$entry = $hive.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\" + $appId)
if ($entry) { Write-Output ("inno-uninstall-entry: " + $appId + " " + $entry.GetValue("InstallLocation")); $entry.Close() }
$hive.Close()
Write-Output ("inno-uninstallers: " + @(Get-ChildItem -LiteralPath $owner -Filter "unins*.exe" -File -Force).Count)
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
        infra_fail "the native shell package is not provably installed (by $NATIVE_INSTALLER) and provisioned in the guest"
        return 1
    fi
    if [ "$NATIVE_INSTALLER" = inno ]; then
        pass "Native shell installed by the preview installer under Program Files (brand $NATIVE_BRAND; uninstall entry registered); engine switches machine-wide; UAC non-interactive"
    else
        warn "Native shell copied with robocopy (NOT the preview installer) under Program Files (brand $NATIVE_BRAND); engine switches machine-wide; UAC non-interactive"
    fi
}

# PowerShell that prints one line per Wootc.Shell.exe and wootc-engine.exe:
#   native-integrity: role=<shell|engine-install|engine-config> pid=N rid=0x2000 elevated=0 sid=S-... path=...
# rid is the token's mandatory integrity level (0x2000 medium, 0x3000 high);
# elevated is TokenElevation. An unreadable token prints error=... instead.
gui_native_integrity_ps() {
    cat <<'PS'
$ErrorActionPreference = "Stop"
if (-not ("WootcIntegrity" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WootcIntegrity {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int information, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr text);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    static IntPtr Query(IntPtr token, int information) {
        int length;
        GetTokenInformation(token, information, IntPtr.Zero, 0, out length);
        if (length <= 0) return IntPtr.Zero;
        IntPtr buffer = Marshal.AllocHGlobal(length);
        if (!GetTokenInformation(token, information, buffer, length, out length)) { Marshal.FreeHGlobal(buffer); return IntPtr.Zero; }
        return buffer;
    }
    static string SidText(IntPtr sid) {
        IntPtr text;
        if (!ConvertSidToStringSid(sid, out text)) return "unknown";
        string value = Marshal.PtrToStringUni(text);
        LocalFree(text);
        return value;
    }
    public static string Probe(int pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) return "error=open-" + Marshal.GetLastWin32Error();
        IntPtr token;
        if (!OpenProcessToken(process, 0x0008, out token)) { int code = Marshal.GetLastWin32Error(); CloseHandle(process); return "error=token-" + code; }
        IntPtr label = Query(token, 25), user = Query(token, 1), elevation = Query(token, 20);
        try {
            if (label == IntPtr.Zero || user == IntPtr.Zero || elevation == IntPtr.Zero) return "error=query";
            IntPtr levelSid = Marshal.ReadIntPtr(label);
            int count = Marshal.ReadByte(GetSidSubAuthorityCount(levelSid));
            int rid = Marshal.ReadInt32(GetSidSubAuthority(levelSid, (uint)(count - 1)));
            return "rid=0x" + rid.ToString("x4") + " elevated=" + Marshal.ReadInt32(elevation) + " sid=" + SidText(Marshal.ReadIntPtr(user));
        } finally {
            if (label != IntPtr.Zero) Marshal.FreeHGlobal(label);
            if (user != IntPtr.Zero) Marshal.FreeHGlobal(user);
            if (elevation != IntPtr.Zero) Marshal.FreeHGlobal(elevation);
            CloseHandle(token);
            CloseHandle(process);
        }
    }
}
'@
}
foreach ($p in @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "Wootc.Shell.exe" -or $_.Name -eq "wootc-engine.exe" })) {
    $role = "shell"
    if ($p.Name -eq "wootc-engine.exe") {
        $role = "engine-config"
        if ($p.CommandLine -match "--purpose\s+install(\s|$)") { $role = "engine-install" }
    }
    Write-Output ("native-integrity: role=" + $role + " pid=" + $p.ProcessId + " " + [WootcIntegrity]::Probe([int]$p.ProcessId) + " path=" + $p.ExecutablePath)
}
Write-Output "native-integrity-done"
PS
}

# The package path a probe line must name, as an ERE (case-insensitive).
gui_native_integrity_path_re() {
    printf '%s' "[A-Z]:\\\\Program Files\\\\wootc Native Preview\\\\${NATIVE_BRAND:-?}\\\\bundle\\\\$1"
}

# The shell's SID from a probe, when exactly one shell answered.
gui_native_integrity_shell_sid() {
    local out="${1//$'\r'/}" lines
    lines=$(printf '%s\n' "$out" | grep '^native-integrity: role=shell ' || true)
    [ "$(printf '%s' "$lines" | grep -c '^native-integrity:')" -eq 1 ] || return 1
    printf '%s\n' "$lines" | sed -n 's/^.* sid=\(S-1-5-21-[0-9-]*\) path=.*$/\1/p' | grep . || return 1
}

# Positive evidence only: exactly one shell, from the installed package, at
# medium integrity (0x2000) and not elevated.
gui_native_shell_unelevated_proven() {
    local out="${1//$'\r'/}"
    printf '%s\n' "$out" | grep -qx 'native-integrity-done' || return 1
    gui_native_integrity_shell_sid "$out" >/dev/null || return 1
    printf '%s\n' "$out" | grep '^native-integrity: role=shell ' \
        | grep -qiE "^native-integrity: role=shell pid=[0-9]+ rid=0x2000 elevated=0 sid=S-1-5-21-[0-9-]+ path=$(gui_native_integrity_path_re 'Wootc\.Shell\.exe')$"
}

# Positive evidence only: an install-purpose engine from the installed
# package, at high integrity (0x3000), elevated, for the shell's own user.
gui_native_engine_elevated_proven() {
    local out="${1//$'\r'/}" sid
    printf '%s\n' "$out" | grep -qx 'native-integrity-done' || return 1
    sid=$(gui_native_integrity_shell_sid "$out") || return 1
    printf '%s\n' "$out" | grep '^native-integrity: role=engine-install ' \
        | grep -qiE "^native-integrity: role=engine-install pid=[0-9]+ rid=0x3000 elevated=1 sid=${sid} path=$(gui_native_integrity_path_re 'wootc-engine\.exe')$"
}

# Samples the shell's and the install engine's integrity until each is
# proven, recording a product assertion for each the first time. Prints the
# probe whenever its answer changes, so a run that never proves one shows
# what it saw instead.
gui_native_observe_integrity() {
    local out shown
    [ "$GUI_NATIVE_SHELL_UNELEVATED_PROVEN" = true ] && [ "$GUI_NATIVE_ENGINE_ELEVATED_PROVEN" = true ] && return 0
    out=$(qga_powershell "$(gui_native_integrity_ps)" 2>&1 | tr -d '\r') || true
    shown=$(printf '%s\n' "$out" | sed 's/ pid=[0-9]*//')
    if [ "$shown" != "$GUI_NATIVE_INTEGRITY_LAST" ]; then
        printf '%s\n' "$out" | sed 's/^/    integrity: /'
        GUI_NATIVE_INTEGRITY_LAST="$shown"
    fi
    if [ "$GUI_NATIVE_SHELL_UNELEVATED_PROVEN" = false ] && gui_native_shell_unelevated_proven "$out"; then
        GUI_NATIVE_SHELL_UNELEVATED_PROVEN=true
        product_pass native-shell-unelevated "Wootc.Shell.exe runs unelevated at medium integrity (0x2000) from the installed package"
    fi
    if [ "$GUI_NATIVE_ENGINE_ELEVATED_PROVEN" = false ] && gui_native_engine_elevated_proven "$out"; then
        GUI_NATIVE_ENGINE_ELEVATED_PROVEN=true
        product_pass native-engine-elevated "The install-session wootc-engine.exe runs elevated at high integrity (0x3000) for the shell's own user, through runas with ConsentPromptBehaviorAdmin=0"
    fi
}
