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
# IMAGE_REF is the first NON-FLAG positional (set in the parse loop below), not
# blindly $1 — otherwise `run-e2e.sh --skip-install <image>` treats the flag as
# the image (this silently produced wootc.image=--skip-install once the deployer
# config was actually wired to IMAGE_REF).
IMAGE_REF=""

# ── Windows test case (matrix knobs) ─────────────────────────────────────────
# WOOTC_E2E_WIN_VERSION is a Dockur version string that selects the ISO+edition:
#   11   Win 11 Pro     11e  Win 11 Enterprise Eval   11l  Win 11 LTSC (IoT Ent)
#   10   Win 10 Pro     10e  Win 10 Enterprise Eval   10l  Win 10 LTSC 2021
# WOOTC_E2E_WIN_KEY is the generic product key the answer file uses to pick the
# edition from a multi-edition ISO (leave the default for Pro/Enterprise ISOs;
# eval/LTSC ISOs are single-edition and ignore it). WOOTC_E2E_WIN_EDITION is
# passed to Dockur for ISO edition selection where applicable.
WIN_VERSION="${WOOTC_E2E_WIN_VERSION:-11}"
WIN_EDITION="${WOOTC_E2E_WIN_EDITION:-pro}"
WIN_KEY="${WOOTC_E2E_WIN_KEY:-NPPR9-FWDCX-D2C8J-H872K-2YT43}"
export WOOTC_E2E_WIN_VERSION="$WIN_VERSION" WOOTC_E2E_WIN_EDITION="$WIN_EDITION"

# Parse flags
SKIP_BUILD=false
KEEP_CONTAINER=false
SKIP_INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --skip-build)   SKIP_BUILD=true ;;
        --keep)         KEEP_CONTAINER=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --phase3)       RUN_PHASE3=true ;;   # rung-3: graduate to a native disk
        --*)            ;;  # ignore unknown flags
        *)              [ -z "$IMAGE_REF" ] && IMAGE_REF="$arg" ;;  # first positional = image
    esac
done
IMAGE_REF="${IMAGE_REF:-ghcr.io/tuna-os/yellowfin:gnome}"

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

# ── wall-clock deadlines ────────────────────────────────────────────────────
# Wait loops used to track time by incrementing a counter alongside `sleep 5`.
# That counter is NOT wall-clock: every blocking call in the loop body (QGA
# probes, qga_read, snapshotting) burns real time without advancing it. Measured
# on a stalled dilli run, the counter advanced at 0.68x wall — so a nominal
# 45-minute deploy timeout was really ~66 minutes, and the "Deploying... (Nm)"
# progress line under-reported by half an hour. A run that looked hung for 90
# minutes was in fact still inside its timeout.
#
# deadline_in returns an absolute epoch; past_deadline tests against it. Time
# spent in the loop body now counts, so timeouts mean what they say and the
# reported minutes match the wall clock the operator is watching.
deadline_in() { echo $(( $(date +%s) + $1 )); }
past_deadline() { [ "$(date +%s)" -ge "$1" ]; }
elapsed_min_since() { echo $(( ( $(date +%s) - $1 ) / 60 )); }

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

# ── artifact retention ──────────────────────────────────────────────────────
# Each run writes a full artifact set — container logs, screenshots, video, a
# serial capture — which reached 3.3 GiB for a single run. Nothing ever removed
# them, so runners silently filled up until a later run died at the preflight
# ("Only 57 GiB free ... need at least 65 GiB"). A test harness that breaks the
# next run by succeeding is not finished.
#
# Keep the N most recent run directories and delete the rest, but ALWAYS keep
# the small text evidence (serial, logs) from the ones being pruned: that is
# what failures are diagnosed from later, and it costs kilobytes. The bulk —
# video, disk images, container dumps — is what actually consumes the space.
# ── deploy budget ───────────────────────────────────────────────────────────
# 90 minutes, not 45. The old default was 2700s, but it was consumed by a loop
# that counted sleeps rather than wall-clock and advanced at ~0.68x real time —
# so "45 minutes" was really ~66 wall-minutes, and deploys completed inside it.
#
# Fixing the clock (bc504a1) made 45 mean 45 and cut the real budget by a third.
# Every deploy then timed out at exactly 45m on all three runners, while the
# guest sat at 130-166% CPU still doing real work: bootc install pulling and
# extracting layers is simply slower than 45 wall-minutes on this hardware.
#
# So the budget was never calibrated against real time. This sets it against
# measured behaviour instead, with headroom. Raising it does NOT mask a hang:
# the CPU check in the deploy wait distinguishes "working" from "wedged".
WOOTC_E2E_DEPLOY_TIMEOUT_DEFAULT=5400

# How long serial may be silent before we check whether the guest is alive.
# bootc install is legitimately quiet for 10+ minutes, so this must be generous.
WOOTC_E2E_SILENCE_WARN_S="${WOOTC_E2E_SILENCE_WARN_S:-600}"

