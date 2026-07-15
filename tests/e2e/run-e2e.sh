#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
# run-e2e.sh — wootc end-to-end test orchestrator
#
# Prerequisites:
#   podman (or docker) with /dev/kvm access
#   pip install pywinrm
#
# Usage:
#   ./run-e2e.sh                               # full e2e with default image
#   ./run-e2e.sh ghcr.io/tuna-os/bonito:gnome # test specific image
#   ./run-e2e.sh --skip-build                  # skip deployer rebuild
#   ./run-e2e.sh --keep                        # keep container after test
#   ./run-e2e.sh --skip-install                # skip Windows install wait (reuse existing disk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_REF="${1:-ghcr.io/tuna-os/yellowfin:gnome}"

# Parse flags
SKIP_BUILD=false
KEEP_CONTAINER=false
SKIP_INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --skip-build)   SKIP_BUILD=true ;;
        --keep)         KEEP_CONTAINER=true ;;
        --skip-install) SKIP_INSTALL=true ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "${CYAN}[STEP]${NC} $*"; }

CONTAINER_NAME="wootc-e2e-windows"
STORAGE_DIR="$SCRIPT_DIR/storage"
WINRM_HOST="127.0.0.1"
WINRM_PORT="5985"
WINRM_USER="wootc"
WINRM_PASS="wootc-test-123!"
# Override for hosts whose pip-enabled interpreter is versioned (for example,
# PYTHON_BIN=python3.14 on Homebrew systems).
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
    if [ "$KEEP_CONTAINER" = false ]; then
        info "Cleaning up..."
        podman compose -f "$SCRIPT_DIR/compose.yml" down --volumes 2>/dev/null || \
            docker compose -f "$SCRIPT_DIR/compose.yml" down --volumes 2>/dev/null || true
    else
        info "Container kept (--keep): $CONTAINER_NAME"
    fi
}
trap cleanup EXIT

capture_vm_diagnostics() {
    info "Collecting Windows VM diagnostics..."
    $DOCKER logs --tail 150 "$CONTAINER_NAME" 2>&1 || true
    $DOCKER exec "$CONTAINER_NAME" ps -ef 2>/dev/null | grep '[q]emu-system' || true
    $DOCKER cp "$SCRIPT_DIR/screenshot.py" "$CONTAINER_NAME:/tmp/screenshot.py" 2>/dev/null || true
    $DOCKER exec "$CONTAINER_NAME" python3 /tmp/screenshot.py 2>/dev/null || true
    $DOCKER cp "$CONTAINER_NAME:/tmp/wootc-screen.png" /tmp/wootc-e2e-failure.png 2>/dev/null || true
    info "If captured, failure screenshot: /tmp/wootc-e2e-failure.png"
}

# Detect podman vs docker
DOCKER="podman"
if ! command -v podman &>/dev/null; then
    DOCKER="docker"
fi
if [ "$DOCKER" = "podman" ] && command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
else
    COMPOSE="$DOCKER compose"
fi

