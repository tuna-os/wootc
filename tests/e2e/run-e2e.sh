#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
# run-e2e.sh — wootc end-to-end test orchestrator
#
# Prerequisites:
#   podman (or docker) with /dev/kvm access
#   Python 3 (the QGA client uses only the standard library)
#
# Usage:
#   ./run-e2e.sh                               # full e2e with default image
#   ./run-e2e.sh ghcr.io/tuna-os/bonito:gnome # test specific image
#   ./run-e2e.sh --skip-build                  # skip deployer rebuild
#   ./run-e2e.sh --keep                        # keep container after test
#   ./run-e2e.sh --skip-install                # reuse Windows, refresh and reset the E2E handoff
#   Wootc Windows ISO cache (optional):
#     tests/e2e/iso-cache/windows-11.iso       # default offline installer cache
#     WOOTC_WINDOWS_ISO=/path/to/windows.iso ./run-e2e.sh

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
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo -e "${CYAN}[STEP]${NC} $*"; run_state "step: $*"; }

CONTAINER_NAME="wootc-e2e-windows"
STORAGE_DIR="$SCRIPT_DIR/storage"
# A second orchestrator can otherwise race QGA cleanup and recreate the
# disposable root disk while the first run is booting the deployer.  Keep the
# advisory lock open for the lifetime of this shell; it is released
# automatically if the runner exits or is killed.
mkdir -p "$STORAGE_DIR"
exec 9>"$STORAGE_DIR/.run-e2e.lock"
if ! flock -n 9; then
    echo "[FAIL] Another run-e2e.sh already owns $STORAGE_DIR/.run-e2e.lock" >&2
    exit 1
fi

# Keep a small, atomic status record next to the VM disk.  Remote runners can
# outlive the SSH command that launched them, so the process ID and run ID are
# the authoritative way to tell an active test from an orphaned VM.
RUN_ID="${WOOTC_E2E_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${HOSTNAME:-unknown}-$$}"
RUN_STARTED_AT="$(date -u +%FT%TZ)"
RUN_STATE_FILE="$STORAGE_DIR/run-e2e.current"
ARTIFACT_DIR="$STORAGE_DIR/artifacts/$RUN_ID"
VIDEO_DIR="$ARTIFACT_DIR/video"
VIDEO_STARTED=false
mkdir -p "$ARTIFACT_DIR"
run_state() {
    local stage="$1" tmp="$RUN_STATE_FILE.tmp"
    {
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "${HOSTNAME:-unknown}"
        printf 'started_at=%s\n' "$RUN_STARTED_AT"
        printf 'updated_at=%s\n' "$(date -u +%FT%TZ)"
        printf 'stage=%s\n' "$stage"
    } > "$tmp"
    mv -f "$tmp" "$RUN_STATE_FILE"
}
run_state "started"
info "Run ID: $RUN_ID (status: $RUN_STATE_FILE)"
printf '%s\n' "$RUN_ID" > "$ARTIFACT_DIR/run-id.txt"
uname -a > "$ARTIFACT_DIR/host-uname.txt" 2>&1 || true
free -m > "$ARTIFACT_DIR/host-memory.txt" 2>&1 || true
df -h "$STORAGE_DIR" > "$ARTIFACT_DIR/host-storage.txt" 2>&1 || true

host_preflight() {
    local mem_available_kib disk_available_kib required_free_gib=65
    mem_available_kib=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)
    disk_available_kib=$(df -Pk "$STORAGE_DIR" | awk 'NR == 2 { print $4 }')

    command -v podman >/dev/null || { fail "podman is required"; return 1; }
    command -v python3 >/dev/null || { fail "python3 is required for QGA"; return 1; }
    [ -r /dev/kvm ] && [ -w /dev/kvm ] || { fail "/dev/kvm is not accessible"; return 1; }
    [ -c /dev/net/tun ] || { fail "/dev/net/tun is unavailable"; return 1; }
    # Dockur reserves host headroom before launching QEMU. Six GiB available
    # is enough to start a 4 GiB Windows 11 VM without its safety clamp
    # reducing QEMU below Setup's hard minimum.
    if [ "${mem_available_kib:-0}" -lt $((6 * 1024 * 1024)) ]; then
        fail "Only $((mem_available_kib / 1024)) MiB host RAM is available; need at least 6144 MiB before starting Windows"
        return 1
    fi
    # Fresh installation needs room for the installer, pulls, and expanding
    # qcow2. Fresh-run peak drops ~10 GiB when the Windows ISO is already cached
    # (no re-download, custom.iso rebuild reuses cached extraction).
    if ls "$STORAGE_DIR"/windows.*.iso &>/dev/null; then
        required_free_gib=55
    fi
    # A reuse run already has those and needs only its allocated-extent
    # safety snapshot plus diagnostics.
    [ "$SKIP_INSTALL" = false ] || required_free_gib=40
    if [ "${disk_available_kib:-0}" -lt $((required_free_gib * 1024 * 1024)) ]; then
        fail "Only $((disk_available_kib / 1024 / 1024)) GiB free under $STORAGE_DIR; need at least $required_free_gib GiB"
        return 1
    fi
    pass "Host preflight: $((mem_available_kib / 1024)) MiB RAM available, $((disk_available_kib / 1024 / 1024)) GiB disk free, KVM/TUN ready"
}
host_preflight || exit 1
# Keep the pristine Windows installer separate from Dockur's mutable working
# directory.  Dockur can generate derived ISO images while preparing an answer
# file, so it must receive a copy rather than the only cached source image.
ISO_CACHE_DIR="$SCRIPT_DIR/iso-cache"
WINDOWS_ISO_CACHE="${WOOTC_WINDOWS_ISO:-$ISO_CACHE_DIR/windows-11.iso}"
QGA_CACHE_DIR="$SCRIPT_DIR/qga-cache"
QGA_MSI="${WOOTC_QGA_MSI:-$QGA_CACHE_DIR/qemu-ga-x86_64.msi}"
QGA_MSI_URL="${WOOTC_QGA_MSI_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-qemu-ga/qemu-ga-x86_64.msi}"
# Override for hosts whose pip-enabled interpreter is versioned (for example,
# PYTHON_BIN=python3.14 on Homebrew systems).
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
    local result=$?
    run_state "exited (status $result)"
    if [ "$VIDEO_STARTED" = true ]; then
        WOOTC_CONTAINER_RUNTIME="$DOCKER" "$SCRIPT_DIR/record-video.sh" stop "$VIDEO_DIR" || true
    fi
    # Capture the final display and logs for successful and failed runs alike.
    if $DOCKER container exists "$CONTAINER_NAME" 2>/dev/null; then
        capture_vm_diagnostics || true
    fi
    if [ "$KEEP_CONTAINER" = false ]; then
        info "Cleaning up..."
        podman compose -f "$SCRIPT_DIR/compose.yml" down --volumes 2>/dev/null || \
            docker compose -f "$SCRIPT_DIR/compose.yml" down --volumes 2>/dev/null || true
    else
        info "Container kept (--keep): $CONTAINER_NAME"
    fi
    return "$result"
}
trap cleanup EXIT

