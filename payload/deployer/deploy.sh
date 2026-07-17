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
log() {
    printf '\033[1;32m[wootc]\033[0m %s\n' "$*"
    printf '[wootc] %s\n' "$*" > /dev/kmsg 2>/dev/null || true
    [ -z "$PERSIST_LOG" ] || printf '%s [wootc] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$PERSIST_LOG" 2>/dev/null || true
}
err() {
    printf '\033[1;31m[wootc]\033[0m %s\n' "$*" >&2
    printf '[wootc] ERROR: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
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
    install -m755 "$(command -v qemu-nbd)" \
        "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/qemu-nbd"

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
        DRACUT_OMIT="plymouth lvm mdraid dm multipath iscsi nfs cifs fcoe fcoe-uefi resume rescue network network-legacy network-manager kernel-network-modules cellular qemu-net memstrack"
        [[ "$LUKS_TYPE" == "none" ]] && DRACUT_OMIT="$DRACUT_OMIT crypt"
        chroot "$DEPLOY_ROOT" dracut --force --hostonly \
            --fwdir /run/wootc-nofw \
            --omit "$DRACUT_OMIT" \
            "$INITRD_CHROOT_PATH" "$KVER"
        REGEN_SIZE=$(wc -c < "${OSTREE_INITRDS[0]}")
        log "  Regenerated initramfs size: $((REGEN_SIZE / 1024 / 1024))M"
    else
        chroot "$DEPLOY_ROOT" dracut --force --regenerate-all
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
    # Linux-side "Bring your Windows over" import tool (external disk / backup /
    # BitLocker) + its GUI launcher. Post-install utility — no autostart.
    install -m755 /usr/lib/wootc/migration/wootc-import \
        "$DEPLOY_ROOT/usr/local/bin/wootc-import"
    install -m755 /usr/lib/wootc/migration/wootc-import-gui \
        "$DEPLOY_ROOT/usr/local/bin/wootc-import-gui"
    install -D -m644 /usr/lib/wootc/migration/wootc-import.desktop \
        "$DEPLOY_ROOT/usr/share/applications/wootc-import.desktop"
    # Phase 3 (§4.2 stage 5-6): "move to Linux only" planner. Analysis path is
    # live; the destructive repartition path is guarded off until rung-3 proof.
    install -m755 /usr/lib/wootc/migration/wootc-go-native \
        "$DEPLOY_ROOT/usr/local/bin/wootc-go-native"
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
options ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200 ${SSHD_KARG}
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

                # The target grub's embedded prefix is /EFI/<vendor>; it reads
                # $prefix/grub.cfg. Write the Phase-2 menu there.
                mkdir -p "/mnt/esp/EFI/$TARGET_VENDOR"
                cat > "/mnt/esp/EFI/$TARGET_VENDOR/grub.cfg" <<GRUBEOF
# wootc Phase 2 — boot installed system from root.vhdx
set default=0
set timeout=5

menuentry "wootc Linux" {
    linux /EFI/wootc/phase2-vmlinuz ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${SSHD_KARG}
    initrd /EFI/wootc/phase2-initramfs.img
}
GRUBEOF
                log "  [PASS] Phase-2 grub.cfg written to EFI/$TARGET_VENDOR/grub.cfg"

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