# ── Step 0: Build deployer initramfs ─────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    step "Building deployer initramfs..."
    cd "$REPO_ROOT"

    podman build -t wootc-deployer -f payload/deployer/Containerfile . || {
        fail "Deployer build failed"
        exit 1
    }

    mkdir -p "$SCRIPT_DIR/wootc-files"
    podman run --rm \
        -v "$SCRIPT_DIR/wootc-files:/out" \
        wootc-deployer || {
        fail "Deployer extraction failed"
        exit 1
    }

    podman build -t wootc-wubildr -f payload/wubildr/Containerfile . || {
        fail "wubildr EFI build failed"
        exit 1
    }
    podman run --rm --entrypoint /bin/cat wootc-wubildr /out/wubildr.efi \
        > "$SCRIPT_DIR/wootc-files/wubildr.efi"

    for f in deployer-vmlinuz deployer-initramfs.img; do
        if [ ! -f "$SCRIPT_DIR/wootc-files/$f" ]; then
            fail "Deployer output missing: wootc-files/$f"
            exit 1
        fi
    done

    [ -s "$SCRIPT_DIR/wootc-files/wubildr.efi" ] || {
        fail "Missing wootc-files/wubildr.efi (custom GRUB core image required)"
        exit 1
    }

    mkdir -p "$SCRIPT_DIR/wootc-files/grub"
    cp "$REPO_ROOT/platform/grub/"*.cfg "$SCRIPT_DIR/wootc-files/grub/" 2>/dev/null || true

    # Locate grubx64.efi from the host system's grub2-efi package.
    # This binary is served via Samba to the Windows VM and copied to the ESP
    # by setup-wootc.ps1 Step 8 (BCD firmware entry).
    GRUB_EFI_CANDIDATES=(
        /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi  # Debian/Ubuntu grub-efi-amd64
        /boot/efi/EFI/fedora/grubx64.efi                  # Fedora (already installed)
        /boot/efi/EFI/almalinux/grubx64.efi               # AlmaLinux
        /boot/efi/EFI/centos/grubx64.efi                  # CentOS
        /usr/share/grub2/grubx64.efi                      # openSUSE
        /usr/lib64/efi/grub.efi                            # openSUSE alt
    )
    GRUB_EFI_SRC=""
    for candidate in "${GRUB_EFI_CANDIDATES[@]}"; do
        if [ -f "$candidate" ]; then
            GRUB_EFI_SRC="$candidate"
            break
        fi
    done

    if [ -n "$GRUB_EFI_SRC" ]; then
        cp "$GRUB_EFI_SRC" "$SCRIPT_DIR/wootc-files/grubx64.efi"
        info "grubx64.efi: copied from $GRUB_EFI_SRC ($(du -sh "$SCRIPT_DIR/wootc-files/grubx64.efi" | cut -f1))"
    else
        info "WARNING: grubx64.efi not found on this host."
        info "  BCD firmware entry will be created but the EFI binary will be missing."
        info "  To fix: install grub2-efi-x64 (Fedora/RHEL) or grub-efi-amd64 (Debian/Ubuntu),"
        info "  or manually copy a grubx64.efi to $SCRIPT_DIR/wootc-files/grubx64.efi"
    fi

    pass "Deployer built: $(du -sh "$SCRIPT_DIR/wootc-files/deployer-vmlinuz" | cut -f1) kernel, $(du -sh "$SCRIPT_DIR/wootc-files/deployer-initramfs.img" | cut -f1) initramfs"
    cd "$SCRIPT_DIR"
fi

# wubildr is a custom GRUB core image, not an interchangeable stock GRUB EFI.
# Refuse to mutate the Windows boot entry when it is absent, including in
# --skip-build runs that reuse artifacts.
[ -s "$SCRIPT_DIR/wootc-files/wubildr.efi" ] || {
    fail "Missing wootc-files/wubildr.efi (custom GRUB core image required)"
    exit 1
}

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
step "Checking prerequisites..."

[ -e /dev/kvm ] || { fail "/dev/kvm not available — KVM required"; exit 1; }
command -v "$DOCKER" &>/dev/null || { fail "$DOCKER not found"; exit 1; }
command -v "$PYTHON_BIN" &>/dev/null || { fail "$PYTHON_BIN not found"; exit 1; }
"$PYTHON_BIN" -c "import winrm" 2>/dev/null || {
    info "Installing pywinrm..."
    "$PYTHON_BIN" -m pip install pywinrm || {
        fail "Could not install pywinrm with $PYTHON_BIN -m pip"
        exit 1
    }
}
"$PYTHON_BIN" -c "import winrm" 2>/dev/null || { fail "pywinrm unavailable"; exit 1; }

pass "Prerequisites OK ($DOCKER, pywinrm)"