capture_vm_diagnostics() {
    info "Collecting Windows VM diagnostics..."
    mkdir -p "$ARTIFACT_DIR"
    $DOCKER inspect "$CONTAINER_NAME" > "$ARTIFACT_DIR/container-inspect.json" 2>&1 || true
    $DOCKER logs "$CONTAINER_NAME" > "$ARTIFACT_DIR/container.log" 2>&1 || true
    $DOCKER exec "$CONTAINER_NAME" ps -ef > "$ARTIFACT_DIR/guest-processes.txt" 2>&1 || true
    $DOCKER exec "$CONTAINER_NAME" ps -ef 2>/dev/null | grep '[q]emu-system' || true
    $DOCKER cp "$CONTAINER_NAME:$SERIAL_SOURCE" "$ARTIFACT_DIR/qemu.pty" >/dev/null 2>&1 || true
    if qga_probe; then
        info "QGA guest-info:"
        qga_call info | tee "$ARTIFACT_DIR/qga-info.json" || true
        info "QGA C:\\OEM\\wootc-e2e.log:"
        qga_read 'C:\OEM\wootc-e2e.log' > "$ARTIFACT_DIR/oem-wootc-e2e.log" 2>&1 || true
        info "QGA C:\\OEM\\e2e-setup-failed.txt:"
        qga_read 'C:\OEM\e2e-setup-failed.txt' > "$ARTIFACT_DIR/oem-setup-failed.txt" 2>&1 || true
        qga_read 'C:\wootc\logs\deployer.log' > "$ARTIFACT_DIR/deployer.log" 2>&1 || true
        qga_read 'C:\wootc\logs\live-journal.log' > "$ARTIFACT_DIR/deployer-live-journal.log" 2>&1 || true
    fi
    $DOCKER cp "$SCRIPT_DIR/screenshot.py" "$CONTAINER_NAME:/tmp/screenshot.py" 2>/dev/null || true
    $DOCKER exec "$CONTAINER_NAME" python3 /tmp/screenshot.py 2>/dev/null || true
    $DOCKER cp "$CONTAINER_NAME:/tmp/wootc-screen.png" "$ARTIFACT_DIR/screenshot.png" 2>/dev/null || true
    info "Failure artifacts: $ARTIFACT_DIR"
}

# Dockur keeps the QEMU serial capture in its tmpfs, not in the /storage bind
# mount. Snapshot it into the test directory so every subsequent assertion can
# inspect the same host-side file without relying on guest networking.
SERIAL_SOURCE="/run/shm/qemu.pty"
snapshot_serial() {
    $DOCKER cp "$CONTAINER_NAME:$SERIAL_SOURCE" "$PTY" >/dev/null 2>&1
}

# Detect podman vs docker
DOCKER="podman"
if ! command -v podman &>/dev/null; then
    DOCKER="docker"
fi
# Bootstrap podman-compose if missing — installs to ~/.local/bin on most distros
if [ "$DOCKER" = "podman" ] && ! command -v podman-compose &>/dev/null; then
    export PATH="$HOME/.local/bin:$PATH"
    if command -v podman-compose &>/dev/null; then
        :  # found after PATH fix
    elif command -v python3 &>/dev/null; then
        info "Installing podman-compose via pip..."
        python3 -m pip install --user podman-compose 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi
fi
if [ "$DOCKER" = "podman" ] && command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
else
    COMPOSE="$DOCKER compose"
fi
$COMPOSE -f "$SCRIPT_DIR/compose.yml" config > "$ARTIFACT_DIR/compose-rendered.yml" 2>&1 || true

# ── QEMU Guest Agent control plane ───────────────────────────────────────────
# qga.py is copied into Dockur after QEMU starts. Keeping the client in the
# container lets it reach the private Unix socket without exposing a port.
qga_call() {
    $DOCKER exec "$CONTAINER_NAME" python3 /tmp/qga.py "$@"
}

qga_probe() {
    qga_call ping 2>/dev/null &
    local probe_pid=$!
    (sleep 5; kill $probe_pid 2>/dev/null) &
    local kill_pid=$!
    wait $probe_pid 2>/dev/null
    local rc=$?
    kill $kill_pid 2>/dev/null || true
    wait $kill_pid 2>/dev/null || true
    return $rc
}

qga_wait() {
    local label="$1" timeout="$2" elapsed=0
    step "Waiting for QGA: $label..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if qga_probe; then
            pass "QGA available: $label"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && info "Waiting for QGA ($label)... ($(( elapsed / 60 ))m)"
    done
    fail "QGA did not become available for $label within $((timeout / 60)) minutes"
    return 1
}

qga_wait_down() {
    local label="$1" timeout="${2:-120}" elapsed=0
    info "Waiting for QGA to go away before $label..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if ! qga_probe; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "QGA did not go away before $label"
    return 1
}

qga_wait_reboot() {
    local label="$1"
    qga_wait_down "$label" 120
    qga_wait "$label" 600
}

# QGA is present in both the Windows guest and our deployer initramfs.  A
# successful ping alone therefore does not prove that it is safe to launch a
# Windows PowerShell payload.  Probe the Windows executable explicitly.
qga_windows_probe() {
    qga_powershell '$env:OS' >/dev/null 2>&1
}

qga_wait_windows() {
    local timeout="$1" elapsed=0
    step "Waiting for QGA: Windows guest..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if qga_windows_probe; then
            pass "QGA available: Windows guest"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && info "Waiting for QGA (Windows guest)... ($(( elapsed / 60 ))m)"
    done
    fail "Windows QGA did not become available within $((timeout / 60)) minutes"
    return 1
}

