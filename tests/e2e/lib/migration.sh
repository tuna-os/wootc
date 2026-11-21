# shellcheck shell=bash
# Migration suite: seed a realistic Windows profile, then hold the installed
# Linux system to it after Phase 2 and on the Phase-3 native disk.
#
#   seed (Windows, before install)  tests/e2e/oem/seed-profile.ps1, staged here
#                                   over QGA every run (never trusted from a
#                                   base image's C:\OEM), writes the expected-
#                                   state manifest; the harness keeps a copy.
#   Wi-Fi (Windows, after install)  netsh-format exports at the collector's
#                                   output boundary (QEMU has no WLAN device,
#                                   so `netsh wlan export` has nothing to read).
#   Phase 2                         runs the on-demand capabilities a user
#                                   would (browser import, folder conversion),
#                                   then tests/e2e/migration-check.py through
#                                   the agent; stages the checker for Phase 3.
#   Phase 3                         reads the export of the same checker, run
#                                   at boot by wootc-e2e-native-migration
#                                   .service (wootc-go-native, E2E-only).
#   Windows return                  re-hashes the seeded files on Windows.
#
# Every verdict goes through product_pass/product_fail as
# migration-<phase>-<category>; GAP lines (claimed, not implemented) are kept
# in migration-gaps.txt. Caller supplies the QGA wrappers, DOCKER,
# CONTAINER_NAME, ARTIFACT_DIR, SCRIPT_DIR, RUN_ID and the result helpers.

MIGRATION_GUEST_DIR='C:\ProgramData\wootc-e2e'
# Set by migration_seed once this run's manifest is on the host.
MIGRATION_EXPECTED=""
MIGRATION_LINUX_USER=wootc
MIGRATION_HOSTNAME=wootc-test
MIGRATION_CONVERT_FOLDER=Music
MIGRATION_P2_DONE=false

# The password the Windows side chose for the Linux account: the GUI
# directive's (gui-drive-directive.py) or the OEM vault's (setup-wootc.ps1).
migration_password() {
    if [ "${GUI_INSTALL:-false}" = true ]; then printf 'wootc-e2e-pass'; else printf 'wootc-e2e'; fi
}

migration_header() { # <key> <value>
    printf '#%s=%s\n' "$1" "$2" >> "$MIGRATION_EXPECTED"
}

# Copy a host file into the guest at an absolute guest path (either OS).
migration_put() { # <host file> <guest path>
    local transfer="/tmp/wootc-migration-$$-$RANDOM"
    "$DOCKER" cp "$1" "$CONTAINER_NAME:$transfer" >/dev/null &&
        WOOTC_QGA_CALL_TIMEOUT=120 qga_call write "$transfer" "$2" >/dev/null
}