WOOTC_E2E_KEEP_RUNS="${WOOTC_E2E_KEEP_RUNS:-3}"
prune_old_artifacts() {
    local base="$STORAGE_DIR/artifacts" keep="$WOOTC_E2E_KEEP_RUNS"
    [ -d "$base" ] || return 0
    local evidence="$base/.evidence"
    mkdir -p "$evidence"
    # Newest first; skip the ones we keep, prune the tail.
    ls -1dt "$base"/*/ 2>/dev/null | grep -v '/.evidence/$' | tail -n "+$((keep + 1))" | while read -r d; do
        local name; name=$(basename "$d")
        mkdir -p "$evidence/$name"
        # Text-sized evidence only: serial + logs under 50 MiB.
        find "$d" -maxdepth 1 -type f \( -name '*.log' -o -name 'qemu.pty' -o -name '*.txt' -o -name '*.json' \) \
            -size -50M -exec cp {} "$evidence/$name/" \; 2>/dev/null || true
        rm -rf "$d"
    done
    return 0
}
prune_old_artifacts
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
    # Recalibrated after the pre-deployer snapshot was disabled (1c6d713).
    #
    # 65 GiB was the bare minimum for ONE run, so a run could pass preflight and
    # die mid-deploy, leaving nothing for the next run — runners ratcheted
    # toward full. That was raised to 120, but 120 assumed the snapshot's FULL
    # byte copy of data.qcow2 (reflink is unavailable here, so it doubled an
    # 18-28 GiB file). With the snapshot off, a run's resident footprint is
    # ~45 GiB: data.qcow2 + windows.*.iso (7.4) + custom.iso (7.3) + artifacts.
    #
    # 90 GiB is still roughly two runs' worth on a persistent host, and it fits
    # a GitHub hosted runner, which offers ~114 GiB after its cleanup step and
    # was being rejected by the 120 figure. Override for unusual hosts.
    local mem_available_kib disk_available_kib
    local required_free_gib="${WOOTC_E2E_MIN_FREE_GIB:-90}"
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
        required_free_gib=75
    fi
    # A reuse run already has those and needs only its allocated-extent
    # safety snapshot plus diagnostics.
    [ "$SKIP_INSTALL" = false ] || required_free_gib=55
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
# Cache each Windows version/edition separately so a matrix run never clobbers
# another case's installer (windows-11.iso, windows-10.iso, windows-11e.iso, …).
WINDOWS_ISO_CACHE="${WOOTC_WINDOWS_ISO:-$ISO_CACHE_DIR/windows-${WIN_VERSION}.iso}"
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
# snapshot_serial — copy the guest serial log out of the container.
#
# This used to be a bare `cp ... 2>&1` whose failure every caller swallowed with
# `|| true`. When the in-container source disappeared, the copy failed silently
# and the harness went on reading the STALE host-side copy from a previous
# snapshot — forever. Observed on dilli: the host qemu.pty sat frozen at 7190
# bytes for two hours while the deploy loop polled it for markers that could
# never arrive, and the "PTY not found" guard passed because the stale file
# existed on disk.
#
# Staleness is indistinguishable from "the guest is quiet" if we only look at
# the file, so track copy failures explicitly and warn once the source has been
# unreadable for a sustained period. A dead serial feed must be loud: it means
# every subsequent observation in the run is meaningless.
SERIAL_FAIL_COUNT=0
SERIAL_WARNED=false
snapshot_serial() {
    if $DOCKER cp "$CONTAINER_NAME:$SERIAL_SOURCE" "$PTY" >/dev/null 2>&1; then
        SERIAL_FAIL_COUNT=0
        return 0
    fi
    SERIAL_FAIL_COUNT=$((SERIAL_FAIL_COUNT + 1))
    # ~12 consecutive failures ≈ 1 minute of polling at the 5s cadence.
    if [ "$SERIAL_FAIL_COUNT" -ge 12 ] && [ "$SERIAL_WARNED" = false ]; then
        SERIAL_WARNED=true
        warn "serial feed is DEAD: cannot read $SERIAL_SOURCE from $CONTAINER_NAME for $((SERIAL_FAIL_COUNT * 5))s."
        warn "  The host copy $PTY is now STALE (last change: $(stat -c%y "$PTY" 2>/dev/null || echo unknown))."
        warn "  Every serial-derived check from here on is reading frozen data and cannot be trusted."
    fi
    return 1
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
# Every QGA call is bounded. Without this, a hung `podman exec` (guest agent
# wedged, container unresponsive, socket never answering) blocks the calling
# wait loop FOREVER — and because the loop body never returns, its deadline is
# never evaluated. Observed: two runners sat "alive" for 20+ minutes with their
# progress line frozen at "Waiting for QGA (5m of 45m)" while pgrep showed the
# script running. A wall-clock deadline cannot help a loop that never iterates,
# so the bound has to be here, on the blocking call itself.
QGA_CALL_TIMEOUT="${WOOTC_QGA_CALL_TIMEOUT:-60}"
qga_call() {
    timeout "$QGA_CALL_TIMEOUT" $DOCKER exec "$CONTAINER_NAME" python3 /tmp/qga.py "$@"
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
    local deadline; deadline=$(deadline_in "$timeout")
    while ! past_deadline "$deadline"; do
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
    local deadline; deadline=$(deadline_in "$timeout")
    while ! past_deadline "$deadline"; do
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
    local deadline; deadline=$(deadline_in "$timeout")
    while ! past_deadline "$deadline"; do
        if qga_windows_probe; then
            pass "QGA available: Windows guest"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && info "Waiting for QGA (Windows guest)... ($(( elapsed / 60 ))m of $((timeout/60))m)"
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

# OFF by default. This snapshot is a fast-retry convenience that currently costs
# far more than it provides, and is a prime suspect for the Phase-2 failures.
#
# Why it is off:
#   1. NOTHING READS IT. `data.qcow2.snap` is written here and referenced
#      nowhere else in this script — there is no restore path at all. It is a
#      pure cost today.
#   2. The design assumed an instant CoW reflink. `cp --reflink=always` FAILS on
#      every runner we have (observed on kanpur, himachal and dilli), so it falls
#      back to a full byte copy of an 18-28 GiB qcow2 — 10-20+ minutes.
#   3. The guest stays fsfreeze-FROZEN for that whole copy. Windows VSS enforces
#      hard freeze limits (writers ~10s, overall ~60s), so the guest cannot
#      honour a 20-minute freeze: it auto-thaws mid-copy under heavy host I/O.
#      The resulting snapshot is therefore not crash-consistent anyway.
#   4. An NTFS volume frozen and then abruptly thawed can be left with the dirty
#      bit set — and a dirty NTFS cannot be mounted read-write by ntfs3. That is
#      exactly the observed Phase-2 failure ("root.disk never attached"), and
#      exactly what the attach hook's own warning describes.
#   5. It costs ~28 GiB, which is what kept exhausting the runners' disks.
#
# Re-enable with WOOTC_E2E_SNAPSHOT=1 once a restore path exists AND the copy is
# either a genuine reflink or taken without holding the guest frozen.
WOOTC_E2E_SNAPSHOT="${WOOTC_E2E_SNAPSHOT:-0}"

snapshot_before_deployer() {
    local disk="$STORAGE_DIR/data.qcow2"
    local snapshot="$STORAGE_DIR/data.qcow2.snap"
    local tmp="$snapshot.tmp.$RUN_ID"
    local frozen=false

    if [ "$WOOTC_E2E_SNAPSHOT" != "1" ]; then
        info "Pre-deployer snapshot disabled (WOOTC_E2E_SNAPSHOT=1 to enable)"
        # The OEM wrapper blocks on this marker, so the barrier MUST still be
        # released or the run wedges waiting for a snapshot that never happens.
        mark_snapshot_complete
        return 0
    fi

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

# Deployer axes: the bootloader AND composefs backend are properties of the
# IMAGE, so by default let the DEPLOYER detect both definitively from it (it
# keys off whether the image ships a signed grub in bootupd → traditional ostree
# + grub2, vs systemd-boot only → composefs-native). The old name-based heuristic
# here (yellowfin→grub2, else→systemd) was wrong: it sent traditional-ostree
# Fedora images like bluefin/bonito down the systemd-boot path. Force a specific
# axis with WOOTC_E2E_BOOTLOADER=grub2|systemd / WOOTC_E2E_COMPOSEFS=0|1.
E2E_BOOTLOADER="${WOOTC_E2E_BOOTLOADER:-auto}"
E2E_COMPOSEFS="${WOOTC_E2E_COMPOSEFS:-auto}"
{
    printf 'ImageRef=%s\n'   "$IMAGE_REF"
    printf 'Bootloader=%s\n' "$E2E_BOOTLOADER"
    printf 'ComposeFs=%s\n'  "$E2E_COMPOSEFS"
    # RunId lets the OEM barrier prove the completion marker came from THIS run.
    # Without it the barrier passes on a stale marker left by a previous run —
    # see the comment on the barrier loop below.
    printf 'RunId=%s\n'     "$RUN_ID"
} > "$OEM_DIR/wootc-config.txt"
printf '[INFO] Deployer config: image=%s bootloader=%s composefs=%s\n' \
    "$IMAGE_REF" "$E2E_BOOTLOADER" "$E2E_COMPOSEFS" >&2

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

# Render the answer file for this Windows case: the product key selects the
# edition from the ISO. Dockur mounts this at /custom.xml (see compose.yml).
# The default key reproduces the original 11-pro answer file byte-for-byte.
RENDERED_ANSWER="$STORAGE_DIR/autounattend.rendered.xml"
sed "s#<Key>[^<]*</Key>#<Key>${WIN_KEY}</Key>#" autounattend.xml > "$RENDERED_ANSWER"

# ── BitLocker axis (SPEC §3.5) ──────────────────────────────────────────────
# off (default): the answer file sets PreventDeviceEncryption=1, so C: stays
#   plaintext and root.disk lives on C: — the path every run has taken so far.
# on: drop that command so Windows 11 auto-enables device encryption during
#   OOBE. C: becomes FVE ciphertext the deployer's ntfs3 mount cannot read, so
#   wootc MUST place root.disk on a separate unencrypted volume instead of
#   forcing the user to decrypt. That is the case this axis exercises.
E2E_BITLOCKER="${WOOTC_E2E_BITLOCKER:-off}"
case "$E2E_BITLOCKER" in
    off) : ;;
    on)
        python3 - "$RENDERED_ANSWER" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8-sig").read()
# remove the whole RunSynchronousCommand block that disables device encryption
s = re.sub(r'\s*<RunSynchronousCommand wcm:action="add">(?:(?!</RunSynchronousCommand>).)*?'
           r'PreventDeviceEncryption.*?</RunSynchronousCommand>', '', s, flags=re.S)
open(p, "w", encoding="utf-8").write(s)
PYEOF
        grep -q PreventDeviceEncryption "$RENDERED_ANSWER" && \
            { fail "BitLocker axis: could not remove PreventDeviceEncryption"; exit 1; }
        ;;
    *) fail "WOOTC_E2E_BITLOCKER must be on|off (got: $E2E_BITLOCKER)"; exit 1 ;;
esac
export WOOTC_E2E_BITLOCKER="$E2E_BITLOCKER"
printf '[INFO] BitLocker axis: %s (C: %s)\n' "$E2E_BITLOCKER" \
    "$([ "$E2E_BITLOCKER" = on ] && echo 'auto-encrypted → root.disk needs an unencrypted volume' || echo 'plaintext')" >&2
info "Windows case: version=$WIN_VERSION edition=$WIN_EDITION"

# ── restore a pristine Windows base image from a GHCR/ORAS snapshot ──────────
# WOOTC_E2E_SNAPSHOT_IN points at a directory holding a previously-primed base
# image: a compressed, cleanly-shut-down data.qcow2 + dockur's install markers +
# a snapshot.key. The key is the answer-file SHA the image was built from; if it
# matches THIS run's answer file, we drop the image into storage/ and take the
# existing --skip-install reuse path (which cold-boots the guest and waits on
# qga_wait_windows). On any mismatch or absence we fall through to a full
# install — the snapshot is a pure speedup, never a correctness dependency, so a
# drifted answer file can only cost time, never validity.
#
# The image is image-AGNOSTIC and wootc-code-AGNOSTIC: the target bootc image
# and deployer come from the /shared and /oem volumes (refreshed every run), not
# from data.qcow2. So one base image per (win_version, bitlocker) axis — which
# is exactly what ANSWER_SHA folds in — serves every target-image test.
SNAPSHOT_IN="${WOOTC_E2E_SNAPSHOT_IN:-}"
if [ "$SKIP_INSTALL" = false ] && [ -n "$SNAPSHOT_IN" ]; then
    want_key=$( { sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}')
    have_key=$(cat "$SNAPSHOT_IN/snapshot.key" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -s "$SNAPSHOT_IN/data.qcow2" ] && [ "$have_key" = "$want_key" ]; then
        info "Restoring pristine Windows base image from $SNAPSHOT_IN (key $want_key)"
        $COMPOSE -f compose.yml down --volumes 2>/dev/null || true
        mkdir -p "$STORAGE_DIR"
        rm -f "$STORAGE_DIR/data.qcow2"
        cp --reflink=auto --sparse=auto "$SNAPSHOT_IN/data.qcow2" "$STORAGE_DIR/data.qcow2"
        # dockur's "already installed" markers + our answer-file stamp, so the
        # reuse path neither reinstalls nor rejects the disk as a case mismatch.
        for f in "$SNAPSHOT_IN"/windows.* "$SNAPSHOT_IN/.wootc-autounattend.sha256"; do
            [ -e "$f" ] && cp "$f" "$STORAGE_DIR/"
        done
        SKIP_INSTALL=true
        info "Base image restored; taking the --skip-install reuse path"
    else
        info "Snapshot at $SNAPSHOT_IN unusable (key have='${have_key:-none}' want='$want_key'); doing a full install"
    fi
fi

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
    ANSWER_SHA=$( { sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}')
    ANSWER_STAMP="$STORAGE_DIR/.wootc-autounattend.sha256"
    if [ "$(cat "$ANSWER_STAMP" 2>/dev/null || true)" != "$ANSWER_SHA" ]; then
        info "answer file / Windows version changed; rebuilding Dockur's processed installer ISO"
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
    ANSWER_SHA=$( { sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}')
    ANSWER_STAMP="$STORAGE_DIR/.wootc-autounattend.sha256"
    if [ "$(cat "$ANSWER_STAMP" 2>/dev/null || true)" != "$ANSWER_SHA" ]; then
        fail "Windows case (answer file / version) changed since this disk was prepared; rerun without --skip-install"
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

# Build the e2e ssh image BEFORE compose needs it.
#
# compose.yml references localhost/wootc-e2e-windows-ssh:latest, which only ever
# exists because build-ssh-image.sh made it locally. On any host that has never
# built it — a fresh GitHub hosted runner, or a laptop after `podman system
# prune -af` — compose interprets "localhost/..." as a REGISTRY and tries to
# pull over HTTPS from localhost:443. Recovering after that failure works, but
# recovering from a failure we can trivially prevent is the wrong order.
ensure_ssh_image() {
    local img="${WOOTC_E2E_IMAGE:-localhost/wootc-e2e-windows-ssh:latest}"
    [[ "$img" == localhost/wootc-e2e-windows-ssh:latest ]] || return 0
    $DOCKER image exists "$img" 2>/dev/null && return 0
    [[ -x "$SCRIPT_DIR/build-ssh-image.sh" ]] || {
        fail "e2e ssh image $img is missing and build-ssh-image.sh is not executable"
        return 1
    }
    step "Building the e2e ssh image (absent on this host)..."
    bash "$SCRIPT_DIR/build-ssh-image.sh" || { fail "build-ssh-image.sh failed"; return 1; }
    $DOCKER image exists "$img" 2>/dev/null || { fail "build completed but $img still absent"; return 1; }
    pass "e2e ssh image built"
}

compose_up_windows() {
    ensure_ssh_image || return 1
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
# Do NOT ignore the result, and do NOT trust it either.
#
# This call used to be bare, so when every recovery path failed the script still
# printed "Container started" and went on to poll 15 minutes for a QEMU that
# could never appear. That is exactly how the first hosted-runner E2E and a
# kanpur run both failed: the locally-built ssh image was missing, compose tried
# to PULL it from a registry literally named "localhost", and the real error —
#   initializing source docker://localhost/wootc-e2e-windows-ssh:latest
#   no container with name or ID "wootc-e2e-windows" found
# — was buried under a 15-minute wait and reported as "QEMU did not start".
#
# podman-compose can also exit 0 without creating the container, so the exit
# status alone is not evidence. Verify the container actually exists.
if ! compose_up_windows; then
    fail "Could not start the Windows container (all recovery paths exhausted)"
    fail "  Common cause: the locally-built $CONTAINER_NAME image is absent and"
    fail "  compose tried to pull 'localhost/...' from a registry. Rebuild with:"
    fail "    bash $SCRIPT_DIR/build-ssh-image.sh"
    exit 1
fi
if ! $DOCKER container exists "$CONTAINER_NAME" 2>/dev/null; then
    fail "compose reported success but $CONTAINER_NAME does not exist"
    fail "  Rebuild the e2e image: bash $SCRIPT_DIR/build-ssh-image.sh"
    exit 1
fi
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

    TIMEOUT="${WOOTC_E2E_DEPLOY_TIMEOUT:-$WOOTC_E2E_DEPLOY_TIMEOUT_DEFAULT}"  # 45 min default; raise on slow CI
    ELAPSED=0
    INSTALL_STARTED=$(date +%s)
    INSTALL_DEADLINE=$(deadline_in "$TIMEOUT")
    INSTALL_DONE=false

    while ! past_deadline "$INSTALL_DEADLINE"; do
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
            info "Still installing... ($(elapsed_min_since "$INSTALL_STARTED")m of $((TIMEOUT/60))m)"
        fi
    done

    if [ "$INSTALL_DONE" = false ]; then
        fail "Windows install did not complete within $((TIMEOUT/60)) minutes"
        capture_vm_diagnostics
        exit 1
    fi

    pass "Windows installer prepared and QEMU booted ($(elapsed_min_since "$INSTALL_STARTED")m)"
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

# ── prime a pristine Windows base image for GHCR/ORAS ────────────────────────
# WOOTC_E2E_SNAPSHOT_OUT captures Windows RIGHT HERE — freshly installed and
# QGA-ready (qemu-ga is installed by dockur's OEM install.bat during setup, so
# it is already up), but BEFORE run-wootc-e2e.ps1 runs any migration. That is
# the maximally-reusable "pre-migration" state.
#
# Two traps, both avoided by a clean shutdown rather than a live fsfreeze copy
# (see snapshot_before_deployer's post-mortem above):
#   1. QEMU must FULLY EXIT before qemu-img touches data.qcow2 — converting a
#      qcow2 QEMU still holds open yields a subtly corrupt image that only fails
#      on restore. We power the guest off and bring the container down first.
#   2. The image must be a CLEANLY shut-down Windows, not dirty NTFS: a frozen-
#      then-thawed volume keeps its dirty bit set, which is the exact enemy of
#      the Phase-2 loop attach ("cannot mount host NTFS rw … Dirty volume?").
# The oras push happens in CI (e2e-snapshot.yml); this only produces the bundle.
SNAPSHOT_OUT="${WOOTC_E2E_SNAPSHOT_OUT:-}"
if [ -n "$SNAPSHOT_OUT" ]; then
    [ "$SKIP_INSTALL" = false ] || { fail "WOOTC_E2E_SNAPSHOT_OUT needs a fresh install; do not combine with --skip-install"; exit 1; }
    command -v qemu-img >/dev/null 2>&1 || { fail "WOOTC_E2E_SNAPSHOT_OUT requires qemu-img (install qemu-utils)"; exit 1; }
    step "Priming Windows base image → $SNAPSHOT_OUT (clean shutdown, then compress)"
    mkdir -p "$SNAPSHOT_OUT"

    # Clean guest shutdown so C:/NTFS is left with its dirty bit CLEAR.
    qga_powershell 'Stop-Computer -Force' >/dev/null 2>&1 \
        || qga_call exec /bin/sh -c 'shutdown /s /t 0' >/dev/null 2>&1 || true
    info "Waiting for the guest to power off cleanly (QGA to go away)..."
    prime_deadline=$(deadline_in 300)
    while ! past_deadline "$prime_deadline"; do
        qga_windows_probe || break   # QGA unreachable == guest powered off
        sleep 5
    done

    # Drop the container so nothing holds data.qcow2 open, THEN convert.
    $COMPOSE -f compose.yml down 2>/dev/null || $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    [ -s "$STORAGE_DIR/data.qcow2" ] || { fail "prime: data.qcow2 missing/empty after install"; exit 1; }

    step "Compressing base image (qemu-img convert -c → standalone qcow2)..."
    qemu-img convert -c -O qcow2 "$STORAGE_DIR/data.qcow2" "$SNAPSHOT_OUT/data.qcow2" \
        || { fail "prime: qemu-img convert failed"; exit 1; }
    # dockur's installed-markers so a restore does not trigger a reinstall.
    for f in "$STORAGE_DIR"/windows.*; do [ -e "$f" ] && cp "$f" "$SNAPSHOT_OUT/"; done
    # The correctness key the restore side validates against (same formula as
    # ANSWER_SHA), doubling as the answer-file stamp the reuse guard checks.
    { sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}' \
        > "$SNAPSHOT_OUT/snapshot.key"
    cp "$SNAPSHOT_OUT/snapshot.key" "$SNAPSHOT_OUT/.wootc-autounattend.sha256"
    ls -lh "$SNAPSHOT_OUT" >&2 || true
    pass "Pristine Windows base image ready at $SNAPSHOT_OUT (key $(cat "$SNAPSHOT_OUT/snapshot.key"))"
    exit 0
fi

if [ "$SKIP_INSTALL" = true ]; then
    reset_oem_attempt
fi

step "Starting OEM setup through QGA..."

# Refresh C:\OEM from the host BEFORE launching setup, ALWAYS.
#
# C:\OEM is populated from the ISO at Windows install time, so a guest whose
# Windows was installed by an earlier run still carries that run's
# run-wootc-e2e.ps1 and wootc-config.txt. Those predate RunId, so the guest
# stamps a constant into e2e-setup-complete.txt, the host's barrier never
# matches, it never writes e2e-snapshot-complete.txt, and the guest dies on its
# own 10-minute deadline while the host waits on it. A mutual deadlock.
#
# qga_sync_oem is the existing, correct implementation (it uses /oem — the
# CONTAINER's view of the mount — because qga.py runs inside the container and
# cannot see host paths). It was only being called for --skip-install, but a
# stale C:\OEM is not exclusive to that flag.
qga_sync_oem

qga_powershell '@("C:\OEM\e2e-setup-complete.txt","C:\OEM\e2e-setup-failed.txt","C:\OEM\e2e-snapshot-complete.txt") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Remove-Item -LiteralPath $_ -Force }' >/dev/null
qga_powershell "Start-Process -FilePath 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File','C:\\OEM\\run-wootc-e2e.ps1') -WindowStyle Hidden" >/dev/null
pass "OEM setup process started through QGA as SYSTEM"

# The OEM wrapper deliberately pauses after staging BootNext. Do not permit
# its first deployer reboot until a reusable, crash-consistent VM snapshot is
# safely present on the host.
step "Waiting for OEM setup to reach the pre-deployer snapshot barrier..."
TIMEOUT="${WOOTC_E2E_DEPLOY_TIMEOUT:-$WOOTC_E2E_DEPLOY_TIMEOUT_DEFAULT}"
BARRIER_STARTED=$(date +%s)
BARRIER_DEADLINE=$(deadline_in "$TIMEOUT")
BARRIER_LAST_MIN=-1
BARRIER_REACHED=false
# The barrier must prove the marker came from THIS run.
#
# It used to accept any readable C:\OEM\e2e-setup-complete.txt. A marker left
# by a previous run satisfied that instantly, so the harness jumped straight to
# "monitoring the deployer" while Windows setup was still staging the payload
# and the BCD one-shot. The VM then rebooted into Windows — serial ending at
#   BdsDxe: starting Boot0003 "Windows Boot Manager" ... bootmgfw.efi
# with zero [wootc] phase: lines — and the harness burned its whole budget
# watching a VM that was never deploying.
#
# This went unnoticed because snapshot_before_deployer() used to spend 10-20
# minutes on the fsfreeze + 28 GiB copy right here, which incidentally gave OEM
# setup the time it needed. The snapshot was accidentally load-bearing as a
# sleep; disabling it exposed the race. The fix is a real check, not a delay.
while ! past_deadline "$BARRIER_DEADLINE"; do
    BARRIER_MARK=$(qga_read 'C:\OEM\e2e-setup-complete.txt' 2>/dev/null | tr -d '\r\n' || true)
    if [ -n "$BARRIER_MARK" ] && [ "$BARRIER_MARK" = "$RUN_ID" ]; then
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
    BARRIER_MIN=$(elapsed_min_since "$BARRIER_STARTED")
    if [ "$BARRIER_MIN" -gt "$BARRIER_LAST_MIN" ]; then
        BARRIER_LAST_MIN=$BARRIER_MIN
        info "Waiting for OEM setup barrier... (${BARRIER_MIN}m of $((TIMEOUT/60))m)"
    fi
done
[ "$BARRIER_REACHED" = true ] || {
    fail "OEM setup did not reach the snapshot barrier within $((TIMEOUT/60)) minutes"
    # Say WHY, so this is attributable in one read instead of a VM session.
    # The common causes are distinguishable from the marker's contents:
    #   empty/missing -> OEM setup never finished (look at wootc-e2e.log);
    #   a different id -> a stale marker from an earlier run, i.e. C:\OEM was
    #     not refreshed — expected on a --skip-install reuse whose guest still
    #     carries an older run-wootc-e2e.ps1 that writes a constant.
    BARRIER_MARK=$(qga_read 'C:\OEM\e2e-setup-complete.txt' 2>/dev/null | tr -d '\r\n' || true)
    if [ -z "$BARRIER_MARK" ]; then
        info "  marker absent: OEM setup never completed. See C:\\OEM\\wootc-e2e.log below."
    elif [ "$BARRIER_MARK" != "$RUN_ID" ]; then
        info "  marker says '$BARRIER_MARK' but this run is '$RUN_ID' — STALE marker."
        info "  The guest's C:\\OEM is from an earlier run; reinstall or refresh it."
    fi
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
TIMEOUT="${WOOTC_E2E_DEPLOY_TIMEOUT:-$WOOTC_E2E_DEPLOY_TIMEOUT_DEFAULT}"
DEPLOY_STARTED=$(date +%s)
DEPLOY_DEADLINE=$(deadline_in "$TIMEOUT")
LAST_PROGRESS_MIN=-1
DEPLOY_COMPLETE=false
DEPLOYER_REBOOT_SEEN=false
KERNEL_REBOOT_SEEN=false
WINDOWS_BACK_STREAK=0
PTY="$STORAGE_DIR/qemu.pty"

# Wait for Dockur's serial capture to appear and create the first local
# snapshot. `qemu.pty` contains control bytes and does not reliably add a
# newline per serial write, so all offsets below are bytes rather than lines.
#
# Delete any prior copy FIRST. The `-f "$PTY"` guard below only proves a file
# exists, not that it came from this run — a leftover from a previous run
# satisfies it just as well, and the harness then spends the whole run reading
# another run's serial output. reset_oem_attempt() removes it, but that only
# runs on --skip-install, so the common path was unprotected.
rm -f "$PTY"

for i in $(seq 1 30); do
    snapshot_serial && [ -f "$PTY" ] && break
    sleep 5
done

[ -f "$PTY" ] || { fail "QEMU PTY not found at $PTY (no serial feed from $CONTAINER_NAME:$SERIAL_SOURCE)"; exit 1; }
LAST_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)

while ! past_deadline "$DEPLOY_DEADLINE"; do
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
    #
    # Windows answering QGA also means the DEPLOYER IS NO LONGER RUNNING. If it
    # neither completed nor is recorded as having rebooted deliberately, the
    # deploy is over and failed — waiting longer cannot change that. Observed:
    # a deployer hung after "ostree deployment:", the box rebooted into Windows,
    # and the harness spent another 76 minutes "Deploying..." before timing out.
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
        elif [ "$KERNEL_REBOOT_SEEN" = true ]; then
            # The box rebooted but the deployer never said it meant to, and the
            # persisted log carries no VERIFICATION_SUMMARY. That is the
            # watchdog signature: deploy died, machine reset, nothing staged.
            fail "Deployer did NOT complete: kernel reboot with no verification summary"
            info "  This is the watchdog signature — the deploy died and the box reset."
            info "  Phase-2 setup (BLS entry, 99wootc-boot module, initramfs regen)"
            info "  will NOT have run, so Phase 2 cannot boot. Deployer log:"
            printf '%s\n' "$DEPLOYER_LOG" | tail -15 >&2
            break
        else
            WINDOWS_BACK_STREAK=$((WINDOWS_BACK_STREAK + 1))
            # ~1 minute of Windows answering with no completion record. Give a
            # little grace for the reboot handoff, then stop: the deployer is
            # gone and the persisted log is the whole story.
            if [ "$WINDOWS_BACK_STREAK" -ge 12 ]; then
                fail "Deployer is gone: Windows QGA is answering but the deploy never completed"
                info "  No VERIFICATION_SUMMARY in C:\\wootc\\logs\\deployer.log, and no"
                info "  deliberate reboot was seen on serial — the deployer died mid-run."
                info "  Last lines of the deployer's own log:"
                printf '%s\n' "$DEPLOYER_LOG" | tail -12 >&2
                break
            fi
        fi
    else
        WINDOWS_BACK_STREAK=0
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

        # Surface the Phase-2-initramfs guard verdict to THIS (persistent) job
        # log. It is the single discriminator between "the wootc-attach service
        # is absent/unwired in the built initramfs" and "it is present+wired but
        # skipped at Phase-2 boot" — and it is otherwise LOST: the deployer
        # writes it to the serial during the Phase-1 boot, which the Phase-2 boot
        # then overwrites, and its persistent copy (C:\wootc\logs\deployer.log)
        # is unreachable once Phase 2 lands in a Linux emergency shell. Without
        # this echo, every Phase-2 attach failure costs a whole run just to learn
        # whether the module even made it into the initramfs.
        # NOTE: `|| true` is load-bearing. This whole script runs under
        # `set -euo pipefail`; a bare `grep | while` that finds NO match (the
        # common case — almost every serial chunk lacks a guard line) exits 1,
        # pipefail propagates it, and set -e then ABORTS the deploy-monitoring
        # loop on the very first chunk — i.e. "Deploying (0m)" then failure.
        # Capture with `|| true`, then feed the loop, so no-match is a no-op.
        GUARD_HITS_OUT=$(echo "$NEW_OUTPUT" | grep -aoE "guard: lsinitrd .*matches=[0-9]+|guard: losetup .*=[0-9]+|dracut regen exit=[0-9]+|dracut regen (FAILED|TIMED OUT)[^[:cntrl:]]*|Phase-2 initramfs .*WIRED[^[:cntrl:]]*|no WIRED wootc-attach[^[:cntrl:]]*|was not wired into initrd-root-device[^[:cntrl:]]*|lsinitrd unavailable[^[:cntrl:]]*" || true)
        [ -n "$GUARD_HITS_OUT" ] && printf '%s\n' "$GUARD_HITS_OUT" \
            | while IFS= read -r gl; do info "PHASE-1 GUARD: $gl"; done

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
        # A DELIBERATE reboot by the deployer is evidence of success. A bare
        # kernel "reboot: Restarting system" is NOT — the watchdog reboots that
        # way too, and treating them alike turned a failed deploy into
        # "deployer rebooted and Windows QGA returned", after which Phase 2 was
        # scheduled against a system that had never been set up. Keep them
        # distinct: only the deployer's own message implies success.
        if echo "$NEW_OUTPUT" | grep -qE '(^|[^[:alpha:]])Rebooting\.?'; then
            DEPLOYER_REBOOT_SEEN=true
            info "wootc: deployer requested reboot"
        fi
        if echo "$NEW_OUTPUT" | grep -q 'reboot: Restarting system'; then
            KERNEL_REBOOT_SEEN=true
            info "wootc: kernel reboot observed (not proof of a successful deploy)"
        fi
        if echo "$NEW_OUTPUT" | grep -qE "fatal|panic|kernel panic|\[FAIL\]"; then
            fail "Deployer error:"
            echo "$NEW_OUTPUT" | grep -E "fatal|panic|kernel panic|\[FAIL\]"
            break
        fi
        LAST_BYTE=$CURRENT_BYTE
    fi

    sleep 5
    # Report real minutes against the real budget, so an operator watching the
    # log can tell "slow but inside its timeout" from "wedged".
    NOW_MIN=$(elapsed_min_since "$DEPLOY_STARTED")
    if [ "$NOW_MIN" -gt "$LAST_PROGRESS_MIN" ]; then
        LAST_PROGRESS_MIN=$NOW_MIN
        info "Deploying... (${NOW_MIN}m of $((TIMEOUT/60))m)"

        # Distinguish "working quietly" from "wedged".
        #
        # `bootc install` produces NO serial output for 10+ minutes while it
        # extracts layers, so silence alone is not a failure signal and warning
        # on it cries wolf every run. Guest CPU is the discriminator that has
        # never lied here:
        #     silence + high CPU  -> working (measured 130-170% mid-install)
        #     silence + idle CPU  -> genuinely wedged
        # A deploy once looked hung for 13 minutes and was fine; another looked
        # identical and was dead. Only CPU separated them.
        SERIAL_AGE=$(( $(date +%s) - $(stat -c %Y "$PTY" 2>/dev/null || echo 0) ))
        if [ "$SERIAL_AGE" -gt "$WOOTC_E2E_SILENCE_WARN_S" ]; then
            GUEST_CPU=$($DOCKER exec "$CONTAINER_NAME" sh -c \
                "ps -eo pcpu,args | grep '[q]emu-system' | head -1 | awk '{print \$1}'" 2>/dev/null | tr -d ' \r\n')
            if [ -z "$GUEST_CPU" ]; then
                warn "  serial silent ${SERIAL_AGE}s and NO QEMU process — the guest is gone"
            elif awk -v c="$GUEST_CPU" 'BEGIN{exit !(c < 15)}' 2>/dev/null; then
                warn "  serial silent ${SERIAL_AGE}s with guest CPU ${GUEST_CPU}% — likely WEDGED, not slow"
            else
                info "  (serial quiet ${SERIAL_AGE}s but guest CPU ${GUEST_CPU}% — working)"
            fi
        fi
    fi
done

[ "$DEPLOY_COMPLETE" = true ] || {
    fail "Deployment did not complete within $((TIMEOUT/60)) minutes"
    info "Last 30 lines of QEMU console:"
    tail -30 "$PTY"
    exit 1
}

# ── Assert the BitLocker axis actually took effect (SPEC §3.5) ──────────────
# setup-wootc.ps1 logs the observed C: state and where Linux was placed. On the
# FDE case C: must be encrypted AND root.disk must live on a different,
# unencrypted volume — proving we never forced the user to decrypt.
OEM_LOG=$(qga_read 'C:\OEM\wootc-e2e.log' 2>/dev/null | tr -d '\r' || true)
BL_SEEN=$(printf '%s' "$OEM_LOG" | grep -aoE 'C: BitLocker state: [a-z]+' | tail -1 | awk '{print $NF}')
BL_ROOT=$(printf '%s' "$OEM_LOG" | grep -aoE 'WOOTC_STORAGE_ROOT=[A-Za-z]:' | tail -1 | cut -d= -f2)
info "BitLocker axis=${WOOTC_E2E_BITLOCKER:-off} observed C: state=${BL_SEEN:-unknown} storage=${BL_ROOT:-unknown}"
if [ "${WOOTC_E2E_BITLOCKER:-off}" = "on" ]; then
    case "$BL_SEEN" in
        on|encrypting) pass "BitLocker FDE: C: is protected as intended" ;;
        *) fail "BitLocker FDE case: C: reported '${BL_SEEN:-unknown}', expected on/encrypting"; exit 1 ;;
    esac
    if [ -n "$BL_ROOT" ] && [ "$BL_ROOT" != "C:" ]; then
        pass "BitLocker FDE: Linux placed on unencrypted volume $BL_ROOT (C: never decrypted)"
    else
        fail "BitLocker FDE: root.disk should NOT be on C: (got '${BL_ROOT:-unknown}')"
        exit 1
    fi
else
    case "$BL_SEEN" in
        off|"") pass "No-BitLocker case: C: is plaintext as intended" ;;
        *) fail "No-BitLocker case: C: reported '$BL_SEEN', expected off"; exit 1 ;;
    esac
fi

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

# PowerShell parses a bare {GUID}/{fwbootmgr} as a script block, so bcdedit
# received garbage and silently failed (ParameterSpecifiedAlready) — the
# bootsequence was never set and the VM just rebooted back to Windows. The
# stop-parsing operator (--%) passes everything after it verbatim to bcdedit,
# so the braces reach it literally. It must be its own command (--% swallows
# the rest of the line), so issue the reboot separately and verify the
# bootsequence actually took before waiting for the reboot.
qga_powershell "bcdedit --% /set {fwbootmgr} bootsequence $PHASE2_GUID /addfirst" >/dev/null
if ! qga_powershell "bcdedit --% /enum {fwbootmgr}" 2>/dev/null | tr -d '\r' | grep -qiF "$PHASE2_GUID"; then
    fail "BCD bootsequence was not set to the wootc Phase-2 entry ($PHASE2_GUID)"
    exit 1
fi
pass "Phase 2 Linux boot scheduled through BCD one-shot entry (bootsequence verified)"
qga_powershell "shutdown /r /t 3 /f" >/dev/null
qga_wait_down "Phase 2 Linux boot"

step "Waiting for Phase 2 Linux system to boot..."

TIMEOUT=300
BOOT_STARTED=$(date +%s)
BOOT_DEADLINE=$(deadline_in "$TIMEOUT")
BOOT_SUCCESS=false

while ! past_deadline "$BOOT_DEADLINE"; do
    snapshot_serial || true
    CURRENT_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)
    [ "$CURRENT_BYTE" -lt "$LAST_BYTE" ] && LAST_BYTE=0
    if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then
        NEW_OUTPUT=$(tail -c "+$((LAST_BYTE + 1))" "$PTY")
        # A real Phase-2 boot means the system reached its ACTUAL root, not just
        # that the initramfs started. "ostree=" matches the kernel cmdline echo
        # inside the initramfs, so it fired even when the boot then dropped to an
        # emergency shell — reporting PASS for a system with no root at all.
        if echo "$NEW_OUTPUT" | grep -qE "Reached target (multi-user|graphical)|login:|Welcome to"; then
            BOOT_SUCCESS=true
            pass "Phase 2 Linux system booted (reached its real root)"
            break
        fi
        # Emergency mode = root never appeared. Fail fast and say why, instead of
        # waiting out the timeout or mislabelling it a success.
        if echo "$NEW_OUTPUT" | grep -qE "Entering emergency mode|emergency\.target|Dependency failed for sysroot"; then
            fail "Phase 2 dropped to an emergency shell — root.disk never attached"
            echo "$NEW_OUTPUT" | grep -aiE "wootc|sysroot|does not exist|mount" | tail -12
            break
        fi
        if echo "$NEW_OUTPUT" | grep -qE "No bootable device|BOOTMGR is missing|kernel panic"; then
            fail "Boot failure detected"
            break
        fi
        LAST_BYTE=$CURRENT_BYTE
    fi
    sleep 5
done

[ "$BOOT_SUCCESS" = true ] || {
    fail "Phase 2 Linux system did not boot within $(elapsed_min_since "$BOOT_STARTED")m (budget $((TIMEOUT/60))m)"
    tail -30 "$PTY"
    exit 1
}

# ── Step 8b (rung 3): graduate Phase 2 → a native disk ──────────────────────
# Only with --phase3. Phase-2 enables qemu-guest-agent (MGMT_KARG), so we can
# drive the graduate inside the running Linux over the same QGA channel. The
# target is a spare blank disk (WOOTC_E2E_DISK2_SIZE), so Windows + root.disk
# are untouched and the whole thing stays reversible.
if [ "${RUN_PHASE3:-false}" = true ]; then
    step "Phase 3: waiting for Linux guest agent in Phase 2..."
    P3_OK=false
    for _ in $(seq 1 60); do
        if qga_call exec /bin/sh -c 'uname -s' 2>/dev/null | grep -qi linux; then
            P3_OK=true; break
        fi
        sleep 5
    done
    if [ "$P3_OK" != true ]; then
        fail "Phase 3: no Linux QGA in Phase 2 (is qemu-guest-agent enabled?)"
        exit 1
    fi
    pass "Phase 3: Linux guest agent reachable inside Phase 2"

    info "Phase 3: go-native status"
    qga_call exec /bin/sh -c 'wootc-go-native status 2>&1 || true' 2>/dev/null | head -25

    # Pick the graduate target: a BLANK whole disk (no partitions, no
    # filesystem). Do NOT use "any disk that isn't root's" — in Phase 2 root
    # lives on a /dev/loopNpM partition (root.disk attached via losetup since the
    # raw switch), so that rule excludes the loop device and happily selects
    # /dev/sda, i.e. the WINDOWS disk. `bootc install --wipe` on that destroys
    # the user's Windows. Emptiness is what actually identifies the spare drive.
    # Selection logic lives in tests/e2e/pick-blank-disk.sh so it can be unit
    # tested — its output is handed to `bootc install --wipe`, so a wrong answer
    # destroys the user's Windows. Shipped as text over QGA and run in the guest.
    P3_TARGET=$(qga_call exec /bin/sh -c "$(cat "$SCRIPT_DIR/pick-blank-disk.sh")" \
        2>/dev/null | tr -d '\r\n ')
    if [ -z "$P3_TARGET" ]; then
        fail "Phase 3: no BLANK spare disk found (run with WOOTC_E2E_DISK2_SIZE=40G)"
        exit 1
    fi
    # Belt-and-braces: never hand a disk with data on it to --wipe.
    P3_CHECK=$(qga_call exec /bin/sh -c \
        "lsblk -nro NAME,FSTYPE $P3_TARGET | tail -n +2 | tr -d ' \n'" 2>/dev/null | tr -d '\r\n ')
    if [ -n "$P3_CHECK" ]; then
        fail "Phase 3: refusing — target $P3_TARGET is not blank ($P3_CHECK)"
        exit 1
    fi
    pass "Phase 3: graduate target = $P3_TARGET (verified blank)"

    step "Phase 3: graduating to native disk (this installs the OS onto $P3_TARGET)..."
    qga_call exec /bin/sh -c \
        "WOOTC_GN_ALLOW_DESTRUCTIVE=1 wootc-go-native migrate --to-disk $P3_TARGET --execute 2>&1" \
        2>/dev/null | tail -40
    if qga_call exec /bin/sh -c \
        "lsblk -no FSTYPE $P3_TARGET 2>/dev/null | grep -q . && echo GRADUATED" 2>/dev/null \
        | grep -q GRADUATED; then
        pass "Phase 3: native install written to $P3_TARGET (Windows + root.disk intact)"
    else
        fail "Phase 3: graduate did not produce a filesystem on $P3_TARGET"
        exit 1
    fi
fi

# ── Step 9: Verify passthrough/migration setup ──────────────────────────────
step "Verifying passthrough and migration setup..."

# Collect additional boot output for passthrough verification.
# The installed system should show:
#   - Host NTFS bind-mount (/host or wootc-host-bind)
#   - Loop device setup (losetup root.disk)
#   - No mount failures or kernel panics
info "Collecting boot-time passthrough markers from serial console..."

PASSTHROUGH_TIMEOUT=60
PASSTHROUGH_DEADLINE=$(deadline_in "$PASSTHROUGH_TIMEOUT")
PASSTHROUGH_MARKERS=""

while ! past_deadline "$PASSTHROUGH_DEADLINE"; do
    snapshot_serial || true
    CURRENT_BYTE=$(stat -c%s "$PTY" 2>/dev/null || echo 0)
    [ "$CURRENT_BYTE" -lt "$LAST_BYTE" ] && LAST_BYTE=0
    if [ "$CURRENT_BYTE" -gt "$LAST_BYTE" ]; then
        PASSTHROUGH_MARKERS+=$(tail -c "+$((LAST_BYTE + 1))" "$PTY")
        PASSTHROUGH_MARKERS+=$'\n'
        LAST_BYTE=$CURRENT_BYTE
    fi
    sleep 2
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

# ── HARD GATE: prove Phase 2 actually ran ───────────────────────────────────
# Everything above passes on the ABSENCE of error strings, and the reboot step
# below sends ctrl-alt-delete — which an emergency shell obeys just as happily
# as a booted system. So a Phase 2 that never mounted its root could sail
# through to "ALL TESTS PASSED". Demand positive evidence instead: the
# loop-attach hook reporting success, or the host bridge, or the real root.
PHASE2_PROOF=$(printf '%s' "$PASSTHROUGH_MARKERS" | grep -aiE \
    "wootc: attached dynamic VHDX|host NTFS mounted via|wootc-host-bind|Reached target (multi-user|graphical)" | head -3)
if [ -n "$PHASE2_PROOF" ]; then
    pass "Phase 2 proof of life: $(printf '%s' "$PHASE2_PROOF" | head -1 | cut -c1-70)"
else
    fail "Phase 2 produced NO proof of life — no loop-attach, no host bridge, no real root."
    fail "  Refusing to report success: an unbooted Phase 2 still reboots to Windows,"
    fail "  so the return-to-Windows check below cannot distinguish it from a real boot."
    printf '%s' "$PASSTHROUGH_MARKERS" | tail -20
    exit 1
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