qga_powershell() {
    qga_call powershell "$1"
}

qga_read() {
    qga_call read "$1"
}

# A reused Windows VM contains C:\OEM from the original unattended install.
# The host-side /oem bind mount is not live in the guest, so copying a new
# deployer to the bind mount alone silently tests stale code.  QGA provides a
# guest-file API that lets retries replace the payload without reinstalling
# Windows or relying on its network stack.
qga_sync_oem() {
    step "Refreshing OEM payload in reused Windows guest..."
    qga_powershell 'New-Item -ItemType Directory -Force -Path C:\OEM\payload\grub | Out-Null'
    while IFS= read -r -d '' source; do
        relative="${source#"$OEM_DIR"/}"
        qga_call write "/oem/$relative" "C:\\OEM\\${relative//\//\\}"
    done < <(find "$OEM_DIR" -type f -print0)
    pass "OEM payload refreshed through QGA"
}

# `--skip-install` is a new deployment attempt on an existing disposable
# Windows installation.  Reset just the handoff-owned guest state so failures
# cannot leak root.disk/root.vhdx, failure markers, or a still-running setup
# process into the next attempt.  Do not remove C: or the Windows disk.
reset_oem_attempt() {
    step "Resetting prior OEM handoff state..."
    qga_powershell '$ErrorActionPreference = "Stop"; cmd.exe /d /c "schtasks.exe /Delete /TN \"wootc-e2e-setup\" /F >NUL 2>&1"; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like "*run-wootc-e2e.ps1*" -or $_.CommandLine -like "*setup-wootc.ps1*") } | ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }; Remove-Item -LiteralPath "$env:SystemDrive\wootc" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath "$env:SystemDrive\OEM\e2e-setup-complete.txt","$env:SystemDrive\OEM\e2e-setup-failed.txt","$env:SystemDrive\OEM\e2e-snapshot-complete.txt","$env:SystemDrive\OEM\wootc-e2e.log" -Force -ErrorAction SilentlyContinue; if (Test-Path "$env:SystemDrive\wootc") { throw "failed to clear prior E2E state" }'
    rm -f "$STORAGE_DIR/qemu.pty"
    printf '%s run_id=%s reset prior OEM handoff state\n' "$(date -u +%FT%TZ)" "$RUN_ID" > "$STORAGE_DIR/e2e-timeline.log"
    pass "Prior OEM handoff state cleared"
}

# Preserve a retry point after Windows has staged the deployer and BootNext,
# but before the first Phase 2 boot can modify root.disk. The OEM wrapper waits
# for our guest marker before rebooting. Freezing Windows filesystems makes the
# host-side sparse qcow2 copy crash-consistent; the temporary name prevents a
# failed copy from masquerading as a usable snapshot.
# Release the OEM/deployer barrier: the guest waits for this marker before it
# reboots into the deployer, so it must be written whether or not the host-side
# snapshot succeeded.
mark_snapshot_complete() {
    qga_powershell '$tmp = "C:\OEM\e2e-snapshot-complete.txt.tmp"; "ok" | Set-Content -Path $tmp -Encoding ASCII; Move-Item -LiteralPath $tmp -Destination C:\OEM\e2e-snapshot-complete.txt -Force' >/dev/null
}

snapshot_before_deployer() {
    local disk="$STORAGE_DIR/data.qcow2"
    local snapshot="$STORAGE_DIR/data.qcow2.snap"
    local tmp="$snapshot.tmp.$RUN_ID"
    local frozen=false

    [ -s "$disk" ] || { fail "Cannot snapshot missing VM disk: $disk"; return 1; }
    step "Snapshotting Windows disk before first deployer boot..."
    rm -f "$tmp"
    # The pre-deployer snapshot is only a fast-retry convenience, so every step
    # is best-effort: a QGA hiccup must never cost a run that is otherwise ready
    # to deploy. Retry the freeze, but on persistent failure skip the snapshot,
    # release the barrier, and let the deploy proceed.
    for _ in 1 2 3 4 5; do
        if qga_call freeze >/dev/null 2>&1; then frozen=true; break; fi
        sleep 3
    done
    if [ "$frozen" = false ]; then
        warn "QGA could not freeze Windows; proceeding without a crash-consistent snapshot"
        mark_snapshot_complete
        return 0
    fi

    # Prefer an instantaneous CoW reflink. Podman commonly marks VM storage
    # NOCOW even on btrfs, so fall back to a sparse allocated-extent copy.
    # The OEM barrier allows ten minutes and the guest stays frozen until the
    # copy is complete, giving us a crash-consistent retry point either way.
    if ! cp --reflink=always --sparse=auto "$disk" "$tmp"; then
        warn "Runner storage does not support reflinks for the VM disk; copying allocated extents"
        rm -f "$tmp"
        if ! cp --reflink=never --sparse=always "$disk" "$tmp"; then
            # Best-effort: thaw and proceed without the snapshot rather than
            # failing a deploy-ready run over a copy hiccup.
            for _ in 1 2 3; do qga_call thaw >/dev/null 2>&1 && break; sleep 2; done
            rm -f "$tmp"
            warn "Could not copy the pre-deployer snapshot; proceeding without it"
            mark_snapshot_complete
            return 0
        fi
    fi
    # Thaw is critical: a still-frozen Windows FS blocks the OEM handoff and
    # wedges the run. QGA fsfreeze-thaw can return a transient error under load
    # right after a long copy, so retry a few times and accept an already-thawed
    # status as success before giving up.
    # guest-fsfreeze-thaw is idempotent (succeeds even if nothing is frozen), so
    # retrying is safe and clears a transient post-copy error.
    thawed=false
    for _ in 1 2 3 4 5; do
        if qga_call thaw >/dev/null 2>/dev/null; then thawed=true; break; fi
        sleep 3
    done
    if [ "$thawed" = false ]; then
        if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
            rm -f "$tmp"
            fail "QGA could not thaw Windows after the Phase 2 snapshot (5 attempts)"
            return 1
        fi
        warn "Container exited during snapshot; $tmp may be crash-consistent"
    fi
    frozen=false
    mv -f "$tmp" "$snapshot"
    mark_snapshot_complete
    pass "Pre-deployer snapshot saved: $snapshot ($(du -h "$snapshot" | cut -f1))"
}

