#!/usr/bin/env bash
# wootc-deploy — runs inside the deployer initramfs.
#
# Finds root.disk on the NTFS partition, attaches it through losetup,
# writes a fisherman recipe, and runs fisherman to deploy the
# bootc image into the loop file.
#
# Kernel cmdline args:
#   wootc.image=ghcr.io/tuna-os/yellowfin:gnome   (required)
#   wootc.hostname=myhost                          (optional, default: tunaos)
#   wootc.debug                                     (optional, drops to shell)
#   wootc.filesystem=xfs|btrfs|ext4                (optional, default: xfs for EL10, btrfs for Fedora)
#   wootc.flatpaks=org.mozilla.firefox,...          (optional)
#   wootc.luks=none|luks-passphrase|tpm2-luks       (optional)
#   wootc.luks-passphrase=...                        (optional)
#   wootc.bootloader=grub2|systemd                   (optional)
#   wootc.composefs=0|1                              (optional)
#   wootc.debug                                      (optional, drops to shell)
#   wootc.debug_ssh_key=<base64 pubkey>              (optional, enables root SSH)

set -Eeuo pipefail

# Set once the Windows NTFS volume is mounted. Keep this log append-only so a
# failed reboot or a later deployment attempt cannot erase the evidence from
# the preceding one.
PERSIST_LOG=""

# Write through /dev/kmsg when available: stdout of a sourced initqueue hook
# lands in the journal but is not reliably forwarded to the serial console,
# which made several failures invisible to the E2E monitor.
# Write through /dev/kmsg when available: stdout of a sourced initqueue hook
# lands in the journal but is not reliably forwarded to the serial console,
# which made several failures invisible to the E2E monitor.
#
# Two things the kmsg write MUST get right, both learned the hard way when the
# initramfs-guard line below never reached the E2E log:
#   1. Emit an explicit <N> priority. A kmsg line with no <N> prefix inherits
#      the kernel default level, so whether it reaches the console depends on
#      console_loglevel — which varies by Phase-2 boot path (the GRUB path adds
#      ignore_loglevel, the BLS path does not). <27> is KERN_ERR (level 3),
#      below any plausible threshold, so it always prints.
#   2. Also write to /dev/console, which bypasses printk filtering altogether.
#      Under `quiet` (console_loglevel=4) printk prints only levels STRICTLY
#      BELOW 4, so even KERN_WARNING is dropped — /dev/console is the only
#      threshold-independent path, and is how systemd's "Entering emergency
#      mode" reaches serial.
# ONE kmsg write per line, at an explicit priority. Not three.
#
# The <27> prefix is KERN_ERR (level 3). `quiet` sets console_loglevel=4 and
# printk prints levels STRICTLY BELOW it, so level 3 reaches the serial console
# on its own — which is the entire reason the priority is here. An additional
# direct /dev/console write adds nothing.
#
# It also actively broke the deploy. With stdout (console in the initramfs) plus
# kmsg-forwarded-to-console plus a direct console write, every line went out
# THREE times over a 115200-baud serial. During the verbose bootc install that
# saturates the link, and a blocking console write stalls the deployer: all
# three runners died at `phase: verification` with the serial frozen, then burned
# their full 45-minute budget. The deploy completed fine before this was added.
#
# Volume is the deciding factor, which is why the Phase-2 attach hook still does
# write to /dev/console: it emits a handful of lines at boot rather than hundreds
# during an install, and it is diagnosing a path we have never seen work.
log() {
    printf '\033[1;32m[wootc]\033[0m %s\n' "$*"
    printf '<27>[wootc] %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    [ -z "$PERSIST_LOG" ] || printf '%s [wootc] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$PERSIST_LOG" 2>/dev/null || true
}
err() {
    printf '\033[1;31m[wootc]\033[0m %s\n' "$*" >&2
    printf '<27>[wootc] ERROR: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    [ -z "$PERSIST_LOG" ] || printf '%s [wootc] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$PERSIST_LOG" 2>/dev/null || true
}
# Current phase, read by the heartbeat and useful over QGA.
phase() {
    echo "$*" > /run/wootc-phase 2>/dev/null || true
    log "phase: $*"
}

# Cap dirty page cache so multi-GB writeback streams to disk continuously.
# Unbounded dirty pages (default: 20% of RAM) made the final sync/umount sit
# in D-state for tens of minutes after a large image pull, wedging the VM.
echo 268435456 > /proc/sys/vm/dirty_bytes 2>/dev/null || true
echo 134217728 > /proc/sys/vm/dirty_background_bytes 2>/dev/null || true

# A failed target-side dracut run must not leave the Windows volume, loop
# devices, or chroot bind mounts busy.  That would prevent a useful retry from
# the deployer shell and can otherwise make the next boot non-deterministic.
NTFS_PART=""
LOOP_DEV=""
VERIFY_LOOP=""
VERIFY_CRYPT=""
SCRATCH_LOOP=""
SCRATCH_IMG=""
JOURNAL_STREAM_PID=""
HEARTBEAT_PID=""
cleanup() {
    local mount
    [[ -n "$JOURNAL_STREAM_PID" ]] && kill "$JOURNAL_STREAM_PID" 2>/dev/null || true
    [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null || true
    # Persist the boot journal to NTFS while it is still mounted: the VM has
    # no console input, so this is the only way to read fisherman/podman
    # errors after the fail-path reboot to Windows.
    if mountpoint -q /mnt/ntfs 2>/dev/null; then
        mkdir -p /mnt/ntfs/wootc/logs 2>/dev/null || true
        { journalctl -b --no-pager 2>&1 | tail -c 2000000; } \
            > /mnt/ntfs/wootc/logs/deployer-last-journal.log || true
        cat /proc/mounts > /mnt/ntfs/wootc/logs/deployer-last-mounts.log 2>&1 || true
        # reboot -f follows an unmount failure here; without an explicit sync
        # the log data never reaches the NTFS volume (observed as a
        # correct-size file full of zeros).
        sync || true
    fi
    # Deployment bind paths live deep under /mnt/verify (ostree layout);
    # unmount everything below it in reverse depth order.
    for mount in $(awk '$2 ~ "^/mnt/verify" {print $2}' /proc/mounts 2>/dev/null | sort -r); do
        umount "$mount" 2>/dev/null || true
    done
    for mount in /mnt/verify /mnt/esp /var/tmp /var/lib/containers /var/fisherman-tmp /mnt/ntfs; do
        mountpoint -q "$mount" 2>/dev/null && umount "$mount" 2>/dev/null || true
    done
    [[ -n "$VERIFY_CRYPT" ]] && cryptsetup close "$VERIFY_CRYPT" 2>/dev/null || true
    [[ -n "$VERIFY_LOOP" ]] && losetup -d "$VERIFY_LOOP" 2>/dev/null || true
    [[ -n "$SCRATCH_LOOP" ]] && losetup -d "$SCRATCH_LOOP" 2>/dev/null || true
    [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

# ── Parse kernel cmdline ────────────────────────────────────────────────────
read_cmdline() {
    local key="$1" default="${2:-}"
    local arg source="${3:-/proc/cmdline}"
    # Read the full cmdline (may be one space-separated line),
    # split into words, and find the matching key=value pair
    while IFS= read -r line; do
        # shellcheck disable=SC2013  # intentional word splitting on cmdline
        for arg in $line; do
            case "$arg" in
                "${key}="*) echo "${arg#*=}"; return ;;
            esac
        done
    done < "$source"
    echo "$default"
}

IMAGE="$(read_cmdline wootc.image)"
FILESYSTEM="$(read_cmdline wootc.filesystem xfs)"
HOSTNAME="$(read_cmdline wootc.hostname tunaos)"
FLATPAKS="$(read_cmdline wootc.flatpaks)"
LUKS_TYPE="$(read_cmdline wootc.luks none)"
LUKS_PASSPHRASE="$(read_cmdline wootc.luks-passphrase)"
VAULT_PATH="$(read_cmdline wootc.vault)"
DEBUG="$(read_cmdline wootc.debug)"
# Both default to `auto`: the deployer detects the deployment backend AND the
# bootloader DEFINITIVELY from the image (see the detection block below), because
# they are a property of the image, not something the caller must know. An
# explicit wootc.bootloader=grub2|systemd or wootc.composefs=0|1 still overrides.
BOOTLOADER="$(read_cmdline wootc.bootloader auto)"
COMPOSEFS="$(read_cmdline wootc.composefs auto)"

# Debug SSH access into the deployed Phase-2 system (mirrors corral): a public
# key enables passwordless SSH for troubleshooting migrations and drives E2E
# verification over ssh instead of the serial console. Sources, in order:
#   1. a staged file  /mnt/ntfs/wootc/install/debug_authorized_keys
#   2. base64 on the cmdline  wootc.debug_ssh_key=<base64 pubkey>
# When a key is present we also force sshd on via a kernel karg, because the
# desktop images ship sshd disabled by preset.
DEBUG_SSH_KEY=""
DEBUG_SSH_KEY_B64="$(read_cmdline wootc.debug_ssh_key)"
if [[ -n "$DEBUG_SSH_KEY_B64" ]]; then
    DEBUG_SSH_KEY="$(printf '%s' "$DEBUG_SSH_KEY_B64" | base64 -d 2>/dev/null || true)"
fi
# The staged file is read later (after the NTFS mount); recorded here as a flag.
DEBUG_SSH_KEY_FILE="/mnt/ntfs/wootc/install/debug_authorized_keys"

case "$BOOTLOADER" in grub2|systemd|auto) ;; *) err "unsupported bootloader: $BOOTLOADER"; exit 1 ;; esac
case "$COMPOSEFS" in 0|1|auto) ;; *) err "unsupported composefs value: $COMPOSEFS (want 0|1|auto)"; exit 1 ;; esac

case "$LUKS_TYPE" in
    none|luks-passphrase|tpm2-luks|tpm2-luks-passphrase) ;;
    *) err "unsupported wootc.luks type: $LUKS_TYPE"; exit 1 ;;
esac
if [[ "$LUKS_TYPE" == *passphrase && -z "$LUKS_PASSPHRASE" ]]; then
    err "$LUKS_TYPE requires wootc.luks-passphrase"
    exit 1
fi

if [[ -z "$IMAGE" ]]; then
    err "wootc.image= not set on kernel command line"
    err "Add wootc.image=ghcr.io/tuna-os/yellowfin:gnome to the GRUB menu entry"
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

ROOT_DISK_PATH="/wootc/disks/root.disk"

# ── Find NTFS partition containing root.disk ────────────────────────────────
log "Searching for ${ROOT_DISK_PATH}..."

# The initqueue/online hook fires when the network is up, which can beat SCSI
# disk enumeration by seconds. Retry the scan until the disk appears instead
# of failing on the first pass.
modprobe ntfs3 2>/dev/null || true
modprobe virtio_scsi 2>/dev/null || true