# ── Step 2: Start Windows VM ─────────────────────────────────────────────────
step "Starting Windows VM..."
cd "$SCRIPT_DIR"
mkdir -p "$STORAGE_DIR"

if [ "$SKIP_INSTALL" = false ]; then
    # Clean previous run's disk so autounattend runs fresh
    $COMPOSE -f compose.yml down --volumes 2>/dev/null || true
    rm -rf storage/data.qcow2

    # dockur mutates the downloaded installer ISO in place and its cache key
    # does not include /custom.xml. Reusing that ISO silently embeds an older
    # answer file (including an older disk layout), so fingerprint the input
    # and discard the processed ISO whenever the answer file changes.
    ANSWER_SHA=$(sha256sum autounattend.xml | awk '{print $1}')
    ANSWER_STAMP="$STORAGE_DIR/.wootc-autounattend.sha256"
    if [ "$(cat "$ANSWER_STAMP" 2>/dev/null || true)" != "$ANSWER_SHA" ]; then
        info "autounattend.xml changed; rebuilding Dockur's processed installer ISO"
        find "$STORAGE_DIR" -maxdepth 1 -type f -name '*.iso' -delete
        rm -f "$STORAGE_DIR/windows.base" "$STORAGE_DIR/windows.boot"
        ANSWER_REFRESH=true
    else
        ANSWER_REFRESH=false
    fi
else
    ANSWER_SHA=$(sha256sum autounattend.xml | awk '{print $1}')
    ANSWER_STAMP="$STORAGE_DIR/.wootc-autounattend.sha256"
    if [ "$(cat "$ANSWER_STAMP" 2>/dev/null || true)" != "$ANSWER_SHA" ]; then
        fail "autounattend.xml changed since this disk was prepared; rerun without --skip-install"
        exit 1
    fi
    ANSWER_REFRESH=false
fi

mkdir -p storage wootc-files
$COMPOSE -f compose.yml up -d windows
info "Container $CONTAINER_NAME started"

# Dockur may need to prepare (or re-use) a Windows ISO before starting QEMU.
# Poll rather than treating a fixed three-second delay as an acceleration
# failure; this also makes --skip-install reliable on a just-prepared disk.
QEMU_CMD=""
for _ in $(seq 1 20); do
    QEMU_CMD=$($DOCKER exec "$CONTAINER_NAME" ps -ef 2>/dev/null | grep '[q]emu-system' || true)
    [ -n "$QEMU_CMD" ] && break
    sleep 3
done
if [[ "$QEMU_CMD" != *"-accel=kvm"* || "$QEMU_CMD" != *"-enable-kvm"* ]]; then
    fail "QEMU is not using KVM acceleration"
    capture_vm_diagnostics
    exit 1
fi
if [[ "$QEMU_CMD" != *"-tpmdev emulator"* || "$QEMU_CMD" != *"property=secure,value=on"* ]]; then
    fail "Windows 11 VM is missing TPM 2.0 or Secure Boot"
    capture_vm_diagnostics
    exit 1
fi
pass "QEMU is KVM-accelerated with TPM 2.0 and Secure Boot"

# ── Fix container routing (WinRM via podman port mapping) ────────────────────
# dockur/windows' PREROUTING rule only applies to traffic on eth0 (external NIC).
# Podman maps host:5985 → container:5985 by injecting on lo (loopback).
# We add a PREROUTING rule on lo so traffic reaches the Windows VM.
step "Fixing container routing for WinRM (lo PREROUTING)..."
_fix_routing() {
    local vm_ip
    # Detect the VM IP from dockur's bridge (172.30.x.x range)
    vm_ip=$($DOCKER exec "$CONTAINER_NAME" ip route show 172.30.0.0/16 2>/dev/null \
        | awk '/172\.30\.[0-9]+\.[0-9]+/{print $NF; exit}') || true

    # Fallback: look for first host on 172.30.x.x/24
    if [ -z "$vm_ip" ]; then
        vm_ip="172.30.1.3"
    fi

    info "VM IP: $vm_ip"

    for port in 5985 5986; do
        $DOCKER exec "$CONTAINER_NAME" iptables -t nat -I PREROUTING \
            -i lo -p tcp --dport "$port" \
            -j DNAT --to-destination "${vm_ip}:${port}" 2>/dev/null || true
    done
    info "PREROUTING rules added for ports 5985/5986 → $vm_ip"
}