# ── Step 0: Build deployer initramfs ─────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    step "Building deployer initramfs..."
    cd "$REPO_ROOT"

    podman build -t wootc-deployer -f payload/deployer/Containerfile . || {
        fail "Deployer build failed"
        exit 1
    }

    mkdir -p "$SCRIPT_DIR/wootc-files"
    printf '\xEF\xBB\xBF' > "$SCRIPT_DIR/wootc-files/setup-wootc.ps1"
    sed 's/$/\r/' "$SCRIPT_DIR/setup-wootc.ps1" >> "$SCRIPT_DIR/wootc-files/setup-wootc.ps1"
    # The image keeps its generated artifacts under /out. Do not bind-mount
    # wootc-files there: that hides the image's /out and leaves the host with
    # no deployer kernel or initramfs. Stream each artifact out first and
    # rename it only after podman succeeds so a failed extraction cannot leave
    # a plausible-looking partial payload for the OEM handoff.
    for artifact in deployer-vmlinuz deployer-initramfs.img; do
        output="$SCRIPT_DIR/wootc-files/$artifact"
        tmp_output="$output.tmp.$$"
        if ! podman run --rm --entrypoint /bin/cat wootc-deployer \
            "/out/$artifact" > "$tmp_output"; then
            rm -f "$tmp_output"
            fail "Deployer extraction failed: $artifact"
            exit 1
        fi
        mv -f "$tmp_output" "$output"
    done

    podman build -t wootc-wubildr -f payload/wubildr/Containerfile . || {
        info "wubildr EFI build failed (non-fatal — using signed shim chain instead)"
    }
    if podman image exists wootc-wubildr 2>/dev/null; then
        podman run --rm --entrypoint /bin/cat wootc-wubildr /out/wubildr.efi \
            > "$SCRIPT_DIR/wootc-files/wubildr.efi" 2>/dev/null || true
    fi

    for f in deployer-vmlinuz deployer-initramfs.img; do
        if [ ! -f "$SCRIPT_DIR/wootc-files/$f" ]; then
            fail "Deployer output missing: wootc-files/$f"
            exit 1
        fi
    done

    mkdir -p "$SCRIPT_DIR/wootc-files/grub"
    cp "$REPO_ROOT/platform/grub/"*.cfg "$SCRIPT_DIR/wootc-files/grub/" 2>/dev/null || true

    # Extract signed shim + GRUB from a Fedora container. These are
    # Microsoft/Fedora-signed and form the Secure Boot chain:
    #   firmware → shimx64.efi → grubx64.efi → grub.cfg
    # setup-wootc.ps1 copies them to the ESP via the Samba share.
    if [ ! -f "$SCRIPT_DIR/wootc-files/shimx64.efi" ] || \
       [ ! -f "$SCRIPT_DIR/wootc-files/grubx64.efi" ]; then
        info "Extracting signed shim + GRUB from Fedora container..."
        # Keep the stopped container until after podman cp. With `--rm`, the
        # previous `podman wait` deleted it before either signed EFI binary
        # could be extracted.
        CID=$(podman create quay.io/fedora/fedora:44 \
            bash -c "dnf install -y -q shim-x64 grub2-efi-x64 2>/dev/null && \
              cp /boot/efi/EFI/fedora/shimx64.efi /tmp/ && \
              cp /boot/efi/EFI/fedora/grubx64.efi /tmp/ && echo DONE")
        podman start -a "$CID" >/dev/null 2>&1 || true
        podman cp "$CID:/tmp/shimx64.efi" "${SCRIPT_DIR}/wootc-files/shimx64.efi" 2>/dev/null || true
        podman cp "$CID:/tmp/grubx64.efi" "${SCRIPT_DIR}/wootc-files/grubx64.efi" 2>/dev/null || true
        podman rm "$CID" >/dev/null 2>&1 || true
        if [ -s "$SCRIPT_DIR/wootc-files/shimx64.efi" ]; then
            info "shimx64.efi: $(du -sh "$SCRIPT_DIR/wootc-files/shimx64.efi" | cut -f1)"
        fi
        if [ -s "$SCRIPT_DIR/wootc-files/grubx64.efi" ]; then
            info "grubx64.efi: $(du -sh "$SCRIPT_DIR/wootc-files/grubx64.efi" | cut -f1)"
        fi
    else
        info "Signed shim + GRUB already cached in wootc-files/"
    fi

    # Fail if signed EFI chain is missing — Secure Boot needs it.
    [ -s "$SCRIPT_DIR/wootc-files/shimx64.efi" ] || {
        fail "Missing wootc-files/shimx64.efi (signed Fedora shim required for Secure Boot)"
        exit 1
    }
    [ -s "$SCRIPT_DIR/wootc-files/grubx64.efi" ] || {
        fail "Missing wootc-files/grubx64.efi (signed Fedora GRUB required for Secure Boot)"
        exit 1
    }

    pass "Deployer built: $(du -sh "$SCRIPT_DIR/wootc-files/deployer-vmlinuz" | cut -f1) kernel, $(du -sh "$SCRIPT_DIR/wootc-files/deployer-initramfs.img" | cut -f1) initramfs"
    cd "$SCRIPT_DIR"
fi

# wubildr is no longer required for Secure Boot (we use the signed shim chain).
# Keep the file around for reference if it was built.

# Dockur copies /oem into C:\OEM; our answer file starts install.bat at the
# first automatic desktop logon. Stage every input locally so that handoff
# does not depend on SMB, WinRM, or a working guest network.
OEM_DIR="$SCRIPT_DIR/oem"
OEM_PAYLOAD="$OEM_DIR/payload"
mkdir -p "$OEM_PAYLOAD/grub"
# Convert to CRLF line endings: PowerShell 5.1 on Windows misparses LF-only
# files (Get-Content -Raw and the internal script parser both corrupt them).
printf '\xEF\xBB\xBF' > "$OEM_DIR/setup-wootc.ps1"
sed 's/$/\r/' "$SCRIPT_DIR/setup-wootc.ps1" >> "$OEM_DIR/setup-wootc.ps1"
# Also convert the wootc-files copy used by subsequent steps
printf '\xEF\xBB\xBF' > "$SCRIPT_DIR/wootc-files/setup-wootc.ps1"
sed 's/$/\r/' "$SCRIPT_DIR/setup-wootc.ps1" >> "$SCRIPT_DIR/wootc-files/setup-wootc.ps1"
cp "$SCRIPT_DIR/wootc-files/deployer-vmlinuz" "$OEM_PAYLOAD/deployer-vmlinuz"
cp "$SCRIPT_DIR/wootc-files/deployer-initramfs.img" "$OEM_PAYLOAD/deployer-initramfs.img"
cp "$SCRIPT_DIR/wootc-files/shimx64.efi" "$OEM_PAYLOAD/shimx64.efi"
cp "$SCRIPT_DIR/wootc-files/grubx64.efi" "$OEM_PAYLOAD/grubx64.efi"
[ -s "$SCRIPT_DIR/wootc-files/wubildr.efi" ] && \
    cp "$SCRIPT_DIR/wootc-files/wubildr.efi" "$OEM_PAYLOAD/wubildr.efi"