# Try progressively more forgiving mounts, and SAY what happened.
#
# A plain `mount -t ntfs3 -o ro` is not enough. On the BitLocker path
# setup-wootc.ps1 shrinks C:, creates a fresh NTFS volume for Linux and then
# reboots almost immediately — so that volume still carries the NTFS dirty bit,
# and ntfs3 REFUSES a dirty volume even read-only. The mount failed, the
# partition was skipped in silence, and the deployer reported
#   Could not find /wootc/disks/root.disk on any partition
# while the volume holding it sat right there (observed twice, #36).
#
# `-o force` tells ntfs3 to mount a dirty volume anyway; read-only makes that
# safe here since we only look for a file. ntfs-3g is the last resort where the
# kernel driver is absent entirely.
try_mount_scan() {
    local dev="$1"
    mount -t ntfs3 -o ro "$dev" /mnt/scan 2>/dev/null && { echo "ntfs3"; return 0; }
    mount -t ntfs3 -o ro,force "$dev" /mnt/scan 2>/dev/null && { echo "ntfs3-force"; return 0; }
    command -v ntfs-3g >/dev/null 2>&1 &&
        ntfs-3g -o ro "$dev" /mnt/scan 2>/dev/null && { echo "ntfs-3g"; return 0; }
    return 1
}

scan_for_root_disk() {
    local dev drv
    for dev in /dev/sd* /dev/nvme* /dev/vd*; do
        [[ -b "$dev" ]] || continue
        mkdir -p /mnt/scan
        if drv=$(try_mount_scan "$dev"); then
            if [[ -f "/mnt/scan${ROOT_DISK_PATH}" ]]; then
                log "  found ${ROOT_DISK_PATH} on ${dev} (mounted via ${drv})"
                NTFS_PART="$dev"
                umount /mnt/scan
                return 0
            fi
            log "  ${dev}: mounted via ${drv}, no ${ROOT_DISK_PATH}"
            umount /mnt/scan
        else
            # Silence here is what made #36 unattributable for two runs.
            log "  ${dev}: not mountable as NTFS (ntfs3, ntfs3+force, ntfs-3g all failed)"
        fi
    done
    return 1
}

for attempt in {1..24}; do
    udevadm settle --timeout=10 2>/dev/null || true
    if scan_for_root_disk; then
        log "Found ${ROOT_DISK_PATH} on ${NTFS_PART}"
        # Topology matters once a spare disk is present (the Phase-3 graduate
        # target): a second disk shifts enumeration and has been observed to
        # break the Phase-2 loop-attach. Record exactly what we resolved so a
        # multi-disk failure is diagnosable from the serial alone.
        log "  disk topology:"
        lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL 2>/dev/null | sed 's/^/    /' >&2 || true
        log "  NTFS_PART=${NTFS_PART} (uuid=$(blkid -s UUID -o value "$NTFS_PART" 2>/dev/null))"
        break
    fi
    log "root.disk not found (attempt ${attempt}/24); retrying in 5s..."
    [[ "$attempt" -eq 1 ]] && { err "block devices seen so far:"; cat /proc/partitions >&2 || true; }
    sleep 5
done

if [[ -z "$NTFS_PART" ]]; then
    err "Could not find ${ROOT_DISK_PATH} on any partition"
    err "final /proc/partitions:"
    cat /proc/partitions >&2 || true
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

# ── Mount NTFS read-write ───────────────────────────────────────────────────
mkdir -p /mnt/ntfs
if ! mount -t ntfs3 -o rw "$NTFS_PART" /mnt/ntfs; then
    err "cannot mount ${NTFS_PART} read-write — the NTFS volume is likely dirty"
    err "(Windows hibernated, Fast Startup, or an unclean shutdown)."
    err "Boot Windows once, perform a full shutdown, and retry."
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi
DISK="/mnt/ntfs/wootc/disks/root.disk"

# Now that NTFS is mounted, pick up a staged debug SSH key if the cmdline did
# not carry one, and derive the sshd-enable kernel karg (empty when no key).
if [[ -z "$DEBUG_SSH_KEY" && -f "$DEBUG_SSH_KEY_FILE" ]]; then
    DEBUG_SSH_KEY="$(grep -E '^(ssh-|ecdsa-|sk-)' "$DEBUG_SSH_KEY_FILE" 2>/dev/null | head -1 || true)"
fi
SSHD_KARG=""
if [[ -n "$DEBUG_SSH_KEY" ]]; then
    SSHD_KARG="systemd.wants=sshd.service"
fi
# Always give the migrated system a control channel: enable qemu-guest-agent on
# every Phase-2 boot. It's a no-op on bare metal (no QEMU) but makes the system
# manageable, recoverable, and testable inside a VM — a migrated user should
# never end up with an unreachable box. Combined below into PHASE2_KARGS.
MGMT_KARG="systemd.wants=qemu-guest-agent.service"
# rd.timeout bounds how long the initramfs waits for the root device before
# dropping to an emergency shell. Without it a Phase-2 boot whose loop-attach
# hook failed (so root=UUID never appears) hangs FOREVER on
# dev-disk-by-uuid-<root>.device ("no limit") — an invisible 5-minute wedge in
# CI and a dead machine for a user. Bound it so the failure is fast and lands
# in a shell with the actual error instead of a silent spinner.
TIMEOUT_KARG="rd.timeout=120"

# loop.max_part on the CMDLINE, not via modprobe.
#
# The Phase-2 hook attaches root.disk with `losetup --partscan`, and everything
# downstream depends on /dev/loopNpM appearing so the root UUID reaches udev.
# `modprobe loop max_part=16` cannot guarantee that: module parameters apply
# only at LOAD time, so it is a no-op when loop is already loaded or built into
# the kernel (CONFIG_BLK_DEV_LOOP=y is common).
#
# Measured: --partscan DOES create the nodes even with max_part=0, because it
# sets LO_FLAGS_PARTSCAN on that device rather than relying on the module
# default (verified on a 64M GPT image — p1 and p2 both appeared). So this is
# insurance, not a fix: a kernel cmdline parameter is honoured whether loop is
# built in or modular, and costs nothing. If a target kernel ever behaves
# differently, this is what keeps Phase 2 bootable.
LOOP_KARG="loop.max_part=16"
PHASE2_KARGS="$MGMT_KARG $SSHD_KARG $TIMEOUT_KARG $LOOP_KARG"

# ── Live telemetry ──────────────────────────────────────────────────────────
# Stream the journal to NTFS continuously: the exit-trap post-mortem is
# written by exactly the code that can hang, so a wedge must still leave a
# fresh journal on disk. Heartbeat gives the serial monitor a liveness and
# resource signal (a 7-minute image pull must look different from a hang).
LOG_DIR=/mnt/ntfs/wootc/logs
mkdir -p "$LOG_DIR"
PERSIST_LOG="$LOG_DIR/deployer.log"
log "Persistent deployer log started: C:\\wootc\\logs\\deployer.log"
(
    set +eu  # telemetry must survive any single command failing
    while true; do
        { journalctl -b --no-pager 2>/dev/null | tail -c 2000000; } \
            > "$LOG_DIR/live-journal.log.tmp" 2>/dev/null &&
            mv -f "$LOG_DIR/live-journal.log.tmp" "$LOG_DIR/live-journal.log" 2>/dev/null
        sync 2>/dev/null
        sleep 15
    done
) &
JOURNAL_STREAM_PID=$!
(
    set +eu  # df fails until the scratch is mounted; keep beating anyway
    while true; do
        printf '[wootc] heartbeat phase=%s scratch=%s mem_avail=%skB\n' \
            "$(cat /run/wootc-phase 2>/dev/null || echo unset)" \
            "$(df -h /var/fisherman-tmp 2>/dev/null | awk 'NR==2{print $3"/"$2}')" \
            "$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)" \
            > /dev/kmsg 2>/dev/null || true
        sleep 30
    done
) &
HEARTBEAT_PID=$!
phase "ntfs-mounted"

# ── Container storage scratch ───────────────────────────────────────────────
# The initramfs root is ramfs: a multi-GB image pull there exhausts RAM.
# fisherman does all heavy I/O under its scratch dir /var/fisherman-tmp
# (podman --root, OCI cache, bootc /var/tmp bind), so back that path with an
# ext4 loop file on the Windows NTFS partition (fisherman's overlay probe
# needs a real POSIX fs, so not NTFS directly). Deleted after deployment.
SCRATCH_IMG="/mnt/ntfs/wootc/cache/deployer-scratch.img"
phase "scratch-setup"
log "Creating fisherman scratch at ${SCRATCH_IMG}..."
mkdir -p /mnt/ntfs/wootc/cache /var/fisherman-tmp /var/lib/containers
# ntfs3 allocates the full size on truncate (no sparse support), so this
# must fit in C:'s free space alongside the dynamically allocated root.disk.
# 13G: with disk-backed default storage fisherman pulls the full extracted
# image (~10G) here plus transient blob staging; the target disk holds only
# the ostree deployment.
#
# Reuse an existing scratch: containers-storage inside it caches the pulled
# image, turning the multi-minute pull into a digest check on retries.
if [[ ! -f "$SCRATCH_IMG" ]] || [[ "$(blkid -o value -s TYPE "$SCRATCH_IMG" 2>/dev/null)" != "ext4" ]]; then
    log "Initializing new scratch filesystem..."
    truncate -s 13G "$SCRATCH_IMG"
    mkfs.ext4 -q -F "$SCRATCH_IMG"
else
    log "Reusing existing scratch (cached container storage)"
fi
SCRATCH_LOOP=$(losetup -f --show "$SCRATCH_IMG")
mount "$SCRATCH_LOOP" /var/fisherman-tmp
# Catch anything that still lands in default podman storage.
mkdir -p /var/fisherman-tmp/host-containers
mount --bind /var/fisherman-tmp/host-containers /var/lib/containers
# containers/image stages large pull blobs in /var/tmp regardless of the
# storage --root; on the initramfs ramfs that exhausts RAM mid-pull.
mkdir -p /var/fisherman-tmp/var-tmp /var/tmp
mount --bind /var/fisherman-tmp/var-tmp /var/tmp

# ── Registry pre-flight ─────────────────────────────────────────────────────
# Surface DNS/TLS/registry problems with a real error message on the console
# instead of a bare podman exit status buried inside fisherman.
phase "registry-preflight"
log "Registry pre-flight for ${IMAGE}..."
if [[ ! -s /etc/resolv.conf ]]; then
    cp /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi
log "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null || echo '<missing>')"
if ! skopeo inspect --retry-times 3 "docker://${IMAGE}" >/dev/null; then
    # Dockur's guest DHCP normally supplies its internal DNS forwarder. Some
    # rootless runners can route Internet traffic but that forwarder cannot
    # reach an upstream resolver; retry directly before treating the registry
    # as unavailable.
    FALLBACK_DNS="${WOOTC_FALLBACK_DNS:-1.1.1.1}"
    log "DHCP DNS failed; retrying registry pre-flight with ${FALLBACK_DNS}..."
    printf 'nameserver %s\n' "$FALLBACK_DNS" > /etc/resolv.conf
    log "resolv.conf fallback: $(cat /etc/resolv.conf)"
    if ! skopeo inspect --retry-times 3 "docker://${IMAGE}" >/dev/null; then
        err "cannot reach registry for ${IMAGE} (see skopeo error above)"
        if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
    fi
fi