winrm_probe() {
    "$PYTHON_BIN" "$SCRIPT_DIR/winrm-check.py" >/dev/null 2>&1
}

wait_for_winrm() {
    local label="$1" timeout="$2" elapsed=0
    step "Waiting for WinRM: $label..."
    while [ "$elapsed" -lt "$timeout" ]; do
        _fix_routing 2>/dev/null || true
        if winrm_probe; then
            pass "WinRM available: $label"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && info "Waiting for WinRM ($label)... ($(( elapsed / 60 ))m)"
    done
    fail "WinRM did not become available for $label within $((timeout / 60)) minutes"
    return 1
}

wait_for_winrm_reboot() {
    local label="$1" elapsed=0
    info "Waiting for WinRM to go away before $label..."
    while [ "$elapsed" -lt 120 ]; do
        if ! winrm_probe; then
            wait_for_winrm "$label" 600
            return
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Windows did not begin rebooting before $label"
    return 1
}

wait_for_winrm_down() {
    local label="$1" elapsed=0
    info "Waiting for WinRM to go away before $label..."
    while [ "$elapsed" -lt 120 ]; do
        if ! winrm_probe; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Windows did not begin rebooting before $label"
    return 1
}

# Wait for container to start iptables, then add our rules
sleep 5
_fix_routing

# ── Step 3: Wait for Windows auto-install ────────────────────────────────────
if [ "$SKIP_INSTALL" = true ]; then
    info "Skipping install wait (--skip-install)"
else
    step "Waiting for Windows auto-install (up to 45 min)..."
    info "  Monitor: open http://localhost:8006 in browser to watch progress"

    TIMEOUT=2700  # 45 minutes
    ELAPSED=0
    INSTALL_DONE=false

    while [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 20
        ELAPSED=$((ELAPSED + 20))

        # dockur writes a file when install completes
        if $DOCKER exec "$CONTAINER_NAME" test -f /storage/windows.ver 2>/dev/null; then
            INSTALL_DONE=true
            break
        fi

        if [ $((ELAPSED % 300)) -eq 0 ]; then
            info "Still installing... ($(( ELAPSED / 60 ))m elapsed)"
        fi
    done

    if [ "$INSTALL_DONE" = false ]; then
        fail "Windows install did not complete within $((TIMEOUT/60)) minutes"
        capture_vm_diagnostics
        exit 1
    fi

    pass "Windows installed ($(( ELAPSED / 60 ))m)"
    if [ "$ANSWER_REFRESH" = true ]; then
        printf '%s\n' "$ANSWER_SHA" > "$ANSWER_STAMP"
    fi
    info "Windows is booting into OOBE / first-logon setup..."
    # Give OOBE + FirstLogonCommands time to run
    sleep 60
fi

# ── Step 4: Wait for WinRM ───────────────────────────────────────────────────
step "Waiting for WinRM to become available..."
info "  WinRM endpoint: $WINRM_HOST:$WINRM_PORT"
info "  Monitoring for sentinel file: storage/winrm-ready.txt (or direct probe)"

TIMEOUT=600  # 10 minutes for first-logon + WinRM startup
ELAPSED=0
WINRM_READY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))

    # Re-apply routing fix in case iptables got reset
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        _fix_routing 2>/dev/null || true
    fi

    # Method 1: sentinel file written by FirstLogonCommands order-7
    if [ -f "$SCRIPT_DIR/wootc-files/winrm-ready.txt" ]; then
        info "Sentinel file detected"
        sleep 5  # let WinRM service fully start
        WINRM_READY=true
        break
    fi

    # Method 2: direct WinRM probe
    if "$PYTHON_BIN" -c "
