#!/usr/bin/env bash
# Source-only fixture GUI session adapter. Explicit QGA callbacks supply guest
# operations; the scenario retains drive directives and product acceptance.
# Caller provides infra_fail/info/pass, deadline_in/past_deadline callbacks.
wootc_gui_configure() {
    [ "$#" -eq 4 ] && [ -n "$1" ] || return 2
    declare -F "$2" >/dev/null && declare -F "$3" >/dev/null && declare -F "$4" >/dev/null || return 2
    WOOTC_GUI_SCRIPT_DIR="$1"
    WOOTC_GUI_POWERSHELL="$2"
    WOOTC_GUI_IDENTITY="$3"
    WOOTC_GUI_RESTART_WINDOWS="$4"
}
gui_prepare_account() {
    "${WOOTC_GUI_IDENTITY:?Configure GUI first}" || { infra_fail "GUI account preparation requires positive Windows identity"; return 1; }
    local result
    GUI_ACCOUNT_RESTART=false
    # shellcheck disable=SC2016 # PowerShell variables are literal.
    if ! result=$("${WOOTC_GUI_POWERSHELL:?Configure GUI first}" '
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
New-Item -ItemType Directory -Force -Path C:\OEM | Out-Null
$log = "C:\OEM\wootc-e2e.log"
try {
    $wl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $name = [string]$wl.DefaultUserName
    if ($wl.AutoAdminLogon -ne "1" -or $name -notin @("wootc", "Docker")) {
        throw "autologon fixture account is missing or unexpected"
    }
    if ($wl.DefaultDomainName -and $wl.DefaultDomainName -notin @(".", $env:COMPUTERNAME)) {
        throw "autologon fixture account is not local"
    }
    $user = Get-LocalUser -Name $name
    if (-not $user.Enabled) { throw "autologon fixture account is disabled" }
    $expired = $null -ne $user.PasswordExpires -and $user.PasswordExpires -le (Get-Date)
    Add-Content -Path $log -Value "autologon: account=$name passwordExpired=$expired" -Encoding UTF8
    Set-LocalUser -Name $name -PasswordNeverExpires $true
    $user = Get-LocalUser -Name $name
    if ($null -ne $user.PasswordExpires) { throw "fixture password still has an expiry date" }
    Add-Content -Path $log -Value "autologon: fixture password expiry disabled; credentials unchanged" -Encoding UTF8
    if ($expired) { Write-Output "autologon-account-ready restart=1" }
    else { Write-Output "autologon-account-ready restart=0" }
} catch {
    Add-Content -Path $log -Value "autologon: provisioning failed: $_" -Encoding UTF8
    throw
}' 2>&1); then
        printf '%s\n' "$result" >&2
        infra_fail "autologon-provisioning: could not prepare the local GUI fixture account (or write C:\\OEM\\wootc-e2e.log)"
        return 1
    fi
    # shellcheck disable=SC2034 # Returned to the scenario in caller context.
    case "$(printf '%s' "$result" | tr -d '\r')" in
        'autologon-account-ready restart=1') GUI_ACCOUNT_RESTART=true ;;
        'autologon-account-ready restart=0') ;;
        *) infra_fail "autologon-provisioning: guest did not confirm the account policy"; return 1 ;;
    esac
}