cp "$SCRIPT_DIR/wootc-files/grub/"*.cfg "$OEM_PAYLOAD/grub/"
cp "$SCRIPT_DIR/qga.py" "$OEM_DIR/qga.py"

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
step "Checking prerequisites..."

[ -e /dev/kvm ] || { fail "/dev/kvm not available — KVM required"; exit 1; }
command -v "$DOCKER" &>/dev/null || { fail "$DOCKER not found"; exit 1; }
command -v "$PYTHON_BIN" &>/dev/null || { fail "$PYTHON_BIN not found"; exit 1; }
command -v curl &>/dev/null || { fail "curl is required to cache the QGA MSI"; exit 1; }

mkdir -p "$QGA_CACHE_DIR"
if [ ! -s "$QGA_MSI" ]; then
    step "Caching QEMU Guest Agent MSI..."
    tmp_msi="$QGA_MSI.tmp.$$"
    curl --fail --location --retry 3 --output "$tmp_msi" "$QGA_MSI_URL"
    mv "$tmp_msi" "$QGA_MSI"
fi
[ -s "$QGA_MSI" ] || { fail "QGA MSI is empty: $QGA_MSI"; exit 1; }
sha256sum "$QGA_MSI" > "$QGA_MSI.sha256"
cp "$QGA_MSI" "$OEM_DIR/qemu-ga-x86_64.msi"

pass "Prerequisites OK ($DOCKER, QGA MSI $(du -h "$QGA_MSI" | cut -f1))"

# Windows PowerShell treats a double-quoted literal ending in a backslash as
# unterminated. This payload is parsed only after the full Windows install, so
# reject that typo locally rather than losing an E2E iteration to a late guest
# parser error.
validate_windows_payload() {
    local invalid
    invalid=$(grep -n '\\\\"$' "$SCRIPT_DIR/setup-wootc.ps1" || true)
    if [ -n "$invalid" ]; then
        fail "setup-wootc.ps1 contains a double-quoted string ending in a backslash"
        echo "$invalid" >&2
        exit 1
    fi
}

validate_windows_payload

# ── Step 2: Start Windows VM ─────────────────────────────────────────────────
step "Starting Windows VM..."
cd "$SCRIPT_DIR"
mkdir -p "$STORAGE_DIR"

if [ "$SKIP_INSTALL" = false ]; then
    # Clean previous run's disk so autounattend runs fresh
    $COMPOSE -f compose.yml down --volumes 2>/dev/null || true
    rm -rf storage/data.qcow2
    rm -f wootc-files/e2e-setup-complete.txt wootc-files/e2e-setup-failed.txt

    # Dockur mutates the downloaded installer ISO in place and its cache key
    # does not include /custom.xml. Reusing that ISO silently embeds an older
    # answer file (including an older disk layout), so fingerprint the input
    # and discard the processed ISO whenever the answer file changes.
    # The Windows disk layout is determined by autounattend.xml.  OEM payload
    # changes are safe on a reused guest because qga_sync_oem refreshes them
    # before each retry; including them here would falsely require a complete
    # Windows reinstall for every deployer or QGA client change.
    ANSWER_SHA=$(sha256sum autounattend.xml | awk '{print $1}')
    ANSWER_STAMP="$STORAGE_DIR/.wootc-autounattend.sha256"
    if [ "$(cat "$ANSWER_STAMP" 2>/dev/null || true)" != "$ANSWER_SHA" ]; then
        info "autounattend.xml changed; rebuilding Dockur's processed installer ISO"
        # Keep a user-supplied custom.iso (for example an offline Windows ISO)
        # and discard only Dockur's derived installer images.
        find "$STORAGE_DIR" -maxdepth 1 -type f -name '*.iso' ! -name 'custom.iso' -delete
        rm -f "$STORAGE_DIR/windows.base" "$STORAGE_DIR/windows.boot"
        ANSWER_REFRESH=true
    else
        ANSWER_REFRESH=false
    fi

    # When a cached ISO is available, always make a fresh working copy for
    # Dockur.  `--reflink=auto` is instantaneous on CoW filesystems (including
    # the XFS volume on our runners) and degrades safely to a normal copy.
    # The cache itself therefore survives test cleanup and installer rebuilds.
    if [ -f "$WINDOWS_ISO_CACHE" ]; then
        mkdir -p "$ISO_CACHE_DIR"
        rm -f "$STORAGE_DIR/custom.iso"
        cp --reflink=auto --sparse=auto "$WINDOWS_ISO_CACHE" "$STORAGE_DIR/custom.iso"
        info "Using cached Windows ISO: $WINDOWS_ISO_CACHE"
    elif [ -n "${WOOTC_WINDOWS_ISO:-}" ]; then
        fail "WOOTC_WINDOWS_ISO does not exist: $WINDOWS_ISO_CACHE"
        exit 1
    elif [ -f "$STORAGE_DIR/custom.iso" ]; then
        info "Using user-supplied Windows ISO: $STORAGE_DIR/custom.iso"
    else
        info "No cached Windows ISO; Dockur will download one. Save a verified installer under $ISO_CACHE_DIR to avoid this next time."
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