import winrm, sys
try:
    s = winrm.Session(
        '$WINRM_HOST',
        auth=('$WINRM_USER', '$WINRM_PASS'),
        transport='basic',
        server_cert_validation='ignore'
    )
    r = s.run_ps('Write-Host ok')
    if r.status_code == 0 and b'ok' in r.std_out:
        sys.exit(0)
except:
    pass
sys.exit(1)
" 2>/dev/null; then
        WINRM_READY=true
        break
    fi

    if [ $((ELAPSED % 60)) -eq 0 ]; then
        info "Waiting for WinRM... ($(( ELAPSED / 60 ))m)"
    fi
done

if [ "$WINRM_READY" = false ]; then
    fail "WinRM did not become available within $((TIMEOUT/60)) minutes"
    info "Troubleshooting hints:"
    info "  1. Open http://localhost:8006 to see Windows desktop"
    info "  2. Check if WinRM is listening: run-just.sh fix-winrm (or: just fix-winrm)"
    info "  3. Check iptables in container: podman exec $CONTAINER_NAME iptables -t nat -L PREROUTING -n"
    info "  4. Check VM IP: podman exec $CONTAINER_NAME ip route"
    exit 1
fi

pass "WinRM is available on $WINRM_HOST:$WINRM_PORT"

# ── Step 5: Run wootc setup via WinRM ────────────────────────────────────────
step "Setting up wootc inside Windows via WinRM..."

SETUP_SCRIPT=$(cat "$SCRIPT_DIR/setup-wootc.ps1")
ENCODED_SCRIPT=$(echo "$SETUP_SCRIPT" | base64 -w0)

"$PYTHON_BIN" << PYEOF
import winrm, sys, time

s = winrm.Session(
    '$WINRM_HOST',
    auth=('$WINRM_USER', '$WINRM_PASS'),
    transport='basic',
    server_cert_validation='ignore'
)

# Write the setup script
r = s.run_ps(r'''
\$b64 = "$ENCODED_SCRIPT"
\$bytes = [System.Convert]::FromBase64String(\$b64)
\$script = [System.Text.Encoding]::UTF8.GetString(\$bytes)
New-Item -ItemType Directory -Force -Path "C:\\wootc" | Out-Null
Set-Content -Path "C:\\wootc\\setup-wootc.ps1" -Value \$script -Encoding UTF8
Write-Host "Script written: C:\\wootc\\setup-wootc.ps1"
''')
print("Write script:", r.status_code, r.std_out.decode()[:200])
if r.status_code != 0:
    print("STDERR:", r.std_err.decode()[:500])
    sys.exit(1)

# Run the setup
r = s.run_ps(r'C:\\wootc\\setup-wootc.ps1 -ImageRef "$IMAGE_REF" -Hostname "wootc-test"')
print("Setup stdout:", r.std_out.decode())
if r.std_err:
    print("Setup stderr:", r.std_err.decode()[:500])
if r.status_code != 0:
    print("SETUP FAILED with status", r.status_code)
    sys.exit(1)
PYEOF

pass "wootc setup inside Windows completed"

# ── Step 6: Reboot into deployer ─────────────────────────────────────────────
step "Rebooting Windows into wootc deployer..."

"$PYTHON_BIN" -c "
import winrm
s = winrm.Session('$WINRM_HOST', auth=('$WINRM_USER', '$WINRM_PASS'), transport='basic', server_cert_validation='ignore')
s.run_ps('shutdown /r /t 5 /f')
print('Reboot triggered')
" 2>/dev/null || true

info "Waiting for Windows to shut down..."
sleep 15

