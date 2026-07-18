#!/usr/bin/env bash
# wootc-deploy — runs inside the deployer initramfs.
#
# Finds root.vhdx on the NTFS partition, attaches it through NBD,
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
log() {
    printf '\033[1;32m[wootc]\033[0m %s\n' "$*"
    printf '<27>[wootc] %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    printf '[wootc] %s\n' "$*" > /dev/console 2>/dev/null || true
    [ -z "$PERSIST_LOG" ] || printf '%s [wootc] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$PERSIST_LOG" 2>/dev/null || true
}
err() {
    printf '\033[1;31m[wootc]\033[0m %s\n' "$*" >&2
    printf '<27>[wootc] ERROR: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    printf '[wootc] ERROR: %s\n' "$*" > /dev/console 2>/dev/null || true
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
    [[ -n "$VERIFY_LOOP" ]] && qemu-nbd --disconnect "$VERIFY_LOOP" 2>/dev/null || true
    [[ -n "$SCRATCH_LOOP" ]] && losetup -d "$SCRATCH_LOOP" 2>/dev/null || true
    [[ -n "$LOOP_DEV" ]] && qemu-nbd --disconnect "$LOOP_DEV" 2>/dev/null || true
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
BOOTLOADER="$(read_cmdline wootc.bootloader grub2)"
COMPOSEFS="$(read_cmdline wootc.composefs 0)"

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

case "$BOOTLOADER" in grub2|systemd) ;; *) err "unsupported bootloader: $BOOTLOADER"; exit 1 ;; esac
case "$COMPOSEFS" in 0|1) ;; *) err "unsupported composefs value: $COMPOSEFS"; exit 1 ;; esac

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

ROOT_DISK_PATH="/wootc/disks/root.vhdx"

# ── Find NTFS partition containing root.vhdx ────────────────────────────────
log "Searching for ${ROOT_DISK_PATH}..."

# The initqueue/online hook fires when the network is up, which can beat SCSI
# disk enumeration by seconds. Retry the scan until the disk appears instead
# of failing on the first pass.
modprobe ntfs3 2>/dev/null || true
modprobe virtio_scsi 2>/dev/null || true