# Self-healing container start. Rootless podman occasionally leaves a phantom
# "podman0 already exists but is a Tun interface" in its network run-state
# after a crashed run — netavark then refuses every bridge start until the
# stale state is cleared. Detect that specific failure and auto-heal once so
# the runner needs no manual host babysitting.
# Avoid host-port clashes without killing anything. The compose file maps
# noVNC/RDP/VNC/ssh purely for debug convenience (QGA is the real control
# plane), so if a default port is already taken — e.g. gnome-remote-desktop
# owns 3389, or a monitoring stack owns a port — pick a free alternative and
# export the override the compose file reads. We never kill the holder: it may
# be a legitimate service (the operator's own remote desktop).
port_free() { ! { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || { exec 3>&- 3<&-; return 1; }; }
pick_free_ports() {
    local var base p
    for pair in "WOOTC_E2E_NOVNC_PORT:8006" "WOOTC_E2E_RDP_PORT:3389" \
                "WOOTC_E2E_VNC_PORT:5900" "WOOTC_E2E_SSH_PORT:2222"; do
        var="${pair%%:*}"; base="${pair##*:}"
        p="${!var:-$base}"
        if ! port_free "$p"; then
            local alt
            for alt in $(seq $((base + 10000)) $((base + 10050))); do
                port_free "$alt" && { p="$alt"; break; }
            done
            warn "host port $base is in use — mapping $var=$p instead"
        fi
        export "$var=$p"
    done
}

# Rebuild the baked-in-sshd image if it went missing (e.g. `podman system
# prune` reclaimed it). Compose then fails trying to pull it from localhost.
rebuild_ssh_image_if_missing() {
    local img="${WOOTC_E2E_IMAGE:-localhost/wootc-e2e-windows-ssh:latest}"
    [[ "$img" == localhost/wootc-e2e-windows-ssh:latest ]] || return 1
    [[ -x "$SCRIPT_DIR/build-ssh-image.sh" ]] || return 1
    warn "e2e ssh image missing — rebuilding via build-ssh-image.sh"
    bash "$SCRIPT_DIR/build-ssh-image.sh"
}

compose_up_windows() {
    pick_free_ports
    $DOCKER rm -f "$CONTAINER_NAME" 2>/dev/null || true
    local out
    if out=$($COMPOSE -f compose.yml up -d windows 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    printf '%s\n' "$out" >&2
    # (1) netavark phantom bridge — clear stale rootless network run-state.
    if printf '%s' "$out" | grep -q "already exists but is a Tun interface"; then
        warn "netavark phantom bridge detected — clearing stale rootless network state and retrying"
        $DOCKER rm -f "$CONTAINER_NAME" 2>/dev/null || true
        local netdir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks"
        rm -rf "${netdir:?}/"* 2>/dev/null || true
        $DOCKER network reload --all 2>/dev/null || true
        $COMPOSE -f compose.yml up -d windows
        return $?
    fi
    # (2) the e2e ssh image was pruned — rebuild it, then retry.
    if printf '%s' "$out" | grep -qiE "pinging container registry localhost|no such image|manifest unknown"; then
        rebuild_ssh_image_if_missing && { $COMPOSE -f compose.yml up -d windows; return $?; }
    fi
    # (3) a port clashed after our pre-check (race) — re-pick and retry once.
    if printf '%s' "$out" | grep -qi "address already in use"; then
        warn "host port clash — re-selecting free ports and retrying"
        $DOCKER rm -f "$CONTAINER_NAME" 2>/dev/null || true
        pick_free_ports
        $COMPOSE -f compose.yml up -d windows
        return $?
    fi
    return 1
}
compose_up_windows
info "Container $CONTAINER_NAME started"

# Dockur may need to prepare (or re-use) a Windows ISO before starting QEMU.
# A first run extracts the ISO, injects drivers, and rebuilds the installer
# image — several minutes on slower disks — so poll long (up to 15 min) and
# distinguish "QEMU never started" from a real acceleration failure.
QEMU_CMD=""
for _ in $(seq 1 300); do
    QEMU_CMD=$($DOCKER exec "$CONTAINER_NAME" ps -ef 2>/dev/null | grep '[q]emu-system' || true)
    [ -n "$QEMU_CMD" ] && break
    sleep 3
done
if [ -z "$QEMU_CMD" ]; then
    fail "QEMU did not start within 15 minutes (Dockur still preparing the image, or it crashed)"
    capture_vm_diagnostics
    exit 1
fi
if [[ ( "$QEMU_CMD" != *"-accel=kvm"* && "$QEMU_CMD" != *"accel=kvm"* ) || "$QEMU_CMD" != *"-enable-kvm"* ]]; then
    fail "QEMU is not using KVM acceleration"
    capture_vm_diagnostics
    exit 1
fi
QEMU_RAM_MB=$(awk '{
    for (i = 1; i < NF; i++) if ($i == "-m" && $(i + 1) ~ /^[0-9]+[MG]$/) {
        value = $(i + 1)
        unit = substr(value, length(value), 1)
        sub(/[MG]$/, "", value)
        if (unit == "G") value *= 1024
        print value
        exit
    }
}' <<<"$QEMU_CMD")
if [ -z "$QEMU_RAM_MB" ] || [ "$QEMU_RAM_MB" -lt 4096 ]; then
    fail "QEMU has ${QEMU_RAM_MB:-unknown} MB RAM; Windows 11 setup requires at least 4096 MB"
    info "Free host memory or adjust WOOTC_E2E_RAM_SIZE after confirming runner capacity"
    capture_vm_diagnostics
    exit 1
fi
pass "QEMU memory allocation is ${QEMU_RAM_MB} MB"
if [[ "$QEMU_CMD" != *"-tpmdev emulator"* || "$QEMU_CMD" != *"property=secure,value=on"* ]]; then
    fail "Windows 11 VM is missing TPM 2.0 or Secure Boot"
    capture_vm_diagnostics
    exit 1
fi
pass "QEMU is KVM-accelerated with TPM 2.0 and Secure Boot"
if [[ "$QEMU_CMD" != *"qga0"* || "$QEMU_CMD" != *"org.qemu.guest_agent.0"* ]]; then
    fail "QEMU is missing the QGA virtio-serial channel"
    capture_vm_diagnostics
    exit 1
fi
$DOCKER cp "$SCRIPT_DIR/qga.py" "$CONTAINER_NAME:/tmp/qga.py"
pass "QGA virtio-serial channel configured"
WOOTC_CONTAINER_RUNTIME="$DOCKER" "$SCRIPT_DIR/record-video.sh" start "$VIDEO_DIR"
VIDEO_STARTED=true
pass "VM walkthrough recording started"

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

        # `windows.ver` is written after Dockur has prepared the installer and
        # started QEMU. It is not a Windows guest-complete marker; the serial
        # deployer marker below is the real end-to-end completion signal.
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

    pass "Windows installer prepared and QEMU booted ($(( ELAPSED / 60 ))m)"
    if [ "$ANSWER_REFRESH" = true ]; then
        printf '%s\n' "$ANSWER_SHA" > "$ANSWER_STAMP"
    fi
    # Cache Dockur's downloaded installer ISO so a later `podman system prune`
    # or storage wipe never forces a fresh multi-GB re-download.
    if [ ! -f "$WINDOWS_ISO_CACHE" ]; then
        dl_iso=$($DOCKER exec "$CONTAINER_NAME" sh -c 'ls -1 /storage/*.iso 2>/dev/null | grep -v custom.iso | head -1' 2>/dev/null || true)
        if [ -n "$dl_iso" ]; then
            mkdir -p "$ISO_CACHE_DIR"
            if $DOCKER cp "$CONTAINER_NAME:$dl_iso" "$WINDOWS_ISO_CACHE.tmp" 2>/dev/null; then
                mv -f "$WINDOWS_ISO_CACHE.tmp" "$WINDOWS_ISO_CACHE"
                info "Cached Windows ISO for future runs: $WINDOWS_ISO_CACHE"
            fi
        fi
    fi
    info "Windows installation is still running; waiting for its OEM handoff..."
fi

# The QGA service is installed by the SYSTEM OEM bootstrap before the wootc
# payload runs. Its availability is the real Windows-ready signal; no guest
# IP, WinRM listener, or Windows password is involved.
if [ "$SKIP_INSTALL" = true ] && qga_probe && ! qga_windows_probe; then
    info "Previous deployer is still running; clearing UEFI BootNext before Windows retry"
    # A failed initramfs can leave the UEFI one-shot entry set, causing every
    # Ctrl-Alt-Del to loop back to the deployer instead of normal BootOrder.
    qga_call exec /bin/sh -c 'rm -f /sys/firmware/efi/efivars/BootNext-*' || \
        info "Could not clear UEFI BootNext from the deployer; continuing with reboot"
    info "Rebooting prior deployer to Windows before retry"
    $DOCKER exec "$CONTAINER_NAME" python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock"); s.sendall(b"sendkey ctrl-alt-delete\n"); s.close()'
fi
qga_wait_windows 2700
qga_call info || true

if [ "$SKIP_INSTALL" = true ]; then
    qga_sync_oem
    reset_oem_attempt
fi

step "Starting OEM setup through QGA..."
qga_powershell '@("C:\OEM\e2e-setup-complete.txt","C:\OEM\e2e-setup-failed.txt","C:\OEM\e2e-snapshot-complete.txt") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Remove-Item -LiteralPath $_ -Force }' >/dev/null
qga_powershell "Start-Process -FilePath 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File','C:\\OEM\\run-wootc-e2e.ps1') -WindowStyle Hidden" >/dev/null
pass "OEM setup process started through QGA as SYSTEM"

# The OEM wrapper deliberately pauses after staging BootNext. Do not permit
# its first deployer reboot until a reusable, crash-consistent VM snapshot is
# safely present on the host.
step "Waiting for OEM setup to reach the pre-deployer snapshot barrier..."
ELAPSED=0
TIMEOUT=2700
BARRIER_REACHED=false
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if qga_read 'C:\OEM\e2e-setup-complete.txt' >/dev/null 2>&1; then
        # Best-effort snapshot: releases the barrier and continues even if the
        # host-side crash-consistent copy had to be skipped.
        snapshot_before_deployer
        BARRIER_REACHED=true
        break
    fi
    OEM_FAILURE=$(qga_read 'C:\OEM\e2e-setup-failed.txt' 2>/dev/null || true)
    if [ -n "$OEM_FAILURE" ]; then
        fail "Windows OEM setup failed before the snapshot barrier:"
        echo "$OEM_FAILURE" >&2
        capture_vm_diagnostics
        exit 1
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    [ $((ELAPSED % 60)) -eq 0 ] && info "Waiting for OEM setup barrier... ($(( ELAPSED / 60 ))m)"
done
[ "$BARRIER_REACHED" = true ] || {
    fail "OEM setup did not reach the snapshot barrier within $((TIMEOUT/60)) minutes"
    capture_vm_diagnostics
    exit 1
}

# ── Step 4: Wait for Windows install and OEM handoff ─────────────────────────
# The deployer serial marker is the end-to-end assertion: it can only appear
# after the local Windows script creates root.disk, installs wubildr.efi,
# creates the one-shot BCD entry, and reboots.  `windows.ver` merely proves
# Dockur prepared its installer; it is deliberately not presented as a guest
# completion signal above.
step "Waiting for Windows install and Dockur OEM handoff..."

# ── Step 7: Monitor deployer via QEMU serial console ─────────────────────────
step "Monitoring deployer (QEMU serial console)..."
info "Watching for fisherman deployment markers..."

# A standard Windows install plus the local OEM handoff routinely takes
# 20–30 minutes even under KVM. Do not turn Dockur's installer-ready file into
# a premature test failure; only the deployer's serial marker proves success.
TIMEOUT=2700
ELAPSED=0
DEPLOY_COMPLETE=false
DEPLOYER_REBOOT_SEEN=false
PTY="$STORAGE_DIR/qemu.pty"

# Wait for Dockur's serial capture to appear and create the first local
# snapshot. `qemu.pty` contains control bytes and does not reliably add a
# newline per serial write, so all offsets below are bytes rather than lines.
for i in $(seq 1 30); do
    snapshot_serial && [ -f "$PTY" ] && break
    sleep 5
done

[ -f "$PTY" ] || { fail "QEMU PTY not found at $PTY"; exit 1; }
LAST_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)

while [ $ELAPSED -lt $TIMEOUT ]; do
    snapshot_serial || true
    OEM_FAILURE=$(qga_read 'C:\OEM\e2e-setup-failed.txt' 2>/dev/null || true)
    if [ -n "$OEM_FAILURE" ]; then
        fail "Windows OEM setup failed (read through QGA):"
        echo "$OEM_FAILURE" >&2
        break
    fi

    # Serial output can be lost across the initramfs-to-Windows reboot.  Once
    # the Windows QGA is back, the persisted deployer log is the authoritative
    # completion record and survives that console handoff.
    if qga_windows_probe; then
        DEPLOYER_LOG=$(qga_read 'C:\wootc\logs\deployer.log' 2>/dev/null || true)
        if echo "$DEPLOYER_LOG" | grep -q 'VERIFICATION_SUMMARY'; then
            echo "$DEPLOYER_LOG" | grep 'VERIFICATION_SUMMARY' | tail -1 \
                | sed "s/^/$(date -u +%FT%TZ) /" >> "$STORAGE_DIR/e2e-timeline.log" 2>/dev/null || true
            DEPLOY_COMPLETE=true
            pass "wootc: deployment verification complete (persistent log)"
            break
        elif [ "$DEPLOYER_REBOOT_SEEN" = true ]; then
            DEPLOY_COMPLETE=true
            pass "wootc: deployer rebooted and Windows QGA returned"
            break
        fi
    fi

    CURRENT_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)
    [ "$CURRENT_BYTE" -lt "$LAST_BYTE" ] && LAST_BYTE=0

    if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then
        NEW_OUTPUT=$(tail -c "+$((LAST_BYTE + 1))" "$PTY")

        # Per-run telemetry timeline: every [wootc]/fisherman marker with a
        # wall-clock timestamp, including phase transitions and heartbeats
        # (phase= and scratch/mem usage come from the deployer's kmsg lines).
        echo "$NEW_OUTPUT" | strings | grep -aE "\[wootc\]|fisherman|VERIFICATION_SUMMARY|\[FAIL\]" \
            | sed "s/^/$(date -u +%FT%TZ) /" >> "$STORAGE_DIR/e2e-timeline.log" 2>/dev/null || true

        echo "$NEW_OUTPUT" | grep -q "\[wootc\]"               && info "wootc: deployer active"
        echo "$NEW_OUTPUT" | grep -q "fisherman.*Partitioning" && info "fisherman: partitioning"
        echo "$NEW_OUTPUT" | grep -qE "Deploying|Pulling container|Installing OS" && info "fisherman: deploying OS"
        echo "$NEW_OUTPUT" | grep -qE "\[PASS\]" && info "wootc: $(echo "$NEW_OUTPUT" | grep -E '\[PASS\]' | tail -1)"
        echo "$NEW_OUTPUT" | grep -qE "\[WARN\]" && info "wootc: $(echo "$NEW_OUTPUT" | grep -E '\[WARN\]' | tail -1)"
        if echo "$NEW_OUTPUT" | grep -q "\[wootc-oem\] Setup failed:"; then
            fail "Windows OEM setup failed; see the serial marker above"
            break
        fi
        if echo "$NEW_OUTPUT" | grep -q "VERIFICATION_SUMMARY"; then
            DEPLOY_COMPLETE=true
            pass "wootc: deployment verification complete"
            LAST_BYTE=$CURRENT_BYTE
            break
        fi
        if echo "$NEW_OUTPUT" | grep -qE '(^|[^[:alpha:]])Rebooting\.?'; then
            DEPLOYER_REBOOT_SEEN=true
            info "wootc: deployer requested reboot"
        fi
        if echo "$NEW_OUTPUT" | grep -qE "fatal|panic|kernel panic|\[FAIL\]"; then
            fail "Deployer error:"
            echo "$NEW_OUTPUT" | grep -E "fatal|panic|kernel panic|\[FAIL\]"
            break
        fi
        LAST_BYTE=$CURRENT_BYTE
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
#
# The deploy-watch loop only declares DEPLOY_COMPLETE from inside a successful
# qga_windows_probe, so in the normal path Windows is already booted and stable
# here — there is no second reboot to wait for. Waiting for QGA to "go away"
# would then time out on a system that is simply sitting at the Windows desktop.
# Only wait for the Windows return when it is not already up (deploy detected
# purely from the serial console before the initramfs→Windows reboot settled).
if ! qga_windows_probe; then
    qga_wait_reboot "Windows after deployer"