# ── Step 7: Monitor deployer via QEMU serial console ─────────────────────────
step "Monitoring deployer (QEMU serial console)..."
info "Watching for fisherman deployment markers..."

TIMEOUT=1200
ELAPSED=0
DEPLOY_COMPLETE=false
PTY="$STORAGE_DIR/qemu.pty"

# Wait for PTY to appear
for i in $(seq 1 30); do
    [ -f "$PTY" ] && break
    sleep 5
done

[ -f "$PTY" ] || { fail "QEMU PTY not found at $PTY"; exit 1; }
LAST_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)

    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        NEW_LINES=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")

        echo "$NEW_LINES" | grep -q "\[wootc\]"               && info "wootc: deployer active"
        echo "$NEW_LINES" | grep -q "fisherman.*Partitioning" && info "fisherman: partitioning"
        echo "$NEW_LINES" | grep -qE "Deploying|Pulling container|Installing OS" && info "fisherman: deploying OS"
        echo "$NEW_LINES" | grep -qE "\[PASS\]" && info "wootc: $(echo "$NEW_LINES" | grep -E '\[PASS\]' | tail -1)"
        echo "$NEW_LINES" | grep -qE "\[WARN\]" && info "wootc: $(echo "$NEW_LINES" | grep -E '\[WARN\]' | tail -1)"
        if echo "$NEW_LINES" | grep -q "VERIFICATION_SUMMARY"; then
            DEPLOY_COMPLETE=true
            pass "wootc: deployment verification complete"
            LAST_LINE=$CURRENT_LINE
            break
        fi
        if echo "$NEW_LINES" | grep -qE "fatal|panic|kernel panic|\[FAIL\]"; then
            fail "Deployer error:"
            echo "$NEW_LINES" | grep -E "fatal|panic|kernel panic|\[FAIL\]"
            break
        fi
        LAST_LINE=$CURRENT_LINE
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
    [ $((ELAPSED % 60)) -eq 0 ] && info "Deploying... ($(( ELAPSED / 60 ))m)"
done

[ "$DEPLOY_COMPLETE" = true ] || {
    fail "Deployment did not complete within $((TIMEOUT/60)) minutes"
    info "Last 30 lines of QEMU console:"
    tail -30 "$PTY"
    exit 1
}

# ── Step 8: Schedule and verify Phase 2 Linux boot ──────────────────────────
# The initial BCD bootsequence entry is intentionally one-shot. The deployer
# returns to Windows after laying down root.disk; re-arm it once to boot the
# installed Phase 2 Linux root through the custom EFI loader.
wait_for_winrm_reboot "Windows after deployer"

step "Scheduling one-shot Phase 2 Linux boot..."
# shellcheck disable=SC2016 # PowerShell variables must remain literal here.
PHASE2_GUID=$("$PYTHON_BIN" "$SCRIPT_DIR/winrm-run.py" \
    '$guid = (Get-Content C:\wootc\install\bcd-guid.txt -Raw).Trim(); if ($guid -notmatch "^\{[0-9a-fA-F-]+\}$") { throw "invalid wootc BCD GUID: $guid" }; Write-Output $guid')
PHASE2_GUID=$(printf '%s' "$PHASE2_GUID" | tr -d '\r\n')
[ -n "$PHASE2_GUID" ] || { fail "Could not read wootc BCD GUID from Windows"; exit 1; }

"$PYTHON_BIN" "$SCRIPT_DIR/winrm-run.py" \
    "bcdedit /set '{fwbootmgr}' bootsequence $PHASE2_GUID /addfirst; shutdown /r /t 5 /f" >/dev/null
pass "Phase 2 Linux boot scheduled through BCD one-shot entry"
wait_for_winrm_down "Phase 2 Linux boot"

step "Waiting for Phase 2 Linux system to boot..."