# Seed the profile and fetch the manifest. Prints the script's own output on
# failure; returns non-zero when the manifest for THIS run is not readable.
migration_seed() { # <drive> <windows user>
    local drive="$1" guser="$2" staged="$ARTIFACT_DIR/seed-profile.ps1" out
    MIGRATION_EXPECTED="$ARTIFACT_DIR/migration-expected.tsv"
    rm -f "$MIGRATION_EXPECTED"
    # PS 5.1 needs BOM + CRLF (AGENTS.md R4).
    { printf '\xEF\xBB\xBF'; sed 's/$/\r/' "$SCRIPT_DIR/oem/seed-profile.ps1"; } > "$staged" || return 1
    qga_powershell "New-Item -ItemType Directory -Force -Path '$MIGRATION_GUEST_DIR' | Out-Null" >/dev/null || return 1
    migration_put "$staged" "$MIGRATION_GUEST_DIR\\seed-profile.ps1" || { warn "Migration seed: could not stage seed-profile.ps1"; return 1; }
    # The QGA client stops any guest command at 60 s, and the corpus (64 MiB
    # written and hashed) can take longer: run the seed detached and poll.
    local wrapper="$ARTIFACT_DIR/seed-run.ps1" done_file="$MIGRATION_GUEST_DIR\\seed.done" deadline
    {
        printf '\xEF\xBB\xBF'
        printf '%s\r\n' "\$ErrorActionPreference = 'Stop'" \
            "Remove-Item -LiteralPath '$done_file' -Force -ErrorAction SilentlyContinue" \
            "try {" \
            "    & '$MIGRATION_GUEST_DIR\\seed-profile.ps1' -Username '$guser' -Drive '$drive' -RunId '$RUN_ID' -ManifestPath '$MIGRATION_GUEST_DIR\\migration-expected.tsv' *>&1 | Out-File -Encoding utf8 '$MIGRATION_GUEST_DIR\\seed.log'" \
            "    'SEED-OK $RUN_ID' | Set-Content -LiteralPath '$done_file'" \
            "} catch {" \
            "    ('SEED-FAILED: ' + \$_.Exception.Message + ' at ' + \$_.InvocationInfo.PositionMessage) | Set-Content -LiteralPath '$done_file'" \
            "}"
    } > "$wrapper" || return 1
    migration_put "$wrapper" "$MIGRATION_GUEST_DIR\\seed-run.ps1" || return 1
    qga_powershell "Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$MIGRATION_GUEST_DIR\\seed-run.ps1')" >/dev/null || return 1
    deadline=$(deadline_in 900)
    out=""
    until printf '%s' "$out" | grep -q "SEED-OK $RUN_ID\|SEED-FAILED"; do
        past_deadline "$deadline" && break
        sleep 10
        out=$(qga_read "$done_file" 2>/dev/null || true)
    done
    { qga_read "$MIGRATION_GUEST_DIR\\seed.log" 2>/dev/null || true; printf '%s\n' "$out"; } > "$ARTIFACT_DIR/seed-profile.log"
    if ! printf '%s' "$out" | grep -q "SEED-OK $RUN_ID"; then
        printf '%s\n' "${out:-seed did not finish within 900 s}" | tail -8 | sed 's/^/    seed: /'
        return 1
    fi
    qga_read "$MIGRATION_GUEST_DIR\\migration-expected.tsv" > "$MIGRATION_EXPECTED" 2>/dev/null || return 1
    grep -qx "#runId=$RUN_ID" "$MIGRATION_EXPECTED" || return 1
    migration_header linuxUser "$MIGRATION_LINUX_USER"
    migration_header password "$(migration_password)"
    migration_header hostname "$MIGRATION_HOSTNAME"
    info "Migration seed: $(grep -vc '^#' "$MIGRATION_EXPECTED") expected items recorded ($(awk -F'\t' '!/^#/{s+=$3} END{printf "%.0f MiB", s/1048576}' "$MIGRATION_EXPECTED"))"
}