scan_for_root_disk() {
    local dev
    for dev in /dev/sd* /dev/nvme* /dev/vd*; do
        [[ -b "$dev" ]] || continue
        mkdir -p /mnt/scan
        if mount -t ntfs3 -o ro "$dev" /mnt/scan 2>/dev/null; then
            if [[ -f "/mnt/scan${ROOT_DISK_PATH}" ]]; then
                NTFS_PART="$dev"
                umount /mnt/scan
                return 0
            fi
            umount /mnt/scan
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
    log "root.vhdx not found (attempt ${attempt}/24); retrying in 5s..."
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
DISK="/mnt/ntfs/wootc/disks/root.vhdx"

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
PHASE2_KARGS="$MGMT_KARG $SSHD_KARG $TIMEOUT_KARG"

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
# must fit in C:'s free space alongside the dynamically allocated root.vhdx.
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

# ── Attach dynamic VHDX through qemu-nbd ───────────────────────────────────
# VHDX has an internal metadata log and is natively mountable by Windows. It
# is not a byte-addressable raw image, so losetup must never be used here.
VHDX_FORMAT=$(qemu-img info --output=json "$DISK" | jq -r '.format // empty')
if [[ "$VHDX_FORMAT" != "vhdx" ]]; then
    err "root.vhdx format check failed (detected: ${VHDX_FORMAT:-unknown})"
    exit 1
fi
modprobe nbd nbds_max=4 max_part=16
LOOP_DEV=/dev/nbd0
qemu-nbd --connect "$LOOP_DEV" --format=vhdx --discard=unmap "$DISK"
udevadm settle --timeout=10 2>/dev/null || true
log "Attached dynamic VHDX ${DISK} as ${LOOP_DEV}"

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
    if ! podman run --name "$cname" "$IMAGE" sh -c \
        'dnf install -y ntfs-3g || microdnf install -y ntfs-3g || rpm-ostree install ntfs-3g'; then
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

qemu-nbd --disconnect "$LOOP_DEV"
LOOP_DEV=""

# ── Post-deployment verification ─────────────────────────────────────────────
# Verify the installed system's passthrough and migration setup before rebooting.
# These markers are captured by the e2e test's serial console monitor.

phase "verification"
log "Verifying installed system setup..."

# Re-mount the installed disk while its NTFS backing mount is still live.
# Do not reuse nbd0 here: qemu-nbd disconnect is asynchronous and the old
# partition nodes can briefly remain after Fisherman exits.  A separate NBD
# device makes verification independent of that teardown race.
VERIFY_LOOP=/dev/nbd1
qemu-nbd --connect "$VERIFY_LOOP" --format=vhdx --discard=unmap "$DISK"

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
    install -d "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot"
    cp -a /usr/lib/wootc/99wootc-boot/. \
        "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/"

    # ── qemu-nbd must be SELF-CONTAINED, not a bare binary ──────────────────
    # We ship the deployer's own qemu-nbd because target bootc images generally
    # do not have one (verified: ghcr.io/tuna-os/yellowfin:gnome has no
    # qemu-nbd). But copying just the executable does not work: it is a
    # dynamically-linked Fedora build, and the Phase-2 initramfs is assembled
    # from the TARGET image's libraries. Measured against yellowfin, the
    # deployer's qemu-nbd needs libfuse3.so.4 while the target ships
    # libfuse3.so.3 — a soname major bump. The binary lands in the initramfs,
    # then dies at runtime with:
    #     error while loading shared libraries: libfuse3.so.4
    # The attach fails, the root UUID never appears, and Phase 2 drops to an
    # emergency shell — silently, because the failure is at the last step.
    #
    # Do NOT "fix" this by symlinking .so.4 onto .so.3: a soname major bump is
    # an ABI break, and mismatched ABI on the driver that writes the loop-backed
    # root filesystem risks data corruption, not merely a crash.
    #
    # Do NOT match the deployer base to the target image either: wootc supports
    # arbitrary bootc images, so the target's distro and library versions are
    # not knowable in advance.
    #
    # Instead ship the full closure — binary + every NEEDED library + Fedora's
    # own ld.so — and invoke through that loader with an explicit --library-path.
    # The result carries its entire runtime and never resolves against the
    # target's libraries, so it works on any image. Verified: the closure runs
    # inside yellowfin and reports qemu-nbd 10.2.2 (fc44).
    NBD_SRC="$(command -v qemu-nbd)"
    if [[ -z "$NBD_SRC" ]]; then
        err "  [FAIL] deployer has no qemu-nbd to stage; Phase 2 could not attach the VHDX"
        exit 1
    fi
    NBD_DIR="$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/nbd-closure"
    install -d "$NBD_DIR"
    install -m755 "$NBD_SRC" "$NBD_DIR/qemu-nbd"
    # Every NEEDED library, dereferenced (ldd prints the resolved real paths).
    while read -r lib; do
        [[ -e "$lib" ]] && install -m755 "$lib" "$NBD_DIR/" 2>/dev/null || true
    done < <(ldd "$NBD_SRC" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*')
    # The loader itself — ldd lists it without a "=>" so the grep above catches
    # it, but copy explicitly in case the format differs.
    NBD_LOADER=$(ldd "$NBD_SRC" 2>/dev/null | grep -oE '/[^ ]*ld-linux[^ ]*\.so\.[0-9]+' | head -1)
    [[ -n "$NBD_LOADER" && -e "$NBD_LOADER" ]] && install -m755 "$NBD_LOADER" "$NBD_DIR/"
    NBD_LOADER_NAME=$(basename "${NBD_LOADER:-ld-linux-x86-64.so.2}")

    # Prove the closure is complete BEFORE it is baked into an initramfs that
    # only runs at Phase-2 boot. A missing library here is a silent emergency
    # shell an hour later.
    if ! "$NBD_DIR/$NBD_LOADER_NAME" --library-path "$NBD_DIR" \
            "$NBD_DIR/qemu-nbd" --version >/dev/null 2>&1; then
        err "  [FAIL] staged qemu-nbd closure is incomplete — it cannot execute:"
        "$NBD_DIR/$NBD_LOADER_NAME" --library-path "$NBD_DIR" \
            "$NBD_DIR/qemu-nbd" --version 2>&1 | head -3 >&2 || true
        exit 1
    fi
    log "  [PASS] qemu-nbd closure staged and verified ($(ls "$NBD_DIR" | wc -l) files)"

    # Wrapper placed at /usr/bin/qemu-nbd inside the initramfs so the hook can
    # keep calling `qemu-nbd` with no knowledge of any of this.
    cat > "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/qemu-nbd" <<WRAP
#!/bin/sh
# Self-contained qemu-nbd: runs against its own bundled libraries, never the
# target image's. See deploy.sh for why a bare binary does not work here.
exec /usr/lib/wootc-nbd/$NBD_LOADER_NAME --library-path /usr/lib/wootc-nbd \\
     /usr/lib/wootc-nbd/qemu-nbd "\$@"
WRAP
    chmod 755 "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/qemu-nbd"

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
            sed -i '/^options / s|$| wootc.host_uuid='"$HOST_UUID"' loop=/wootc/disks/root.vhdx|' "$entry"
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
        set +e
        chroot "$DEPLOY_ROOT" dracut --force --no-hostonly \
            --add wootc-boot \
            "${DRACUT_INSTALL_ARGS[@]}" \
            --fwdir /run/wootc-nofw \
            --omit "$DRACUT_OMIT" \
            "$INITRD_CHROOT_PATH" "$KVER" 2>&1 | tail -25 >&2
        REGEN_RC=${PIPESTATUS[0]}
        set -e
        log "  dracut regen exit=$REGEN_RC"
        REGEN_SIZE=$(wc -c < "${OSTREE_INITRDS[0]}" 2>/dev/null || echo 0)
        log "  Regenerated initramfs size: $((REGEN_SIZE / 1024 / 1024))M"
    else
        chroot "$DEPLOY_ROOT" dracut --force --regenerate-all
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
        GUARD_HITS=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null | grep -c 'wootc-attach-loop')
        log "  guard: lsinitrd listed $GUARD_ENTRIES entries, wootc-attach-loop matches=$GUARD_HITS"
        # The hook alone is not enough: it calls qemu-nbd, and a hook present
        # without a working qemu-nbd closure fails at the last step before the
        # root device would appear — the exact silent emergency-shell failure
        # this guard exists to prevent. Check the closure landed too.
        GUARD_NBD=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null | grep -c 'wootc-nbd/')
        log "  guard: wootc-nbd closure files in initramfs=$GUARD_NBD"
        if [[ "${GUARD_HITS:-0}" -ge 1 ]] && [[ "${GUARD_NBD:-0}" -lt 2 ]]; then
            err "  [FAIL] Phase-2 initramfs has the hook but NOT the qemu-nbd closure"
            err "         The hook would run, call qemu-nbd, and fail to attach the VHDX."
            exit 1
        fi
        if [[ "${GUARD_HITS:-0}" -ge 1 ]]; then
            log "  [PASS] Phase-2 initramfs carries the loop-attach hook + qemu-nbd closure"
        else
            err "  [FAIL] Phase-2 initramfs is MISSING wootc-attach-loop.sh — root.disk would never attach; aborting deploy"
            exit 1
        fi
    else
        log "  [WARN] lsinitrd unavailable — cannot verify loop-attach hook in the Phase-2 initramfs"
    fi
    for fs in sys proc dev; do umount "$DEPLOY_ROOT/$fs"; done

    # Check dracut module
    if [[ -d "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot" ]]; then
        log "  [PASS] dracut 99wootc-boot module installed"
    else
        err "  [FAIL] dracut 99wootc-boot module NOT found"
    fi

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

    if grep -q 'wootc.host_uuid=.*loop=/wootc/disks/root.vhdx' "$DEPLOY_ROOT"/boot/loader/entries/*.conf; then
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
                cp "$DEPLOY_ROOT/usr/lib/bootupd/updates/EFI/$TARGET_VENDOR/mmx64.efi" \
                   /mnt/esp/EFI/fedora/mmx64.efi 2>/dev/null || true
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
# wootc Phase 2 — boot installed system from root.vhdx
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
            umount /mnt/esp
        else
            err "  [WARN] Could not mount ESP ${ESP_DEV}; Phase-2 boot will fail"
        fi
    fi

    umount "$DEPLOY_ROOT/boot"
    umount /mnt/verify
else
    err "  [WARN] Could not mount installed root for verification (checking via loop file only)"
fi

if [[ -n "$VERIFY_CRYPT" ]]; then
    cryptsetup close "$VERIFY_CRYPT"
    VERIFY_CRYPT=""
fi
qemu-nbd --disconnect "$VERIFY_LOOP"
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
umount /mnt/ntfs

phase "reboot"
log "Verification complete. Rebooting..."
log "  [wootc] VERIFICATION_SUMMARY: deployer ready for migration phase"
sleep 3
sync || true
# reboot -f is systemctl reboot -f and hangs under emergency mode; use the
# direct syscall (everything is unmounted by this point).
reboot -ff || reboot -f