# Session-0 QGA liveness cannot satisfy schtasks /IT. A failed/empty probe must
# never be promoted to a desktop, and the deadline must stop launch entirely.
gui_wait_interactive_session() {
    local deadline user remaining pause budget="${1-120}" pattern='^interactive-user=[^[:space:]\\]+\\[^[:space:]\\]+$'
    case "$budget" in ''|*[!0-9]*) return 2;; esac
    [ "$budget" -gt 0 ] || return 2
    deadline=$(deadline_in "$budget")
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "Interactive Windows identity deadline expired"; return 1; }
    "${WOOTC_GUI_IDENTITY:?Configure GUI first}" "$remaining" || { infra_fail "Interactive desktop observation requires positive Windows identity"; return 1; }
    while ! past_deadline "$deadline"; do
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        [ "$remaining" -le 10 ] || remaining=10
        # shellcheck disable=SC2016 # PowerShell variables are literal.
        if user=$(WOOTC_QGA_CALL_TIMEOUT="$remaining" "${WOOTC_GUI_POWERSHELL:?Configure GUI first}" '$ErrorActionPreference = "Stop"; $u = (Get-CimInstance Win32_ComputerSystem).UserName; if ($u) { Write-Output "interactive-user=$u" }' 2>/dev/null); then
            user=$(printf '%s' "$user" | tr -d '\r')
            if [[ "$user" =~ $pattern ]]; then
                # UserName alone is not what schtasks /IT needs: on 9/25-9/26
                # it said wootc while `query user` was empty and the launch
                # task never ran (Last Result 267011). Only a session the
                # scheduler itself can enumerate counts as ready.
                # shellcheck disable=SC2016 # PowerShell variables are literal.
                if sessions=$(WOOTC_QGA_CALL_TIMEOUT="$remaining" "${WOOTC_GUI_POWERSHELL:?Configure GUI first}" '(query user 2>&1) -join " | "' 2>/dev/null) \
                    && [[ -n "$sessions" && "$sessions" != *"No User exists"* ]]; then
                    pass "GUI interactive session ready: ${user#interactive-user=} (query user: $sessions)"
                    return 0
                fi
            fi
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=5
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
    # Deliberately not a retryable flake: another copy of the same expired or
    # misconfigured snapshot cannot fix itself on a second hosted runner.
    infra_fail "autologon-no-session: Win32_ComputerSystem.UserName never paired with a query-user session within $budget s; GUI was not scheduled"
    # The deadline has expired. Do not issue a new guest diagnostic/write
    # beyond it; the infrastructure ledger above retains the refusal.
    return 1
}

gui_servicing_probe() {
    local result
    # Nonempty typed output binds the successful registry read to Windows.
    # shellcheck disable=SC2016
    result=$(WOOTC_QGA_CALL_TIMEOUT=10 "${WOOTC_GUI_POWERSHELL:?Configure GUI first}" '
$ErrorActionPreference = "Stop"
$pending = @()
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $pending += "servicing" }
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $pending += "windows-update" }
$result = @{ schemaVersion = 1; os = $env:OS; pending = @($pending) }
$result | ConvertTo-Json -Compress -Depth 4
' 2>/dev/null) || return 1
    printf '%s' "$result" | python3 "${WOOTC_GUI_SCRIPT_DIR:?Configure GUI first}/gui-servicing-receipt.py"
}

gui_settle_pending_servicing() {
    "${WOOTC_GUI_IDENTITY:?Configure GUI first}" || { infra_fail "GUI servicing preparation requires positive Windows identity"; return 1; }
    # Best effort per service; these calls do not establish servicing readiness.
    # shellcheck disable=SC2016
    "${WOOTC_GUI_POWERSHELL:?Configure GUI first}" 'foreach ($svc in "wuauserv","UsoSvc","WaaSMedicSvc") {
  try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
  try { Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
}
Write-Output "update service stop requested"' >/dev/null 2>&1 || true
    info "Windows Update service stop requested for the test fixture"
    local pending
    pending=$(gui_servicing_probe) || { infra_fail "GUI servicing status is unknown; launch refused"; return 1; }
    if [ "$pending" = clean ]; then
        info "Windows reports no pending servicing operation"
        return 0
    fi
    info "Windows reports $pending; restarting as the app instructs"
    "${WOOTC_GUI_RESTART_WINDOWS:?Configure GUI first}" "Windows after the pending-servicing restart" || return 1
    gui_wait_interactive_session 300 || return 1
    pending=$(gui_servicing_probe) || { infra_fail "GUI servicing status after restart is unknown; launch refused"; return 1; }
    if [ "$pending" != clean ]; then
        infra_fail "Windows remains $pending after restart; GUI launch refused"
        return 1
    fi
    pass "Windows reports servicing cleared after restart"
}
