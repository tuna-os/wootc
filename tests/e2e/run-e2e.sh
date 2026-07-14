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

# Detect podman vs docker
DOCKER="podman"
if ! command -v podman &>/dev/null; then
    DOCKER="docker"
fi
COMPOSE="$DOCKER compose"

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

    for f in vmlinuz initramfs.img; do
        if [ ! -f "$SCRIPT_DIR/wootc-files/$f" ]; then
            fail "Deployer output missing: wootc-files/$f"
            exit 1
        fi
    done

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

    pass "Deployer built: $(du -sh "$SCRIPT_DIR/wootc-files/vmlinuz" | cut -f1) kernel, $(du -sh "$SCRIPT_DIR/wootc-files/initramfs.img" | cut -f1) initramfs"
    cd "$SCRIPT_DIR"
fi

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
step "Checking prerequisites..."

[ -e /dev/kvm ] || { fail "/dev/kvm not available — KVM required"; exit 1; }
command -v "$DOCKER" &>/dev/null || { fail "$DOCKER not found"; exit 1; }
python3 -c "import winrm" 2>/dev/null || {
    info "Installing pywinrm..."
    pip install pywinrm
}
python3 -c "import winrm" 2>/dev/null || { fail "pywinrm unavailable"; exit 1; }

pass "Prerequisites OK ($DOCKER, pywinrm)"

# ── Step 2: Start Windows VM ─────────────────────────────────────────────────
step "Starting Windows VM..."
cd "$SCRIPT_DIR"

if [ "$SKIP_INSTALL" = false ]; then
    # Clean previous run's disk so autounattend runs fresh
    $COMPOSE -f compose.yml down --volumes 2>/dev/null || true
    rm -rf storage/data.qcow2
fi

mkdir -p storage wootc-files
$COMPOSE -f compose.yml up -d windows
info "Container $CONTAINER_NAME started"

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

        # Also watch for VM disk growing past 5GB (means install copied files)
        if [ -f "$STORAGE_DIR/data.qcow2" ]; then
            QCOW_SIZE=$(du -s "$STORAGE_DIR/data.qcow2" 2>/dev/null | cut -f1)
            if [ "${QCOW_SIZE:-0}" -gt 5000000 ]; then  # >5GB
                INSTALL_DONE=true
                break
            fi
        fi

        if [ $((ELAPSED % 300)) -eq 0 ]; then
            info "Still installing... ($(( ELAPSED / 60 ))m elapsed)"
        fi
    done

    if [ "$INSTALL_DONE" = false ]; then
        fail "Windows install did not complete within $((TIMEOUT/60)) minutes"
        exit 1
    fi

    pass "Windows installed ($(( ELAPSED / 60 ))m)"
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
    if python3 -c "
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

python3 << PYEOF
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

python3 -c "
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
        if echo "$NEW_LINES" | grep -q "Installation complete"; then
            DEPLOY_COMPLETE=true
            pass "fisherman: installation complete!"
            break
        fi
        if echo "$NEW_LINES" | grep -qE "fatal|panic|kernel panic"; then
            fail "Deployer error:"
            echo "$NEW_LINES" | grep -E "fatal|panic|kernel panic"
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

# ── Step 8: Verify bootc system boots ────────────────────────────────────────
step "Waiting for bootc system to boot..."
sleep 15

ELAPSED=0
TIMEOUT=300
BOOT_SUCCESS=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)
    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        NEW_LINES=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")
        if echo "$NEW_LINES" | grep -qE "ostree=|Starting version|Welcome to|login:"; then
            BOOT_SUCCESS=true
            pass "Bootc system booted!"
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
    fail "Bootc system did not boot within $((TIMEOUT/60)) minutes"
    tail -30 "$PTY"
    exit 1
}

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   wootc E2E test: ALL TESTS PASSED   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
info "Image tested: $IMAGE_REF"

exit 0