# Saved Wi-Fi networks, written where the installer's collector writes them
# (<storage>\wootc\install\wifi, `netsh wlan export profile key=clear`
# format) after the install step ran and before the deployer reboot.
migration_seed_wifi() { # <storage root, e.g. C:>
    local root="$1" dir ssid auth key expect onex n=0 suffix
    [ -s "$MIGRATION_EXPECTED" ] || { warn "Migration Wi-Fi: no manifest, not seeding"; return 1; }
    info "Migration Wi-Fi: wireless interfaces on Windows: $(qga_powershell 'netsh wlan show interfaces' 2>&1 | tr -s '\r\n ' ' ' | cut -c1-120)"
    dir=$(mktemp -d)
    suffix=$(printf '%s' "$RUN_ID" | sha256sum | cut -c1-6)
    qga_powershell "New-Item -ItemType Directory -Force -Path '$root\\wootc\\install\\wifi' | Out-Null" >/dev/null || return 1
    while IFS='|' read -r ssid auth key expect; do
        n=$((n + 1))
        onex=""
        [ "$expect" = skip ] && onex='<OneX xmlns="http://www.microsoft.com/networking/OneX/v1"><EAPConfig/></OneX>'
        python3 - "$dir/profile-$n.xml" "$ssid" "$auth" "$key" "$onex" <<'PYWIFI' || return 1
import sys
from xml.sax.saxutils import escape
path, ssid, auth, key, onex = sys.argv[1:]
encryption = {"open": "none", "WPA2PSK": "AES", "WPA3SAE": "AES", "WPA2": "AES"}[auth]
shared = (f"<sharedKey><keyType>passPhrase</keyType><protected>false</protected>"
          f"<keyMaterial>{escape(key)}</keyMaterial></sharedKey>") if key else ""
body = f"""<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>{escape(ssid)}</name>
	<SSIDConfig><SSID><hex>{ssid.encode().hex().upper()}</hex><name>{escape(ssid)}</name></SSID></SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>auto</connectionMode>
	<MSM><security><authEncryption><authentication>{auth}</authentication><encryption>{encryption}</encryption><useOneX>{"true" if onex else "false"}</useOneX></authEncryption>{shared}{onex}</security></MSM>
</WLANProfile>
"""
with open(path, "w", encoding="utf-8") as stream:
    stream.write(body)
PYWIFI
        migration_put "$dir/profile-$n.xml" "$root\\wootc\\install\\wifi\\Wi-Fi-wootc-e2e-$n.xml" \
            || { rm -rf "$dir"; warn "Migration Wi-Fi: could not write profile $n"; return 1; }
        migration_header wifi "$(python3 -c 'import base64,json,sys; print(base64.b64encode(json.dumps(dict(zip(("ssid","auth","key","expect"),sys.argv[1:]))).encode()).decode())' "$ssid" "$auth" "$key" "$expect")"
    done <<EOF
Home Network $suffix|WPA2PSK|wpa2-$suffix-correct horse|wpa-psk
Café ☕ 5G $suffix|WPA3SAE|sae-$suffix-battery staple|sae
Bob's iPhone $suffix|open||none
Corp-Secure $suffix|WPA2||skip
EOF
    rm -rf "$dir"
    info "Migration Wi-Fi: $n saved networks staged in $root\\wootc\\install\\wifi"
}

# What the Windows side collected, read back before the deployer consumes it:
# the expectations for the look checks and the app selection the installer
# handed over.
migration_record_windows_handoff() { # <storage root>
    local root="$1" slurp apps
    if slurp=$(qga_read "$root\\wootc\\install\\slurp\\slurp.json" 2>/dev/null) && [ -n "$slurp" ]; then
        printf '%s' "$slurp" > "$ARTIFACT_DIR/windows-slurp.json"
        migration_header slurp "$(printf '%s' "$slurp" | base64 -w0)"
        migration_header slurpWallpaperSha256 "$(qga_powershell "(Get-ChildItem -LiteralPath '$root\\wootc\\install\\slurp' -Filter 'wallpaper.*' | Select-Object -First 1 | Get-FileHash -Algorithm SHA256).Hash.ToLowerInvariant()" 2>/dev/null | tr -d '\r\n ')"
    fi
    if apps=$(qga_read "$root\\wootc\\install\\apps.json" 2>/dev/null) && [ -n "$apps" ]; then
        printf '%s' "$apps" > "$ARTIFACT_DIR/windows-apps.json"
        info "Migration: installer handed over apps.json: $(printf '%s' "$apps" | tr -d '\r\n' | cut -c1-200)"
    fi
}

# One RESULT line per observation → the run's result ledger.
migration_record() { # <phase label> <checker output>
    local label="$1" output="$2" verdict category message
    printf '%s\n' "$output" > "$ARTIFACT_DIR/migration-$label.log"
    while IFS=$'\t' read -r _ verdict category message; do
        case "$verdict" in
            PASS) product_pass "migration-$label-$category" "Migration ($label) $category: $message" ;;
            FAIL) product_fail "Migration ($label) $category: $message" ;;
            GAP) info "Migration ($label) GAP $category: $message"
                 printf '%s\t%s\t%s\n' "$label" "$category" "$message" >> "$ARTIFACT_DIR/migration-gaps.txt" ;;
            SKIP) info "Migration ($label) skipped $category: $message" ;;
        esac
    done < <(printf '%s\n' "$output" | grep $'^RESULT\t')
    if ! printf '%s\n' "$output" | grep -qx 'MIGRATION_CHECK_DONE'; then
        infra_fail "Migration ($label): the check did not run to completion"
        printf '%s\n' "$output" | tail -15 | sed 's/^/    /'
        return 1
    fi
}