# ── Attach the RAW image through losetup ───────────────────────────────────
# root.disk is a byte-addressable sparse raw image, so the kernel loop driver
# attaches it directly. No format driver, and — crucially — no binary to stage.
#
# This replaced qemu-nbd + VHDX. Target bootc images ship losetup but NOT
# qemu-nbd (verified against ghcr.io/tuna-os/yellowfin:gnome), so the VHDX path
# forced a foreign Fedora qemu-nbd and its 26-library closure into an initramfs
# built from the target's libraries — a libfuse3 soname mismatch, a loader
# wrapper, and a silent failure that cost most of a day. losetup is already
# there, in both the deployer and the target.
#
# --partscan is load-bearing: it makes /dev/loopNpM appear, which is how the
# root partition's UUID reaches udev and lets the ordinary sysroot.mount work.
# `modprobe loop max_part=16` is deliberately NOT relied upon: module params
# apply only at LOAD time, so it is a no-op when loop is already loaded or built
# in (CONFIG_BLK_DEV_LOOP=y is common). Empirically --partscan still creates
# /dev/loopNpM with max_part=0, because it sets LO_FLAGS_PARTSCAN on that
# specific device rather than depending on the module default — verified on a
# 64M GPT image: p1 and p2 both appeared. The modprobe stays as belt-and-braces
# for kernels where loop is a module and not yet loaded.
modprobe loop max_part=16 2>/dev/null || true
LOOP_DEV=$(losetup --find --show --partscan "$DISK")
if [[ -z "$LOOP_DEV" ]]; then
    err "losetup could not attach $DISK"
    exit 1
fi
udevadm settle --timeout=10 2>/dev/null || true
log "Attached raw image ${DISK} as ${LOOP_DEV}"

# ── Ingest vault.json (secure credential handoff) ───────────────────────────
VAULT_USER=""
VAULT_PASSWORD_HASH=""
if [[ -n "$VAULT_PATH" ]]; then
    VAULT_FILE="/mnt/ntfs${VAULT_PATH}"
    if [[ -f "$VAULT_FILE" ]]; then
        log "Ingesting vault.json from ${VAULT_FILE}..."
        VAULT_USER=$(jq -r '.username // empty' "$VAULT_FILE" 2>/dev/null || true)
        VAULT_PASSWORD_HASH=$(jq -r '.password_hash // empty' "$VAULT_FILE" 2>/dev/null || true)
        VAULT_HOSTNAME=$(jq -r '.hostname // empty' "$VAULT_FILE" 2>/dev/null || true)
        if [[ -n "$VAULT_HOSTNAME" ]]; then
            HOSTNAME="$VAULT_HOSTNAME"
        fi
        # Shred before deployment — no credentials persist on NTFS
        log "Shredding vault.json..."
        shred -u "$VAULT_FILE" 2>/dev/null || rm -f "$VAULT_FILE"
    else
        log "vault.json not found at ${VAULT_FILE} — using cmdline defaults"
    fi
fi

# ╔═══════════════════════════════════════════════════════════════════════════
# ║ PROVISIONER: bootc/fisherman — begins here.
# ║ Everything above this line is generic orchestration (disk discovery, NTFS,
# ║ telemetry, scratch, credential vault, block-device attach) and must stay
# ║ free of bootc/ostree concepts. Everything from here to the matching END
# ║ banner turns the attached block device into a bootable root and would be
# ║ replaced wholesale when adapting wootc to another deployment method.
# ║ Contract: docs/architecture-boundary.md.
# ╚═══════════════════════════════════════════════════════════════════════════

# ── Ensure the image can mount NTFS at Phase-2 boot ─────────────────────────
# Phase-2 boots Linux from root.disk hosted on the Windows NTFS: the initramfs
# hook MUST be able to mount that NTFS. Enterprise Linux kernels ship no ntfs3,
# so if the image has neither the ntfs3 kernel module nor a userspace ntfs-3g,
# inject ntfs-3g using the image's OWN repos (matching glibc) and persist it as
# a local derived image (podman commit — the same layer remora persists). This
# lets wootc boot arbitrary bootc images, not only ones that ship NTFS support.
ensure_ntfs_support() {
    if podman run --rm "$IMAGE" sh -c \
        'command -v ntfs-3g >/dev/null 2>&1 || command -v mount.ntfs >/dev/null 2>&1 || \
         ls /usr/lib/modules/*/kernel/fs/ntfs3/ntfs3.ko* >/dev/null 2>&1 || \
         grep -qw ntfs3 /proc/filesystems 2>/dev/null || \
         grep -qxE "CONFIG_NTFS3_FS=[ym]" /usr/lib/modules/*/config 2>/dev/null'; then
        log "Image already has an NTFS driver (ntfs3 or ntfs-3g)."
        return 0
    fi
    # NOTE: the capability check above is NOT authoritative. It looks for an
    # ntfs3.ko and an ntfs-3g binary, but a kernel with CONFIG_NTFS3=y (built
    # in, no module file) mounts ntfs3 fine and shows neither. Evidence: a run
    # where this injection FAILED still booted Phase-2 successfully, so the
    # image could mount NTFS all along. Treat injection as best-effort belt —
    # the braces are the hook's runtime ntfs3 -> ntfs-3g fallback plus the
    # loop-attach guard. Making these failures fatal broke deploys that worked.
    log "No NTFS driver in ${IMAGE}; injecting ntfs-3g (persisted layer)…"
    local derived="localhost/wootc-ntfs-injected:latest" cname="wootc-ntfs-inject"
    podman rm -f "$cname" >/dev/null 2>&1 || true
    # FOREGROUND run, not `-d`: detached mode does not work in the deployer
    # initramfs (every previous injection died at "could not start the
    # container"), while the plain `podman run` used elsewhere here works fine.
    # No --rm, because the stopped container is what we commit.
    # ntfs-3g is NOT in the EL base repos — it lives in EPEL. On AlmaLinux/RHEL
    # (yellowfin is EL10) a plain `dnf install ntfs-3g` fails "no package", which
    # is exactly why Phase 2 hit "cannot mount host NTFS (no ntfs3, no ntfs-3g)":
    # the EL10 kernel ships no ntfs3 AND the image had no ntfs-3g. Enable EPEL
    # (+CRB, which many EPEL packages need) first, then install. Verified against
    # ghcr.io/tuna-os/yellowfin:gnome — installs ntfs-3g-2026.2.25.el10. Fedora
    # images still work via the leading direct attempt.
    # --network=host is load-bearing: this runs inside the deployer's minimal
    # initramfs, where podman's default netavark path fails ("netavark: nftables
    # error: nft did not return successfully" in the serial — nft kmods/tables
    # are not fully available in the stripped initramfs). A fresh `podman run`
    # needs a container netns; --network=host reuses the deployer VM's HOST netns
    # (the same one bootc pull already succeeds on) and its /etc/resolv.conf, so
    # dnf can actually reach EPEL. Without it the install fails on BOTH himachal
    # and the hosted runner, and Phase 2 has no NTFS driver.
    if ! podman run --name "$cname" --network=host "$IMAGE" sh -c \
        'dnf install -y ntfs-3g || \
         { { dnf install -y epel-release || \
             dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm; } && \
           { dnf config-manager --set-enabled crb 2>/dev/null || true; } && \
           dnf install -y ntfs-3g; } || \
         microdnf install -y ntfs-3g || rpm-ostree install ntfs-3g'; then
        err "  [WARN] ntfs-3g install failed in ${IMAGE} (network/repo?); relying on the image's own NTFS support"
        podman logs "$cname" 2>&1 | tail -10 >&2 || true
        podman rm -f "$cname" >/dev/null 2>&1 || true
        return 1
    fi
    if ! podman commit -q "$cname" "$derived" >/dev/null 2>&1; then
        err "  [WARN] could not commit the NTFS-injected image (disk space?); deploying the original"
        podman rm -f "$cname" >/dev/null 2>&1 || true
        return 1
    fi
    podman rm -f "$cname" >/dev/null 2>&1 || true
    IMAGE="$derived"
    log "  [PASS] injected ntfs-3g; deploying ${IMAGE}"
    # Prove it actually landed rather than trusting the commit.
    if ! podman run --rm "$IMAGE" sh -c 'command -v ntfs-3g >/dev/null'; then
        err "  [WARN] ntfs-3g still absent from ${IMAGE} after injection"
        return 1
    fi
    log "  [PASS] verified ntfs-3g present in the deployed image"
}
ensure_ntfs_support || log "NTFS injection unavailable; using the image's own NTFS support"