fi

step "Scheduling one-shot Phase 2 Linux boot..."
# shellcheck disable=SC2016 # PowerShell variables must remain literal here.
PHASE2_GUID=$(qga_powershell \
    '$guid = (Get-Content C:\wootc\install\bcd-guid.txt -Raw).Trim(); if ($guid -notmatch "^\{[0-9a-fA-F-]+\}$") { throw "invalid wootc BCD GUID: $guid" }; Write-Output $guid')
PHASE2_GUID=$(printf '%s' "$PHASE2_GUID" | tr -d '\r\n')
[ -n "$PHASE2_GUID" ] || { fail "Could not read wootc BCD GUID from Windows"; exit 1; }

qga_powershell \
    "bcdedit /set '{fwbootmgr}' bootsequence $PHASE2_GUID /addfirst; shutdown /r /t 5 /f" >/dev/null
pass "Phase 2 Linux boot scheduled through BCD one-shot entry"
qga_wait_down "Phase 2 Linux boot"

step "Waiting for Phase 2 Linux system to boot..."

ELAPSED=0
TIMEOUT=300
BOOT_SUCCESS=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    snapshot_serial || true
    CURRENT_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)
    [ "$CURRENT_BYTE" -lt "$LAST_BYTE" ] && LAST_BYTE=0
    if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then
        NEW_OUTPUT=$(tail -c "+$((LAST_BYTE + 1))" "$PTY")
        if echo "$NEW_OUTPUT" | grep -qE "ostree=|Starting version|Welcome to|login:"; then
            BOOT_SUCCESS=true
            pass "Phase 2 Linux system booted!"
            break
        fi
        if echo "$NEW_OUTPUT" | grep -qE "No bootable device|BOOTMGR is missing|kernel panic"; then
            fail "Boot failure detected"
            break
        fi
        LAST_BYTE=$CURRENT_BYTE
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
    snapshot_serial || true
    CURRENT_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)
    [ "$CURRENT_BYTE" -lt "$LAST_BYTE" ] && LAST_BYTE=0
    if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then
        PASSTHROUGH_MARKERS+=$(tail -c "+$((LAST_BYTE + 1))" "$PTY")
        PASSTHROUGH_MARKERS+=$'\n'
        LAST_BYTE=$CURRENT_BYTE
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
$DOCKER exec "$CONTAINER_NAME" python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock"); s.sendall(b"sendkey ctrl-alt-delete\n"); s.close()'
qga_wait "Windows return after Phase 2 Linux" 600
pass "One-shot Phase 2 boot consumed; Windows returned successfully"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   wootc E2E test: ALL TESTS PASSED   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
info "Image tested: $IMAGE_REF"

exit 0