# Phase 2: exercise the on-demand capabilities, run the check, and leave the
# checker + manifest in /run where wootc-go-native carries them to the
# native disk. Runs once, before any graduation.
migration_check_phase2() {
    [ "$MIGRATION_P2_DONE" = true ] && return 0
    MIGRATION_P2_DONE=true
    step "Migration suite: checking the Windows profile against Phase 2..."
    if [ ! -s "$MIGRATION_EXPECTED" ]; then
        infra_fail "Migration (phase2): no seed manifest for this run; nothing to check against"
        return 1
    fi
    local winuser out
    winuser=$(sed -n 's/^#windowsUser=//p' "$MIGRATION_EXPECTED" | tail -1)
    # Wait for the boot-time bridges a first login would find finished.
    # shellcheck disable=SC2016
    WOOTC_QGA_CALL_TIMEOUT=55 qga_call exec /bin/sh -c \
        'for i in $(seq 1 16); do s=$(systemctl show -p ActiveState --value wootc-passthrough.service); [ "$s" = active ] || [ "$s" = failed ] && break; sleep 3; done; true' >/dev/null 2>&1 || true
    # Browser import is on demand (SPEC §4.2 stage 3): the user picks it.
    out=$(WOOTC_QGA_CALL_TIMEOUT=55 qga_call exec /bin/sh -c \
        "WOOTC_HOST=/run/wootc/host timeout 50 /var/usrlocal/bin/wootc-import-browser '$winuser' '$MIGRATION_LINUX_USER' 2>&1; echo rc=\$?" 2>&1 || true)
    printf '%s\n' "$out" > "$ARTIFACT_DIR/migration-browser-import.log"
    info "Migration: browser import: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-240)"
    migration_header browserImport 1
    # Stage 4: convert one bridged folder to native storage.
    out=$(WOOTC_QGA_CALL_TIMEOUT=55 qga_call exec /bin/sh -c \
        "o=\$(timeout 50 /var/usrlocal/bin/wootc-convert-dir '$MIGRATION_LINUX_USER' '$MIGRATION_CONVERT_FOLDER' 2>&1); rc=\$?; printf '%s\n' \"\$o\" | grep -v '^PROGRESS' | tail -5; echo rc=\$rc" 2>&1 || true)
    printf '%s\n' "$out" > "$ARTIFACT_DIR/migration-convert.log"
    info "Migration: convert ~/$MIGRATION_CONVERT_FOLDER: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-240)"
    migration_header convertedFolder "$MIGRATION_CONVERT_FOLDER"
    if ! migration_put "$SCRIPT_DIR/migration-check.py" /run/wootc-e2e-migration-check.py \
        || ! migration_put "$MIGRATION_EXPECTED" /run/wootc-e2e-migration-expected.tsv; then
        infra_fail "Migration (phase2): could not stage the check in the guest"
        return 1
    fi
    # Detached (a login, Flatpak launches and ~80 MiB of hashing outlast the
    # agent's 60 s command limit); poll its output file for the done line.
    local deadline result=/run/wootc-e2e-migration-phase2.out
    WOOTC_QGA_CALL_TIMEOUT=30 qga_call exec /bin/sh -c \
        "rm -f $result; setsid nohup /usr/bin/python3 /run/wootc-e2e-migration-check.py phase2 /run/wootc-e2e-migration-expected.tsv > $result 2>&1 < /dev/null &" >/dev/null 2>&1 || true
    deadline=$(deadline_in 1200)
    out=""
    until printf '%s\n' "$out" | grep -qx 'MIGRATION_CHECK_DONE'; do
        past_deadline "$deadline" && break
        sleep 10
        out=$(WOOTC_QGA_CALL_TIMEOUT=30 qga_call exec /bin/cat "$result" 2>/dev/null || true)
    done
    migration_record phase2 "$out"
}