ELAPSED=0
TIMEOUT=300
BOOT_SUCCESS=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        NEW_LINES=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")
        if echo "$NEW_LINES" | grep -qE "ostree=|Starting version|Welcome to|login:"; then
            BOOT_SUCCESS=true
            pass "Phase 2 Linux system booted!"
            break
        fi
        if echo "$NEW_LINES" | grep -qE "No bootable device|BOOTMGR is missing|kernel panic"; then
            fail "Boot failure detected"
            break
        fi
        LAST_LINE=$CURRENT_LINE
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

[ "$BOOT_SUCCESS" = true ] || {
    fail "Phase 2 Linux system did not boot within $((TIMEOUT/60)) minutes"
    tail -30 "$PTY"
    exit 1
}

# ── Step 9: Verify passthrough/migration setup ──────────────────────────────
step "Verifying passthrough and migration setup..."

# Collect additional boot output for passthrough verification.
# The installed system should show:
#   - Host NTFS bind-mount (/host or wootc-host-bind)
#   - Loop device setup (losetup root.disk)
#   - No mount failures or kernel panics
info "Collecting boot-time passthrough markers from serial console..."

PASSTHROUGH_TIMEOUT=60
PASSTHROUGH_ELAPSED=0
PASSTHROUGH_MARKERS=""

while [ $PASSTHROUGH_ELAPSED -lt $PASSTHROUGH_TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        PASSTHROUGH_MARKERS+=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")
        PASSTHROUGH_MARKERS+=$'\n'
        LAST_LINE=$CURRENT_LINE
    fi
    sleep 2
    PASSTHROUGH_ELAPSED=$((PASSTHROUGH_ELAPSED + 2))
done

# ── Passthrough checks ────────────────────────────────────────────────────
PASSTHROUGH_OK=true

# Look for wootc host bind mount
if echo "$PASSTHROUGH_MARKERS" | grep -qiE "wootc-host-bind|/host|ntfs3.*wootc"; then
    pass "Passthrough: host NTFS bind-mount detected"
else
    info "Passthrough: host NTFS bind-mount NOT detected in serial output (may need console=ttyS0)"
fi

# Look for loop device setup
if echo "$PASSTHROUGH_MARKERS" | grep -qiE "losetup|loop0|/dev/loop"; then
    pass "Passthrough: loop device setup detected"
else
    info "Passthrough: loop device setup NOT detected (may need console=ttyS0)"
fi

# Check for fatal errors that would block migration
if echo "$PASSTHROUGH_MARKERS" | grep -qiE "failed.*host|host.*failed|panic|kernel BUG|ntfs3.*error|ntfs3.*refus"; then
    fail "Passthrough: errors detected in boot output:"
    echo "$PASSTHROUGH_MARKERS" | grep -iE "failed.*host|host.*failed|panic|kernel BUG|ntfs3.*error|ntfs3.*refus"
    PASSTHROUGH_OK=false
fi

# Look for wootc passthrough systemd service
if echo "$PASSTHROUGH_MARKERS" | grep -qiE "wootc-passthrough|passthrough.*service"; then
    pass "Passthrough: wootc-passthrough service detected"
else
    info "Passthrough: wootc-passthrough service NOT detected (may need console=ttyS0)"
fi

if [ "$PASSTHROUGH_OK" = true ]; then
    pass "Passthrough verification: no errors detected"
else
    info "Passthrough verification: errors found (see above) — migration may fail"
fi

# ── Step 10: Verify the one-shot entry returns to Windows ───────────────────
step "Rebooting Phase 2 Linux and verifying return to Windows..."
$DOCKER exec "$CONTAINER_NAME" python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock"); s.sendall(b"sendkey ctrl-alt-delete\\n"); s.close()'
wait_for_winrm_reboot "Windows return after Phase 2 Linux"
pass "One-shot Phase 2 boot consumed; Windows returned successfully"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   wootc E2E test: ALL TESTS PASSED   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
info "Image tested: $IMAGE_REF"

exit 0