# ── Resolve deployment backend and bootloader from the image ─────────────
# Probe the image ONCE for the two independent signals that decide how to deploy:
#   BACKEND=ostree → the image ships signed GRUB in bootupd. bootupd 0.2.x
#             stored the binaries below updates/EFI/<vendor>; current Fedora
#             stores versioned binaries below /usr/lib/efi and keeps only
#             EFI.json below bootupd/updates.
#   BACKEND=composefs-native → it ships systemd-boot but no bootupctl. Unknown
#             or failed probes abort rather than guessing from missing evidence.
#   SEALED=1 → the ostree rootfs is composefs-SEALED (prepare-root.conf [composefs]
#             enabled). This needs fs-verity → ext4 — INDEPENDENT of the backend,
#             because traditional-ostree images (bluefin, bonito) are sealed too.
# This is the crux fix: the old detector keyed the BACKEND off SEALED, so it forced
# --composefs-backend (systemd-boot/UKI) onto traditional-ostree images. Verified
# on himachal: dakota/marlin ship no grub + systemd-boot (native); bluefin/bonito
# ship bootupctl + grubx64.efi (ostree). wootc.composefs / wootc.bootloader override.
if [[ "$COMPOSEFS" == auto || "$BOOTLOADER" == auto ]]; then
    if ! DETECT="$(podman run --rm --network=host "$IMAGE" sh -c '
        if { ls /usr/lib/bootupd/updates/EFI/*/grubx64.efi >/dev/null 2>&1 ||
             { test -f /usr/lib/bootupd/updates/EFI.json &&
               find /usr/lib/efi/grub2 -type f -name grubx64.efi -print -quit 2>/dev/null | grep -q . &&
               find /usr/lib/efi/shim -type f -name shimx64.efi -print -quit 2>/dev/null | grep -q .; }; }; then
            echo BACKEND=ostree
        elif test -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi && ! command -v bootupctl >/dev/null 2>&1; then
            echo BACKEND=composefs-native
        else
            echo BACKEND=unknown
        fi
        grep -A8 "^\[composefs\]" /usr/lib/ostree/prepare-root.conf 2>/dev/null \
          | grep -qiE "enabled[[:space:]]*=[[:space:]]*(yes|true|1|signed)" && echo SEALED=1 || echo SEALED=0
    ' 2>/dev/null)"; then
        err "failed to inspect image for deployment backend: $IMAGE"
        exit 1
    fi
    if grep -q '^BACKEND=ostree$' <<<"$DETECT"; then
        [[ "$COMPOSEFS"  == auto ]] && COMPOSEFS=0
        [[ "$BOOTLOADER" == auto ]] && BOOTLOADER=grub2
        log "  backend: image ships signed grub → traditional ostree (grub2, no --composefs-backend)"
    elif grep -q '^BACKEND=composefs-native$' <<<"$DETECT"; then
        [[ "$COMPOSEFS"  == auto ]] && COMPOSEFS=1
        [[ "$BOOTLOADER" == auto ]] && BOOTLOADER=systemd
        log "  backend: image ships only systemd-boot → composefs-native (--composefs-backend, systemd-boot)"
    else
        err "image exposes neither a signed bootupd GRUB nor systemd-boot-only backend: $IMAGE"
        exit 1
    fi
    grep -q 'SEALED=1' <<<"$DETECT" && ROOTFS_SEALED=1 || ROOTFS_SEALED=0
fi
# Any lingering auto (e.g. an explicit wootc.composefs but auto bootloader) falls
# back to safe defaults.
[[ "$BOOTLOADER" == auto ]] && BOOTLOADER=grub2
[[ "$COMPOSEFS"  == auto ]] && COMPOSEFS=0

# A composefs-SEALED rootfs (native OR traditional ostree) needs fs-verity, which
# fisherman only enables for ext4 (`mkfs.ext4 -O verity`); the deployer default
# xfs has none, so fisherman fails installing the root ("mounting root: … exit
# status 32", seen on dakota). Force ext4 when sealed unless the caller picked a
# filesystem. Keyed off SEALED, NOT the backend — bonito (ostree) is sealed too.
if [[ "${ROOTFS_SEALED:-0}" == 1 || "$COMPOSEFS" == 1 ]] && \
   [[ "$FILESYSTEM" == xfs && -z "$(read_cmdline wootc.filesystem)" ]]; then
    FILESYSTEM=ext4
    log "  composefs-sealed rootfs → ext4 (fs-verity); deployer default xfs has none"
fi

# ── Write fisherman recipe ──────────────────────────────────────────────────
# Fisherman handles partitioning, formatting, bootc install to-filesystem,
# Flatpaks, and kernel cmdline injection. We just point it at the loop device.

FLATPAKS_JSON="[]"
if [[ -n "$FLATPAKS" ]]; then
    FLATPAKS_JSON="[$(echo "$FLATPAKS" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
fi

# Build LUKS encryption JSON
LUKS_JSON='"encryption": { "type": "none" }'
if [[ "$LUKS_TYPE" != "none" ]]; then
    if [[ -n "$LUKS_PASSPHRASE" ]]; then
        LUKS_JSON="\"encryption\": { \"type\": \"${LUKS_TYPE}\", \"passphrase\": \"${LUKS_PASSPHRASE}\" }"
    else
        LUKS_JSON="\"encryption\": { \"type\": \"${LUKS_TYPE}\" }"
    fi
fi

# Build user JSON if vault provided credentials
USER_JSON=""
if [[ -n "$VAULT_USER" && -n "$VAULT_PASSWORD_HASH" ]]; then
    USER_JSON=",\"user\": { \"username\": \"${VAULT_USER}\", \"password\": \"${VAULT_PASSWORD_HASH}\", \"groups\": [\"wheel\", \"video\", \"audio\"] }"
fi

RECIPE="/tmp/recipe.json"
cat > "$RECIPE" << EOF
{
  "disk": "${LOOP_DEV}",
  "filesystem": "${FILESYSTEM}",
  "composeFsBackend": $([[ "$COMPOSEFS" == 1 ]] && echo true || echo false),
	"bootloader": "${BOOTLOADER}",
  "unifiedStorage": false,
  "selinuxDisabled": false,
  ${LUKS_JSON},
  "image": "${IMAGE}",
  "hostname": "${HOSTNAME}",
  "flatpaks": ${FLATPAKS_JSON}${USER_JSON}
}
EOF

log "Fisherman recipe:"
# The serial console and journal are persisted for E2E diagnostics. Never put
# the disk-unlock secret in either one.
jq 'if .encryption.passphrase then .encryption.passphrase = "<redacted>" else . end' "$RECIPE"

# ── Run fisherman ───────────────────────────────────────────────────────────
phase "fisherman"
log "Running fisherman — this pulls the image and deploys it..."
fisherman "$RECIPE"

losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── Post-deployment verification ─────────────────────────────────────────────
# Verify the installed system's passthrough and migration setup before rebooting.
# These markers are captured by the e2e test's serial console monitor.

phase "verification"
log "Verifying installed system setup..."

# DURABLE per-stage marker. deployer.log lives on the Windows NTFS mount, so a
# disturbed mount silently truncates it (the "status from a proxy" trap) — and
# the serial is overwritten by the Phase-2 boot. This file lives on the DEPLOYED
# disk's /boot, which survives in data.qcow2 and is reachable with `virt-cat -m
# <root> /boot/wootc-verify.stage`. It is the authoritative record of exactly how
# far verify got — the discriminator for a composefs deploy that aborts before
# the ESP staging (read-only /usr is the leading suspect). VSTAGE_MARK is set
# once $DEPLOY_ROOT is known (below); vstage() is a no-op until then.
VSTAGE_MARK=""
vstage() {
    [ -n "$VSTAGE_MARK" ] && printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$VSTAGE_MARK" 2>/dev/null || true
    log "vstage: $*"
}

# Re-mount the installed disk while its NTFS backing mount is still live.
# `losetup --find` picks a fresh loop device rather than reusing the previous
# one, so verification is independent of any teardown race on the old nodes.
VERIFY_LOOP=$(losetup --find --show --partscan "$DISK")
if [[ -z "$VERIFY_LOOP" ]]; then
    err "losetup could not attach $DISK for verification"
    exit 1
fi

# qemu-nbd publishes the capacity change before the partition scan completes.
# Wait for the root partition explicitly instead of treating a successful
# udevadm settle as proof that /dev/nbd*p* nodes are ready.
for _ in {1..20}; do
    udevadm settle --timeout=1 2>/dev/null || true
    [[ -b "${VERIFY_LOOP}p3" ]] && break
    sleep 1
done
if [[ ! -b "${VERIFY_LOOP}p3" ]]; then
    err "  [WARN] ${VERIFY_LOOP} partition nodes did not appear for verification"
fi

# Fisherman closes its mapper before returning. Re-open an encrypted root for
# post-install verification; TPM modes use the token enrolled by fisherman,
# while passphrase-only mode feeds the key over stdin (never argv or logs).
VERIFY_ROOT_DEVICE="${VERIFY_LOOP}p3"
if [[ "$LUKS_TYPE" != "none" && -b "$VERIFY_ROOT_DEVICE" ]]; then
    VERIFY_CRYPT=wootc-verify-root
    if [[ "$LUKS_TYPE" == tpm2-* ]]; then
        /usr/lib/systemd/systemd-cryptsetup attach "$VERIFY_CRYPT" "$VERIFY_ROOT_DEVICE" - tpm2-device=auto
    else
        printf '%s' "$LUKS_PASSPHRASE" | \
            cryptsetup open --key-file=- "$VERIFY_ROOT_DEVICE" "$VERIFY_CRYPT"
    fi
    VERIFY_ROOT_DEVICE="/dev/mapper/$VERIFY_CRYPT"
    log "Opened encrypted root for verification"
fi

# Find the root partition inside the loop device. bootc/ostree roots have no
# top-level /etc — the OS tree lives under /ostree/deploy/<stateroot>/deploy/.
VERIFY_ROOT=""
for p in "$VERIFY_ROOT_DEVICE" "${VERIFY_LOOP}"p*; do
    [[ -b "$p" ]] || continue
    mkdir -p /mnt/verify
    if mount -o rw "$p" /mnt/verify 2>/dev/null; then
        if [[ -d /mnt/verify/ostree/deploy || -f /mnt/verify/etc/os-release ]]; then
            VERIFY_ROOT="$p"
            break
        fi
        umount /mnt/verify 2>/dev/null
    fi
done

if [[ -n "$VERIFY_ROOT" ]]; then
    log "Mounted installed system root at ${VERIFY_ROOT} for verification"

    # Resolve the OS tree: the ostree deployment dir when present, the
    # filesystem root otherwise (classic layout).
    shopt -s nullglob
    deployments=(/mnt/verify/ostree/deploy/*/deploy/*.0)
    shopt -u nullglob
    if (( ${#deployments[@]} > 0 )); then
        DEPLOY_ROOT="${deployments[0]}"
        log "  ostree deployment: ${DEPLOY_ROOT#/mnt/verify}"
    else
        DEPLOY_ROOT="/mnt/verify"
    fi

    VERIFY_BOOT="${VERIFY_LOOP}p2"
    if [[ ! -b "$VERIFY_BOOT" ]]; then
        err "  [FAIL] expected /boot partition ${VERIFY_BOOT} is missing"
        exit 1
    fi
    mkdir -p "$DEPLOY_ROOT/boot"
    mount "$VERIFY_BOOT" "$DEPLOY_ROOT/boot"
    # Everything from here to the closure PASS used to be SILENT. A deploy hung
    # somewhere in this stretch for 31 minutes and then the box rebooted, and
    # the journal's last line was this mount — leaving no way to tell which step
    # blocked. Each step now announces itself; a hang is identified by which
    # line is LAST rather than by guessing.
    log "  verify: /boot mounted, staging Phase-2 boot support"
    # /boot is now mounted and writable and survives in data.qcow2 — arm the
    # durable stage marker. From here every major verify step records itself, so
    # an abort (read-only /usr under composefs is the leading suspect) is pinned
    # to an exact stage instead of inferred from a truncated NTFS log.
    VSTAGE_MARK="$DEPLOY_ROOT/boot/wootc-verify.stage"
    vstage "verify-start bootloader=$BOOTLOADER composefs=$COMPOSEFS filesystem=$FILESYSTEM"
    # Collect problems in this stretch instead of dying at the first one.
    #
    # Each E2E run costs 40-90 minutes, so aborting on the first fault means one
    # bug per run. These steps are independent enough that a failure in one does
    # not invalidate the diagnosis of the next, so record and continue, then
    # report everything at the end. Genuinely unsafe conditions still abort.
    PHASE2_PROBLEMS=()

    # ── [generic] Debug SSH key for root (mirrors corral) ────────────────
    # On ostree, /root is a symlink to /var/roothome and /var lives in the
    # stateroot (…/deploy/<stateroot>/var), not in the deployment tree — so
    # write the key there. The matching sshd-enable karg is already on the
    # Phase-2 BLS entry (SSHD_KARG). No key ⇒ nothing enabled (production safe).
    if [[ -n "$DEBUG_SSH_KEY" ]]; then
        SSH_ROOTHOME=""
        if [[ "$DEPLOY_ROOT" == *"/ostree/deploy/"* ]]; then
            SSH_ROOTHOME="$(dirname "$(dirname "$DEPLOY_ROOT")")/var/roothome"
        elif [[ -d "$DEPLOY_ROOT/var/roothome" ]]; then
            SSH_ROOTHOME="$DEPLOY_ROOT/var/roothome"
        else
            SSH_ROOTHOME="$DEPLOY_ROOT/root"
        fi
        if mkdir -p "$SSH_ROOTHOME/.ssh" 2>/dev/null; then
            printf '%s\n' "$DEBUG_SSH_KEY" > "$SSH_ROOTHOME/.ssh/authorized_keys"
            chmod 700 "$SSH_ROOTHOME/.ssh"
            chmod 600 "$SSH_ROOTHOME/.ssh/authorized_keys"
            chown -R 0:0 "$SSH_ROOTHOME/.ssh" 2>/dev/null || true
            log "  [PASS] debug SSH key installed for root; sshd forced on via karg"
        else
            err "  [WARN] could not create ${SSH_ROOTHOME}/.ssh — debug SSH key not installed"
        fi
    fi

    # Install the runtime hook after bootc/fisherman has laid down the target.
    # This is the point at which Phase 2 becomes bootable: the initramfs
    # learns to attach the NTFS-backed VHDX so the root UUID appears.
    vstage "before-module-copy (writes \$DEPLOY_ROOT/usr — read-only under composefs)"
    log "  verify: copying 99wootc-boot dracut module"
    install -d "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot"
    cp -a /usr/lib/wootc/99wootc-boot/. \
        "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/"
    vstage "after-module-copy"
    log "  verify: dracut module copied (no binary staging needed for raw)"

    # NOTHING to stage here any more.
    #
    # This is where the qemu-nbd closure used to live: a foreign Fedora binary,
    # its 26 NEEDED libraries, its ld.so, a --library-path wrapper, and an
    # execute-test — all so a VHDX could be attached inside an initramfs built
    # from a DIFFERENT image's libraries. It produced a libfuse3.so.4-vs-.so.3
    # soname mismatch and a silent failure that cost most of a day.
    #
    # root.disk is now a raw image, so the Phase-2 hook uses `losetup`, which the
    # target image already ships (verified: yellowfin has /usr/sbin/losetup and
    # no qemu-nbd). No cross-image binary, no closure, no wrapper, no failure
    # mode. Deleting the component beat repairing it.

    HOST_UUID=$(blkid -s UUID -o value "$NTFS_PART")
    if [[ -z "$HOST_UUID" ]]; then
        err "  [FAIL] could not determine Windows NTFS UUID"
        exit 1
    fi
    shopt -s nullglob
    BLS_ENTRIES=("$DEPLOY_ROOT"/boot/loader/entries/*.conf)
    if (( ${#BLS_ENTRIES[@]} == 0 )); then
        err "  [FAIL] no BLS entries found on installed /boot"
        exit 1
    fi
    for entry in "${BLS_ENTRIES[@]}"; do
        grep -q 'wootc.host_uuid=' "$entry" || \
            sed -i '/^options / s|$| wootc.host_uuid='"$HOST_UUID"' loop=/wootc/disks/root.disk|' "$entry"
    done
    shopt -u nullglob

    # Regenerate the initramfs with the module and BLS arguments in place.
    # ostree keeps the live initramfs on the boot partition under
    # /boot/ostree/<stateroot>-<csum>/ — regenerate that exact file.
    for fs in dev proc sys; do mount --bind "/$fs" "$DEPLOY_ROOT/$fs"; done
    KVER=$(ls "$DEPLOY_ROOT/usr/lib/modules" 2>/dev/null | head -1)
    shopt -s nullglob
    OSTREE_INITRDS=("$DEPLOY_ROOT"/boot/ostree/*/initramfs*.img)
    shopt -u nullglob
    if [[ -n "$KVER" ]] && (( ${#OSTREE_INITRDS[@]} > 0 )); then
        INITRD_CHROOT_PATH="${OSTREE_INITRDS[0]#"$DEPLOY_ROOT"}"
        log "  Regenerating ${INITRD_CHROOT_PATH} for kernel ${KVER}..."
        # The initramfs must stay small enough for the ESP copy below.
        # --hostonly degrades to all-drivers+firmware (241M measured) when
        # chrooted under a foreign running kernel, so omit every dracut
        # module the NTFS-loop boot cannot need. ntfs3/loop/virtio ride in
        # via kernel-modules + the 99wootc-boot module.
        # --fwdir at an empty dir: the journal showed amdgpu/nvidia firmware
        # blobs dominating the 241M image; no firmware is needed to reach
        # the NTFS-loop root (virtio/ahci/nvme need none).
        mkdir -p "$DEPLOY_ROOT/run/wootc-nofw"
        # --no-hostonly (not --hostonly): under a foreign-kernel chroot with no
        # /run mounted, dracut force-disables host-only anyway ("Turning off
        # host-only mode: '/run' is not mounted!") and, worse, its host-only
        # path probing fails on '/root' (dracut-install ... -f /root → FAILED),
        # which was silently producing a Phase-2 initramfs WITHOUT the
        # 99wootc-boot module — so root.disk never attached and Phase-2 hung.
        # Explicitly --add wootc-boot so the loop-attach module can never be
        # dropped by omit/dependency heuristics (the guard below enforces it).
        # nvmf/systemd-cryptsetup are auto-pulled but depend on the network/dm
        # modules we omit; omit them too so they don't error the run.
        DRACUT_OMIT="plymouth lvm mdraid dm multipath iscsi nfs cifs fcoe fcoe-uefi resume rescue network network-legacy network-manager kernel-network-modules cellular qemu-net memstrack nvmf nvdimm"
        [[ "$LUKS_TYPE" == "none" ]] && DRACUT_OMIT="$DRACUT_OMIT crypt systemd-cryptsetup"
        # Capture dracut's real exit + tail its output to the serial. The
        # module + hook land cleanly in a bare `podman run <img> dracut …`, so
        # any failure here is specific to the chroot-into-mounted-deployment
        # context (e.g. an empty /var, /var/tmp, or /run) — surface it instead
        # of losing it to a redirected log.
        # Pull the userspace NTFS driver into the Phase-2 initramfs when the
        # deployment has it (EL kernels have no ntfs3, so the hook needs
        # ntfs-3g to mount the Windows volume). Only list what actually exists —
        # dracut --install hard-fails on a missing item. A regen-level --install
        # resolves these reliably where a module-level inst does not.
        NTFS_BINS=()
        for _b in ntfs-3g lowntfs-3g mount.ntfs mount.ntfs-3g; do
            for _d in /usr/bin /usr/sbin /bin /sbin; do
                if [[ -e "$DEPLOY_ROOT$_d/$_b" ]]; then NTFS_BINS+=("$_d/$_b"); break; fi
            done
        done
        DRACUT_INSTALL_ARGS=()
        if (( ${#NTFS_BINS[@]} > 0 )); then
            DRACUT_INSTALL_ARGS=(--install "${NTFS_BINS[*]}")
            log "  Including userspace NTFS driver in Phase-2 initramfs: ${NTFS_BINS[*]}"
        else
            log "  [WARN] no ntfs-3g in the deployment — Phase-2 relies on a kernel ntfs3"
        fi
        # BOUNDED. An unbounded chroot dracut is a prime suspect for the
        # 31-minute silent hang: it writes nothing to the journal, so a block
        # here looks exactly like a dead deployer. A regen legitimately takes a
        # few minutes; 15 is generous and still finite.
        log "  verify: regenerating Phase-2 initramfs (dracut, up to 15m)"
        set +e
        timeout 900 chroot "$DEPLOY_ROOT" dracut --force --no-hostonly \
            --add wootc-boot \
            "${DRACUT_INSTALL_ARGS[@]}" \
            --fwdir /run/wootc-nofw \
            --omit "$DRACUT_OMIT" \
            "$INITRD_CHROOT_PATH" "$KVER" 2>&1 | tail -25 >&2
        REGEN_RC=${PIPESTATUS[0]}
        set -e
        # A non-zero regen must ABORT here, not merely be logged as a "problem"
        # and continued past (PHASE2_PROBLEMS is only summarised, never fatal).
        # PROVEN on hosted run 29712429479: the module's wiring dfatal aborted
        # the regen (exit!=0), the deploy carried on regardless, and Phase 2
        # booted an initramfs WITHOUT the wootc-attach module — root.disk never
        # attached and sysroot.mount timed out. A failed regen means the Phase-2
        # initramfs is stale/hookless; booting it is the exact silent wedge we
        # keep turning into loud Phase-1 failures.
        if [[ "$REGEN_RC" -eq 124 ]]; then
            err "  [FAIL] dracut regen TIMED OUT after 15m — Phase-2 initramfs not rebuilt"
            err "         Without it the loop-attach hook is absent and Phase 2 cannot boot; aborting deploy."
            exit 1
        elif [[ "$REGEN_RC" -ne 0 ]]; then
            err "  [FAIL] dracut regen FAILED (exit=$REGEN_RC) — Phase-2 initramfs is stale/hookless; aborting deploy"
            err "         root.disk would never attach and sysroot.mount would time out into emergency."
            exit 1
        fi
        log "  dracut regen exit=$REGEN_RC"
        REGEN_SIZE=$(wc -c < "${OSTREE_INITRDS[0]}" 2>/dev/null || echo 0)
        log "  Regenerated initramfs size: $((REGEN_SIZE / 1024 / 1024))M"
    else
        # This branch runs when OSTREE_INITRDS is empty — which is exactly the
        # composefs-native + systemd-boot case (the kernel/initramfs are NOT
        # under /boot/ostree/*/, so the glob above finds nothing). It MUST still
        # inject the loop-attach module: a bare --regenerate-all rebuilds every
        # initramfs WITHOUT wootc-boot, producing a hookless Phase-2 initramfs —
        # proven on bonito run 29785623612, where Phase 2 found no
        # wootc-attach.service, fell back to /dev/gpt-auto-root, and emergency'd.
        # --add wootc-boot here is what wires the attach service into whatever
        # initramfs the composefs/systemd-boot path actually boots.
        log "  verify: regenerating ALL initramfses WITH wootc-boot (dracut, up to 15m)"
        if ! timeout 900 chroot "$DEPLOY_ROOT" dracut --force --regenerate-all --add wootc-boot; then
            err "  [FAIL] dracut --regenerate-all failed or timed out"
            exit 1
        fi
        log "  verify: regenerate-all complete"
    fi

    # GUARD: the Phase-2 initramfs is useless without the loop-attach hook —
    # without wootc-attach-loop.sh the NTFS-hosted root.disk is never attached,
    # root=UUID never appears, and Phase-2 hangs at boot. `dracut --omit`,
    # a foreign-kernel chroot, or a wrong KVER can all silently drop the module
    # (line 586 below only checks the module *dir* exists in the target, NOT
    # that it landed in the built image). Verify the actual output and abort the
    # deploy here — a loud [FAIL] beats a silent 5-minute boot wedge.
    if [[ -n "${INITRD_CHROOT_PATH:-}" ]] && chroot "$DEPLOY_ROOT" sh -c 'command -v lsinitrd >/dev/null 2>&1'; then
        # Diagnostic: how many entries did lsinitrd list, and did the hook match?
        # entries=0 means a decompression/false-negative (lsinitrd couldn't read
        # the image), not a genuinely hookless initramfs — different fixes.
        GUARD_ENTRIES=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null | wc -l)
        # Require the hook to be WIRED, not merely present.
        #
        # This used to grep for the filename anywhere in the archive, so it
        # passed identically whether the file was installed as a hook or had
        # merely been copied into modules.d and never wired. It reported
        # "matches=1" for an initramfs whose Phase-2 boot then produced not one
        # line of hook output. Same proxy-check failure as the rest of this
        # session: assert the property, not a correlate of it.
        # Verify the attach SERVICE is WIRED, not just present. The Phase-2
        # initramfs is systemd-based and never runs dracut-initqueue, so the
        # hook alone is dead — the unit must be wanted by
        # initrd-root-device.target or nothing attaches root.disk (proven: a
        # correctly-present hook produced zero output and sysroot.mount timed
        # out). Require the .wants symlink, which is what actually makes it run.
        GUARD_HITS=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null \
            | grep -cE 'initrd-root-device.target.wants/wootc-attach.service')
        log "  guard: lsinitrd listed $GUARD_ENTRIES entries, wootc-attach-loop matches=$GUARD_HITS"
        # The wants symlink alone is NOT enough: it can dangle. Proven the hard
        # way — the symlink was present but usr/lib/systemd/system/
        # wootc-attach.service was ABSENT (the deployer initramfs never staged
        # the unit file), so systemd had no unit to start and root.disk never
        # attached. Require the actual UNIT FILE too, matched at end-of-line so a
        # wants symlink of the same name does not satisfy it.
        GUARD_UNIT=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null \
            | grep -cE 'usr/lib/systemd/system/wootc-attach\.service$')
        log "  guard: wootc-attach.service unit file present=$GUARD_UNIT"
        if [[ "${GUARD_UNIT:-0}" -lt 1 ]]; then
            err "  [FAIL] Phase-2 initramfs has the wants symlink but NO wootc-attach.service unit file (dangling) — root.disk would never attach; aborting deploy"
            exit 1
        fi
        # With a raw root.disk the hook needs only losetup, which the target
        # image already provides — so there is no staged binary to verify. The
        # hook's own presence is now the whole requirement.
        GUARD_LOSETUP=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null | grep -c 'losetup')
        log "  guard: losetup present in initramfs=$GUARD_LOSETUP"
        if [[ "${GUARD_LOSETUP:-0}" -lt 1 ]]; then
            err "  [FAIL] Phase-2 initramfs has no losetup — root.disk cannot be attached"
            PHASE2_PROBLEMS+=("initramfs missing losetup")
        fi
        if [[ "${GUARD_HITS:-0}" -ge 1 ]]; then
            log "  [PASS] Phase-2 initramfs has wootc-attach.service WIRED into initrd-root-device.target"
        else
            err "  [FAIL] Phase-2 initramfs has no WIRED wootc-attach.service — root.disk would never attach; aborting deploy"
            exit 1
        fi
    else
        log "  [WARN] lsinitrd unavailable — cannot verify loop-attach hook in the Phase-2 initramfs"
    fi
    # One summary of everything that went wrong in this stretch, so a single run
    # yields the full picture instead of only its first fault.
    if (( ${#PHASE2_PROBLEMS[@]} > 0 )); then
        err "  [FAIL] Phase-2 setup completed with ${#PHASE2_PROBLEMS[@]} problem(s):"
        for p in "${PHASE2_PROBLEMS[@]}"; do err "         - $p"; done
        err "         Phase 2 will NOT boot correctly. Fix all of the above."
    else
        log "  [PASS] Phase-2 setup completed with no problems"
    fi

    for fs in sys proc dev; do umount "$DEPLOY_ROOT/$fs"; done

    # Check dracut module
    if [[ -d "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot" ]]; then
        log "  [PASS] dracut 99wootc-boot module installed"
    else
        err "  [FAIL] dracut 99wootc-boot module NOT found"
    fi

    vstage "before-userbridge (writes \$DEPLOY_ROOT/usr/local + /usr/share — read-only under composefs)"
    # ── [generic] User Data Bridge (native passthrough) ──────────────────
    # Distro-agnostic: installs units/scripts into the target root. Only
    # its *placement inside* the verification mount is provisioner-hosted.
    # fisherman does not install these — inject them the same way as the
    # 99wootc-boot dracut module, and enable them via local-fs.target.wants
    # symlinks (systemctl --root needs D-Bus/policy that isn't available
    # here; a plain symlink is exactly what `systemctl enable` would create
    # for a WantedBy=local-fs.target oneshot unit).
    install -m644 /usr/lib/wootc/migration/wootc-host-bind.service \
        "$DEPLOY_ROOT/etc/systemd/system/wootc-host-bind.service"
    install -m644 /usr/lib/wootc/migration/wootc-passthrough.service \
        "$DEPLOY_ROOT/etc/systemd/system/wootc-passthrough.service"
    # ENABLE them (the missing step): a WantedBy=local-fs.target unit only runs
    # if it is symlinked into local-fs.target.wants — installing the unit file
    # is not enough. Without this the User Data Bridge never activated at boot
    # (E2E: "wootc-passthrough service NOT detected").
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants"
    ln -sf ../wootc-host-bind.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-host-bind.service"
    ln -sf ../wootc-passthrough.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-passthrough.service"
    install -m755 /usr/lib/wootc/migration/wootc-mount-user-dirs \
        "$DEPLOY_ROOT/usr/local/bin/wootc-mount-user-dirs"
    install -m755 /usr/lib/wootc/migration/wootc-umount-user-dirs \
        "$DEPLOY_ROOT/usr/local/bin/wootc-umount-user-dirs"
    # Extra bridge categories (SPEC §4.1–4.2): Steam, browser import, and
    # the stage-4 folder conversion used by the migration dashboard.
    install -m755 /usr/lib/wootc/migration/wootc-steam-bridge \
        "$DEPLOY_ROOT/usr/local/bin/wootc-steam-bridge"
    install -m755 /usr/lib/wootc/migration/wootc-import-browser \
        "$DEPLOY_ROOT/usr/local/bin/wootc-import-browser"
    install -m755 /usr/lib/wootc/migration/wootc-convert-dir \
        "$DEPLOY_ROOT/usr/local/bin/wootc-convert-dir"
    install -D -m644 /usr/lib/wootc/migration/org.tunaos.wootc.policy \
        "$DEPLOY_ROOT/usr/share/polkit-1/actions/org.tunaos.wootc.policy"
    # Optional post-install utilities. These are not required for the deployer
    # to run, so a payload that a given initramfs did not carry must WARN, never
    # abort the whole deploy (set -e) — a missing GUI helper is not worth losing
    # a completed OS install over. mig_opt does that.
    mig_opt() { # <mode> <name> <dst>
        local src="/usr/lib/wootc/migration/$2"
        if [[ -f "$src" ]]; then install -D -m"$1" "$src" "$3"
        else log "  optional migration payload not in initramfs (skipped): $2"; fi
    }
    # Linux-side "Bring your Windows over" import tool (external disk / backup /
    # BitLocker) + its GUI launcher. Post-install utility — no autostart.
    mig_opt 755 wootc-import     "$DEPLOY_ROOT/usr/local/bin/wootc-import"
    mig_opt 755 wootc-import-gui "$DEPLOY_ROOT/usr/local/bin/wootc-import-gui"
    mig_opt 644 wootc-import.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-import.desktop"
    # Migration chooser (§4.6): discover everything migratable, default-on, opt-out.
    mig_opt 755 wootc-manifest "$DEPLOY_ROOT/usr/local/bin/wootc-manifest"
    mig_opt 755 wootc-manifest-gui "$DEPLOY_ROOT/usr/local/bin/wootc-manifest-gui"
    mig_opt 644 wootc-manifest.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-manifest.desktop"
    # Identity prefill/copy (§4.6): account name + picture (never the password).
    mig_opt 755 wootc-identity "$DEPLOY_ROOT/usr/local/bin/wootc-identity"
    # Account setup screen: pre-fills the identity, asks for the one thing that
    # cannot be migrated (the password). Never persists the secret.
    mig_opt 755 wootc-user-gui "$DEPLOY_ROOT/usr/local/bin/wootc-user-gui"
    mig_opt 644 wootc-user.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-user.desktop"
    # Gates the bridges on the migration chooser's opt-out selection.
    mig_opt 755 wootc-selection "$DEPLOY_ROOT/usr/local/bin/wootc-selection"
    # Phase 3 (§4.2 stage 5-6): "move to Linux only" planner. Analysis path is
    # live; the destructive repartition path is guarded off until rung-3 proof.
    mig_opt 755 wootc-go-native  "$DEPLOY_ROOT/usr/local/bin/wootc-go-native"
    mig_opt 755 wootc-go-native-gui "$DEPLOY_ROOT/usr/local/bin/wootc-go-native-gui"
    mig_opt 644 wootc-go-native.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-go-native.desktop"
    # WSL migration (§4.6): dotfiles + Brewfile from a WSL install.
    mig_opt 755 wootc-wsl-bridge "$DEPLOY_ROOT/usr/local/bin/wootc-wsl-bridge"
    # Wi-Fi migration (§4.6): the bridge needs python3 + nmcli, so it runs on
    # first boot (oneshot service), not in this minimal initramfs. Stage the
    # exported profiles into the deployment; the bridge imports then shreds them.
    mig_opt 755 wootc-wifi-bridge "$DEPLOY_ROOT/usr/local/bin/wootc-wifi-bridge"
    if [[ -d /mnt/ntfs/wootc/install/wifi && -f /usr/lib/wootc/migration/wootc-wifi-import.service ]]; then
        install -m644 /usr/lib/wootc/migration/wootc-wifi-import.service \
            "$DEPLOY_ROOT/etc/systemd/system/wootc-wifi-import.service"
        mkdir -p "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf ../wootc-wifi-import.service \
            "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-wifi-import.service"
        mkdir -p "$DEPLOY_ROOT/var/lib/wootc/wifi-import"
        cp /mnt/ntfs/wootc/install/wifi/*.xml \
            "$DEPLOY_ROOT/var/lib/wootc/wifi-import/" 2>/dev/null || true
        chmod 700 "$DEPLOY_ROOT/var/lib/wootc/wifi-import"
        chmod 600 "$DEPLOY_ROOT"/var/lib/wootc/wifi-import/*.xml 2>/dev/null || true
        log "  Staged Wi-Fi profiles for first-boot import"
    fi
    # ESP self-healing sync: keeps the Windows-ESP kernel pair current
    # after OS updates (variant-agnostic — BLS and classic layouts).
    install -m755 /usr/lib/wootc/migration/wootc-esp-sync \
        "$DEPLOY_ROOT/usr/local/bin/wootc-esp-sync"
    install -m644 /usr/lib/wootc/migration/wootc-esp-sync.service \
        "$DEPLOY_ROOT/etc/systemd/system/wootc-esp-sync.service"
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../wootc-esp-sync.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-esp-sync.service"
    install -m755 /usr/lib/wootc/migration/wootc-detect-apps \
        "$DEPLOY_ROOT/usr/local/bin/wootc-detect-apps"
    install -m755 /usr/lib/wootc/migration/wootc-office-bridge \
        "$DEPLOY_ROOT/usr/local/bin/wootc-office-bridge"
    # Windows-Style Mode: per-user look apply on first login.
    install -m755 /usr/lib/wootc/migration/wootc-apply-look \
        "$DEPLOY_ROOT/usr/local/bin/wootc-apply-look"
    install -D -m644 /usr/lib/wootc/migration/wootc-apply-look.desktop \
        "$DEPLOY_ROOT/etc/xdg/autostart/wootc-apply-look.desktop"
    # Slurped Windows look (wallpaper/theme/timezone), if the installer
    # collected it. Timezone applies system-wide right here.
    if [[ -d /mnt/ntfs/wootc/install/slurp ]]; then
        mkdir -p "$DEPLOY_ROOT/usr/share/wootc"
        cp -a /mnt/ntfs/wootc/install/slurp "$DEPLOY_ROOT/usr/share/wootc/slurp"
        SLURP_TZ=$(jq -r '.timezone // empty' /mnt/ntfs/wootc/install/slurp/slurp.json 2>/dev/null || true)
        if [[ -n "$SLURP_TZ" && -e "$DEPLOY_ROOT/usr/share/zoneinfo/$SLURP_TZ" ]]; then
            ln -sf "../usr/share/zoneinfo/$SLURP_TZ" "$DEPLOY_ROOT/etc/localtime"
            log "  Timezone set to $SLURP_TZ (from Windows)"
        fi
    fi
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants"
    ln -sf ../wootc-host-bind.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-host-bind.service"
    ln -sf ../wootc-passthrough.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-passthrough.service"

    if [[ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-host-bind.service" ]]; then
        log "  [PASS] wootc-host-bind.service installed"
    else
        err "  [FAIL] wootc-host-bind.service install failed"
    fi

    if [[ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-passthrough.service" ]]; then
        log "  [PASS] wootc-passthrough.service installed"
    else
        err "  [FAIL] wootc-passthrough.service install failed"
    fi

    if grep -q 'wootc.host_uuid=.*loop=/wootc/disks/root.disk' "$DEPLOY_ROOT"/boot/loader/entries/*.conf; then
        log "  [PASS] Phase 2 loop-root arguments in BLS entries"
    else
        err "  [FAIL] Phase 2 loop-root arguments missing from BLS entries"
        exit 1
    fi

    # ── [mixed] ESP kernel-sync for Phase-2 Secure Boot boot ─────────────
    # The *mechanics* (mount ESP, copy kernel pair, write grub.cfg) are
    # generic; the *sources* are provisioner-owned: ostree kernel globs,
    # BLS cmdline extraction, and the bootupd-shipped signed shim+grub.
    # A non-bootc provisioner would return these three via the contract in
    # docs/architecture-boundary.md and this block would keep its shape.
    #
    # The signed GRUB cannot read NTFS (unsigned ntfs.mod rejected under
    # Secure Boot), so the installed kernel and initramfs must live on the
    # FAT32 ESP. Copy them there and write a Phase-2 grub.cfg with the
    # loop-root cmdline from the patched BLS entries.
    vstage "before-esp-staging (reaching here means /usr writes all succeeded)"
    log "Syncing Phase-2 kernel to ESP..."

    # ESP is partition 1 of the disk containing the NTFS partition.
    # /dev/sda3 → /dev/sda1, /dev/nvme0n1p3 → /dev/nvme0n1p1
    ESP_DEV=$(printf '%s' "$NTFS_PART" | sed -E 's/(p?)[0-9]+$/\11/')
    log "  ESP_DEV=${ESP_DEV} (derived from NTFS_PART=${NTFS_PART})"
    if [[ ! -b "$ESP_DEV" ]]; then
        err "  [WARN] ESP device ${ESP_DEV} not found; Phase-2 boot will fail"
    else
        mkdir -p /mnt/esp
        if mount -t vfat "$ESP_DEV" /mnt/esp 2>/dev/null; then
            mkdir -p /mnt/esp/EFI/wootc
            # The deployer kernel+initramfs (~153M) are dead weight on the
            # ESP after deployment, and a 256M ESP cannot hold both them and
            # the Phase-2 pair (canonical copies remain in C:\wootc\install).
            # Also clear any partial Phase-2 files from earlier attempts.
            rm -f /mnt/esp/EFI/wootc/deployer-vmlinuz \
                  /mnt/esp/EFI/wootc/deployer-initramfs.img \
                  /mnt/esp/EFI/wootc/phase2-vmlinuz \
                  /mnt/esp/EFI/wootc/phase2-initramfs.img
            # ── composefs-native + systemd-boot: stage Phase 2 from the target's
            # OWN ESP UKI. `bootc install --composefs-backend --bootloader systemd`
            # puts the BLS entry at $DEPLOY_ROOT/boot/efi/loader/entries/ and the
            # kernel+initrd under $DEPLOY_ROOT/boot/efi/EFI/Linux/<hash>/ — NOT the
            # /boot/ostree/ layout the generic globs below assume (ground truth:
            # bonito `bootc install to-filesystem --composefs-backend` on himachal).
            # The initrd is a plain systemd initramfs already shipping
            # loop/ntfs3/losetup/udevadm, so wootc-boot is injected by APPENDING a
            # cpio (no dracut regen — the deploy dir /usr/lib/modules is empty, its
            # content lives in the .ostree.cfs). We bake root=/composefs= (from the
            # target BLS entry) + loop=/wootc.host_uuid into our OWN entry, so
            # Phase 2 mounts the composefs root once root.disk is attached instead
            # of falling back to /dev/gpt-auto-root (which emergency'd on run
            # 29785623612 — no wootc-attach ran, root never appeared).
            CFS_HANDLED=0
            if [[ "$COMPOSEFS" == 1 && "$BOOTLOADER" == systemd ]]; then
                TESP="$DEPLOY_ROOT/boot/efi"
                shopt -s nullglob
                cfs_entries=("$TESP"/loader/entries/*.conf)
                shopt -u nullglob
                if (( ${#cfs_entries[@]} == 0 )); then
                    err "  [FAIL] composefs: no BLS entry under $TESP/loader/entries — cannot stage Phase 2"
                    exit 1
                fi
                cfs_linux=$(grep -m1 '^linux '  "${cfs_entries[0]}" | awk '{print $2}')
                cfs_initrd=$(grep -m1 '^initrd ' "${cfs_entries[0]}" | awk '{print $2}')
                cfs_opts=$(grep -m1 '^options ' "${cfs_entries[0]}" | sed 's/^options *//')
                KSRC="$TESP$cfs_linux"; ISRC="$TESP$cfs_initrd"
                if [[ ! -s "$KSRC" || ! -s "$ISRC" ]]; then
                    err "  [FAIL] composefs UKI kernel/initrd missing ($KSRC / $ISRC)"
                    exit 1
                fi
                log "  composefs: Phase-2 kernel=$cfs_linux initrd=$cfs_initrd"
                cp "$KSRC" /mnt/esp/EFI/wootc/phase2-vmlinuz
                # Inject wootc-boot: unit + wants symlink + loop script. PREPEND an
                # uncompressed cpio ahead of the (compressed) base initrd — the
                # kernel's early-cpio mechanism unpacks the leading 4-byte-padded
                # cpio, then the compressed main archive. Prepend (not append)
                # sidesteps any end-of-compressed-stream alignment ambiguity; our
                # three paths are unique to the base image's initramfs, so nothing
                # is overwritten. The base already ships loop/ntfs3/losetup/udevadm
                # (verified on bonito), so no modules or binaries need adding.
                OVL=$(mktemp -d)
                # early_cpio marker: makes lsinitrd/skipcpio recognise this as a
                # leading (early) cpio and skip past it to show the base initrd —
                # honest introspection. Harmless to the kernel (same as microcode).
                : > "$OVL/early_cpio"
                install -D -m0644 /usr/lib/wootc/99wootc-boot/wootc-attach.service \
                    "$OVL/usr/lib/systemd/system/wootc-attach.service"
                install -D -m0755 /usr/lib/wootc/99wootc-boot/wootc-attach-loop.sh \
                    "$OVL/usr/lib/wootc/wootc-attach-loop.sh"
                mkdir -p "$OVL/usr/lib/systemd/system/initrd-root-device.target.wants"
                ln -sf ../wootc-attach.service \
                    "$OVL/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"
                CPIO_OK=0
                if ( cd "$OVL" && find . | cpio -o -H newc --quiet ) > "$OVL.cpio" && \
                   cat "$OVL.cpio" "$ISRC" > /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                    CPIO_OK=1
                fi
                rm -f "$OVL.cpio"; rm -rf "$OVL"
                if [[ "$CPIO_OK" == 1 && -s /mnt/esp/EFI/wootc/phase2-initramfs.img ]]; then
                    log "  [PASS] composefs Phase-2 initrd patched with wootc-boot (prepend-cpio)"
                else
                    err "  [FAIL] composefs: cpio prepend failed — Phase-2 initrd would be hookless"
                    exit 1
                fi
                # Keep root=UUID + composefs=<hash>; drop unresolved \$vars + quiet.
                cfs_opts=$(printf '%s' "$cfs_opts" | tr ' ' '\n' | grep -v '\$' | grep -vE '^(quiet|rhgb)$' | tr '\n' ' ')
                mkdir -p /mnt/esp/loader/entries
                cat > /mnt/esp/loader/entries/wootc.conf <<BLSEOF
title wootc Linux
linux /EFI/wootc/phase2-vmlinuz
initrd /EFI/wootc/phase2-initramfs.img
options ${cfs_opts} loop=/wootc/disks/root.disk wootc.host_uuid=${HOST_UUID} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${PHASE2_KARGS}
BLSEOF
                rm -f /mnt/esp/loader/entries/wootc-deployer.conf
                ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
                if [[ -n "$ESP_UUID" ]]; then
                    mkdir -p "$DEPLOY_ROOT/etc/wootc"
                    printf 'HOST_ESP_UUID=%s\nBOOTLOADER=systemd\n' "$ESP_UUID" > "$DEPLOY_ROOT/etc/wootc/host-esp.conf"
                fi
                log "  [PASS] Phase-2 composefs/systemd-boot entry written (root+composefs+loop kargs)"
                CFS_HANDLED=1
            fi

            # Generic (ostree/BLS on /boot) path — skipped when the composefs
            # branch above already staged Phase 2.
            if [[ "$CFS_HANDLED" != 1 ]]; then
            shopt -s nullglob
            kernels=("$DEPLOY_ROOT"/boot/ostree/*/vmlinuz* "$DEPLOY_ROOT"/boot/vmlinuz-*)
            initrds=("$DEPLOY_ROOT"/boot/ostree/*/initramfs*.img "$DEPLOY_ROOT"/boot/initramfs-*.img)
            shopt -u nullglob
            KERNEL_SRC="${kernels[0]:-}"
            INITRD_SRC="${initrds[0]:-}"

            if [[ "$BOOTLOADER" == systemd ]]; then
                if [[ -n "$KERNEL_SRC" && -s "$KERNEL_SRC" && -n "$INITRD_SRC" && -s "$INITRD_SRC" ]] && \
                   cp "$KERNEL_SRC" /mnt/esp/EFI/wootc/phase2-vmlinuz && \
                   cp "$INITRD_SRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                    ROOT_OPTIONS=$(grep '^options ' "$DEPLOY_ROOT"/boot/loader/entries/*.conf 2>/dev/null | head -1 | sed 's/^options *//')
                    ROOT_OPTIONS=$(printf '%s' "$ROOT_OPTIONS" | tr ' ' '\n' | grep -v '\$' | grep -v -E '^(quiet|rhgb)$' | tr '\n' ' ')
                    mkdir -p /mnt/esp/loader/entries
                    cat > /mnt/esp/loader/entries/wootc.conf <<BLSEOF
title wootc Linux
linux /EFI/wootc/phase2-vmlinuz
initrd /EFI/wootc/phase2-initramfs.img
options ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200 ${PHASE2_KARGS}
BLSEOF
                    rm -f /mnt/esp/loader/entries/wootc-deployer.conf
                    log "  [PASS] Phase-2 systemd-boot entry written"
                else
                    err "  [FAIL] Phase-2 systemd-boot ESP sync failed"
                    exit 1
                fi
                ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
                if [[ -n "$ESP_UUID" ]]; then
                    mkdir -p "$DEPLOY_ROOT/etc/wootc"
                    printf 'HOST_ESP_UUID=%s\nBOOTLOADER=systemd\n' "$ESP_UUID" > "$DEPLOY_ROOT/etc/wootc/host-esp.conf"
                fi
            else

            # ── Target-signed Secure Boot chain ───────────────────────────
            # GRUB's shim_lock verifier rejects the target kernel unless the
            # shim's vendor cert trusts the kernel's signing key. The Fedora
            # deployer shim trusts only Fedora; the target kernel is signed by
            # its own distro (e.g. AlmaLinux/Red Hat). So swap the ESP chain
            # to the TARGET's own shim+grub (shipped signed inside the image
            # under bootupd) for the Phase-2 boot. All shims are MS-signed, so
            # UEFI still accepts the swapped shim at the BCD-referenced path.
            TARGET_SHIM=""
            TARGET_GRUB=""
            TARGET_VENDOR=""
            shopt -s nullglob
            for sd in "$DEPLOY_ROOT"/usr/lib/bootupd/updates/EFI/*/ \
                      "$DEPLOY_ROOT"/usr/lib/ostree-boot/efi/EFI/*/ ; do
                if [[ -f "${sd}shimx64.efi" && -f "${sd}grubx64.efi" ]]; then
                    TARGET_SHIM="${sd}shimx64.efi"
                    TARGET_GRUB="${sd}grubx64.efi"
                    TARGET_VENDOR=$(basename "$sd")
                    break
                fi
            done
            # bootupd's current Fedora layout separates versioned shim and
            # GRUB payloads. Match them by EFI vendor directory so we still
            # install a coherent, target-signed pair.
            if [[ -z "$TARGET_GRUB" ]]; then
                for grub in "$DEPLOY_ROOT"/usr/lib/efi/grub2/*/EFI/*/grubx64.efi; do
                    [[ -f "$grub" ]] || continue
                    vendor_dir=$(basename "$(dirname "$grub")")
                    for shim in "$DEPLOY_ROOT"/usr/lib/efi/shim/*/EFI/"$vendor_dir"/shimx64.efi; do
                        [[ -f "$shim" ]] || continue
                        TARGET_GRUB="$grub"
                        TARGET_SHIM="$shim"
                        TARGET_VENDOR="$vendor_dir"
                        break 2
                    done
                done
            fi
            shopt -u nullglob

            if [[ -n "$KERNEL_SRC" && -s "$KERNEL_SRC" ]] && \
               [[ -n "$INITRD_SRC" && -s "$INITRD_SRC" ]] && \
               [[ -n "$TARGET_SHIM" && -n "$TARGET_GRUB" ]] && \
               cp "$KERNEL_SRC" /mnt/esp/EFI/wootc/phase2-vmlinuz && \
               cp "$INITRD_SRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                log "  Copied kernel and initramfs to ESP:EFI/wootc/"

                # BCD loads \EFI\fedora\shimx64.efi; the target shim then loads
                # grubx64.efi from that same dir. Overwrite both with the
                # target-signed pair (deployment is done — this ESP now boots
                # Phase-2, not the deployer).
                cp "$TARGET_SHIM" /mnt/esp/EFI/fedora/shimx64.efi
                cp "$TARGET_GRUB" /mnt/esp/EFI/fedora/grubx64.efi
                TARGET_MM="$DEPLOY_ROOT/usr/lib/bootupd/updates/EFI/$TARGET_VENDOR/mmx64.efi"
                if [[ ! -f "$TARGET_MM" ]]; then
                    for mm in "$DEPLOY_ROOT"/usr/lib/efi/shim/*/EFI/"$TARGET_VENDOR"/mmx64.efi; do
                        [[ -f "$mm" ]] && TARGET_MM="$mm" && break
                    done
                fi
                [[ -f "$TARGET_MM" ]] && cp "$TARGET_MM" /mnt/esp/EFI/fedora/mmx64.efi || true
                log "  Installed target-signed shim+grub (vendor: $TARGET_VENDOR)"

                # Kernel cmdline from the patched BLS entry (keeps root=UUID
                # and ostree=; the loop-attach hook makes that UUID appear).
                ROOT_OPTIONS=$(grep '^options ' "$DEPLOY_ROOT"/boot/loader/entries/*.conf 2>/dev/null | head -1 | sed 's/^options *//')
                # BLS $kernelopts-style variables never resolve in our
                # grub.cfg; drop tokens containing '$'. Also drop quiet/rhgb —
                # a silent early-boot panic (all 4 vCPUs parked in
                # stop_this_cpu() at an identical RIP, confirmed via QEMU
                # monitor `info registers` across CPUs) showed zero output on
                # serial OR framebuffer, meaning the panic happens before any
                # console driver registers. earlycon+ignore_loglevel force the
                # UART console up immediately so the actual panic prints.
                ROOT_OPTIONS=$(printf '%s' "$ROOT_OPTIONS" | tr ' ' '\n' | grep -v '\$' | grep -v -E '^(quiet|rhgb)$' | tr '\n' ' ')

                # Write the Phase-2 menu to EVERY grub.cfg location the loaded
                # grub could read. BCD chains \EFI\fedora\shimx64.efi, which
                # loads \EFI\fedora\grubx64.efi (now the target-signed grub).
                # That grub's embedded prefix has been observed to resolve to
                # its own dir (/EFI/fedora) rather than /EFI/<vendor>, so a menu
                # written only to /EFI/<vendor>/grub.cfg is never read and the
                # STALE installer menu at /EFI/fedora (or /EFI/wootc) — which
                # points at the now-deleted deployer-vmlinuz — wins, bricking the
                # boot. Overwriting all three paths makes the handoff prefix-
                # independent and removes the stale deployer menu.
                PHASE2_GRUB_CFG=$(cat <<GRUBEOF
# wootc Phase 2 — boot installed system from root.disk
set default=0
set timeout=5

menuentry "wootc Linux" {
    linux /EFI/wootc/phase2-vmlinuz ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${PHASE2_KARGS}
    initrd /EFI/wootc/phase2-initramfs.img
}
GRUBEOF
)
                for gd in "$TARGET_VENDOR" fedora wootc; do
                    mkdir -p "/mnt/esp/EFI/$gd"
                    printf '%s\n' "$PHASE2_GRUB_CFG" > "/mnt/esp/EFI/$gd/grub.cfg"
                done
                log "  [PASS] Phase-2 grub.cfg written to EFI/{$TARGET_VENDOR,fedora,wootc}/grub.cfg"

                # Record the Windows ESP identity so wootc-esp-sync can
                # refresh this pair after OS updates inside the target.
                ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
                if [[ -n "$ESP_UUID" ]]; then
                    mkdir -p "$DEPLOY_ROOT/etc/wootc"
                    printf 'HOST_ESP_UUID=%s\n' "$ESP_UUID" \
                        > "$DEPLOY_ROOT/etc/wootc/host-esp.conf"
                    log "  [PASS] host-esp.conf written (UUID $ESP_UUID)"
                fi
            else
                # Never leave the ESP kernel-less: the deployer pair was
                # removed above to make room, so restore it from the
                # canonical NTFS copies before failing.
                err "  [FAIL] Phase-2 ESP sync failed (missing or unwritable kernel/initramfs)"
                rm -f /mnt/esp/EFI/wootc/phase2-vmlinuz /mnt/esp/EFI/wootc/phase2-initramfs.img
                cp /mnt/ntfs/wootc/install/deployer-vmlinuz /mnt/esp/EFI/wootc/deployer-vmlinuz 2>/dev/null || true
                cp /mnt/ntfs/wootc/install/deployer-initramfs.img /mnt/esp/EFI/wootc/deployer-initramfs.img 2>/dev/null || true
            fi
            fi
            fi   # close CFS_HANDLED guard (generic ostree/BLS staging path)
            umount /mnt/esp
        else
            err "  [WARN] Could not mount ESP ${ESP_DEV}; Phase-2 boot will fail"
        fi
    fi

    vstage "verify-complete (all stages passed; Phase-2 ESP is staged)"
    umount "$DEPLOY_ROOT/boot"
    umount /mnt/verify
else
    err "  [WARN] Could not mount installed root for verification (checking via loop file only)"
fi

if [[ -n "$VERIFY_CRYPT" ]]; then
    cryptsetup close "$VERIFY_CRYPT"
    VERIFY_CRYPT=""
fi
losetup -d "$VERIFY_LOOP"
VERIFY_LOOP=""

# ╔═══════════════════════════════════════════════════════════════════════════
# ║ PROVISIONER: bootc/fisherman — ENDS here. Generic teardown follows.
# ╚═══════════════════════════════════════════════════════════════════════════

# Tear down the scratch store and leave the NTFS volume clean before the
# forced reboot (reboot -f syncs but does not unmount; a still-mounted rw
# NTFS would be flagged dirty and block the Phase 2 rw mount).
umount /var/tmp 2>/dev/null || true
umount /var/lib/containers 2>/dev/null || true
umount /var/fisherman-tmp 2>/dev/null || true
[[ -n "$SCRATCH_LOOP" ]] && losetup -d "$SCRATCH_LOOP" 2>/dev/null || true
SCRATCH_LOOP=""
rm -f "$SCRATCH_IMG"

# Robustly unmount the host NTFS. The composefs verify path can fail to mount the
# installed root ("checking via loop file only") and leave a loop device or
# overlay pinning a file under /mnt/ntfs — then a plain `umount /mnt/ntfs` blocks
# "target is busy" forever and the whole deploy times out without ever rebooting
# into Phase 2. So: sync, detach any loop still backed by a /mnt/ntfs file,
# unmount anything nested, then a BOUNDED umount with a lazy fallback. (The sync
# means a lazy detach is acceptable rather than hanging the deploy; we still try
# a clean umount first to avoid a dirty-NTFS flag.)
sync || true
for _lp in $(losetup -ln -O NAME,BACK-FILE 2>/dev/null | awk '$2 ~ /\/mnt\/ntfs\// {print $1}'); do
    losetup -d "$_lp" 2>/dev/null || true
done
awk '$2 ~ /^\/mnt\/ntfs\// {print $2}' /proc/mounts 2>/dev/null | sort -r | while read -r _m; do
    umount "$_m" 2>/dev/null || umount -l "$_m" 2>/dev/null || true
done
_ntfs_umounted=false
for _ in 1 2 3 4 5; do umount /mnt/ntfs 2>/dev/null && { _ntfs_umounted=true; break; }; sync; sleep 2; done
if [ "$_ntfs_umounted" != true ]; then
    err "  [WARN] /mnt/ntfs still busy after retries; lazy-detaching so the deploy can reboot into Phase 2"
    umount -l /mnt/ntfs 2>/dev/null || true
fi

phase "reboot"
log "Verification complete. Rebooting..."
log "  [wootc] VERIFICATION_SUMMARY: deployer ready for migration phase"
sleep 3
sync || true
# reboot -f is systemctl reboot -f and hangs under emergency mode; use the
# direct syscall (everything is unmounted by this point).
reboot -ff || reboot -f