# Phase 3: the native system ran the same check at boot; read its export.
migration_check_native() { # <native boot id>
    local boot="$1" export="" deadline status
    step "Migration suite: checking the Windows profile against the native disk..."
    deadline=$(deadline_in "${WOOTC_E2E_MIGRATION_WAIT_SECS:-900}")
    while :; do
        export=$(WOOTC_QGA_CALL_TIMEOUT=30 qga_call exec /bin/sh -c \
            'cat /run/wootc-e2e-native-migration && echo MIGRATION_READ=complete' 2>/dev/null || true)
        if [ "${export##*$'\n'}" = MIGRATION_READ=complete ] \
            && printf '%s\n' "$export" | grep -qx 'MIGRATION_CHECK_DONE'; then
            export=${export%$'\n'MIGRATION_READ=complete}
            break
        fi
        export=""
        past_deadline "$deadline" && break
        sleep 10
    done
    if [ "$(printf '%s\n' "$export" | sed -n 1p)" != MIGRATION_SCHEMA=1 ] \
        || [ "$(printf '%s\n' "$export" | sed -n 2p)" != "MIGRATION_BOOT_ID=$boot" ]; then
        printf '%s\n' "$export" | head -5
        infra_fail "Migration (native): export absent, incomplete or not from this boot ($boot)"
        return 1
    fi
    status=$(printf '%s\n' "$export" | sed -n 's/^MIGRATION_STATUS=//p;3q')
    [ "$status" = 0 ] || info "Migration (native): checker exited $status"
    migration_record native "$(printf '%s\n' "$export" | tail -n +4)"
}

# After Linux hands the machine back: every seeded file is still the bytes
# Windows wrote (Phase 2 bridged these folders read-write).
migration_check_windows_intact() {
    local out
    [ -s "$MIGRATION_EXPECTED" ] || return 0
    out=$(WOOTC_QGA_CALL_TIMEOUT=600 qga_powershell "\$m = '$MIGRATION_GUEST_DIR\\migration-expected.tsv'; \$root = ((Get-Content -LiteralPath \$m -Encoding UTF8) | Where-Object { \$_ -like '#profileRoot=*' } | Select-Object -First 1).Substring(13); \$bad = @(); \$n = 0; foreach (\$line in (Get-Content -LiteralPath \$m -Encoding UTF8)) { if (\$line.StartsWith('#')) { continue }; \$f = \$line.Split([char]9); if (\$f[0] -ne 'file') { continue }; \$n++; \$p = Join-Path \$root (\$f[1].Replace('/', '\\')); if (-not (Test-Path -LiteralPath \$p)) { \$bad += ('missing ' + \$f[1]); continue }; if ((Get-FileHash -LiteralPath \$p -Algorithm SHA256).Hash.ToLowerInvariant() -ne \$f[3]) { \$bad += ('changed ' + \$f[1]) } }; if (\$bad.Count) { 'WINDOWS-CHANGED ' + (\$bad -join ' | ') } else { 'WINDOWS-INTACT ' + \$n }" 2>&1 || true)
    case "$out" in
        *WINDOWS-INTACT*) product_pass migration-windows-intact "Migration (windows) the $(printf '%s' "$out" | sed -n 's/.*WINDOWS-INTACT \([0-9]*\).*/\1/p') seeded files are unchanged on Windows after Linux used them" ;;
        *WINDOWS-CHANGED*) product_fail "Migration (windows) seeded Windows files changed: $(printf '%s' "$out" | sed -n 's/.*WINDOWS-CHANGED //p' | cut -c1-400)" ;;
        *) infra_fail "Migration (windows) could not re-hash the seeded files: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
    esac
}
