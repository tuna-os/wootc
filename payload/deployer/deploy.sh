#!/usr/bin/env bash
# wootc-deploy — runs inside the deployer initramfs.
#
# Finds root.disk on the NTFS partition, sets up a loop device,
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
#   wootc.debug                                      (optional, drops to shell)

set -Eeuo pipefail

# Write through /dev/kmsg when available: stdout of a sourced initqueue hook
# lands in the journal but is not reliably forwarded to the serial console,
# which made several failures invisible to the E2E monitor.
log() {
    printf '\033[1;32m[wootc]\033[0m %s\n' "$*"
    printf '[wootc] %s\n' "$*" > /dev/kmsg 2>/dev/null || true
}
err() {
    printf '\033[1;31m[wootc]\033[0m %s\n' "$*" >&2
    printf '[wootc] ERROR: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

# A failed target-side dracut run must not leave the Windows volume, loop
# devices, or chroot bind mounts busy.  That would prevent a useful retry from
# the deployer shell and can otherwise make the next boot non-deterministic.
NTFS_PART=""
LOOP_DEV=""
VERIFY_LOOP=""
SCRATCH_LOOP=""
SCRATCH_IMG=""
cleanup() {
    local mount
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
    for mount in /mnt/verify/sys /mnt/verify/proc /mnt/verify/dev \
        /mnt/verify/boot /mnt/verify /var/tmp /var/lib/containers /var/fisherman-tmp /mnt/ntfs; do
        mountpoint -q "$mount" 2>/dev/null && umount "$mount" 2>/dev/null || true
    done
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

# ── Container storage scratch ───────────────────────────────────────────────
# The initramfs root is ramfs: a multi-GB image pull there exhausts RAM.
# fisherman does all heavy I/O under its scratch dir /var/fisherman-tmp
# (podman --root, OCI cache, bootc /var/tmp bind), so back that path with an
# ext4 loop file on the Windows NTFS partition (fisherman's overlay probe
# needs a real POSIX fs, so not NTFS directly). Deleted after deployment.
SCRATCH_IMG="/mnt/ntfs/wootc/cache/deployer-scratch.img"
log "Creating fisherman scratch at ${SCRATCH_IMG}..."
mkdir -p /mnt/ntfs/wootc/cache /var/fisherman-tmp /var/lib/containers
truncate -s 30G "$SCRATCH_IMG"
mkfs.ext4 -q -F "$SCRATCH_IMG"
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
log "Registry pre-flight for ${IMAGE}..."
if [[ ! -s /etc/resolv.conf ]]; then
    cp /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi
log "resolv.conf: $(cat /etc/resolv.conf 2>/dev/null || echo '<missing>')"
if ! skopeo inspect --retry-times 3 "docker://${IMAGE}" >/dev/null; then
    err "cannot reach registry for ${IMAGE} (see skopeo error above)"
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

# ── Set up loop device ──────────────────────────────────────────────────────
losetup -fP "$DISK"
LOOP_DEV=$(losetup -j "$DISK" | cut -d: -f1)
log "Loop device: ${LOOP_DEV}"

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
  "composeFsBackend": false,
  "unifiedStorage": false,
  "selinuxDisabled": false,
  ${LUKS_JSON},
  "image": "${IMAGE}",
  "hostname": "${HOSTNAME}",
  "flatpaks": ${FLATPAKS_JSON}${USER_JSON}
}
EOF

log "Fisherman recipe:"
cat "$RECIPE"

# ── Run fisherman ───────────────────────────────────────────────────────────
log "Running fisherman — this pulls the image and deploys it..."
fisherman "$RECIPE"

losetup -d "$LOOP_DEV"
LOOP_DEV=""

# ── Post-deployment verification ─────────────────────────────────────────────
# Verify the installed system's passthrough and migration setup before rebooting.
# These markers are captured by the e2e test's serial console monitor.

log "Verifying installed system setup..."

# Re-mount the installed disk while its NTFS backing mount is still live.
VERIFY_LOOP=$(losetup -fP --show "$DISK")

# Find the root partition inside the loop device (typically partition 3 or 4)
VERIFY_ROOT=""
for p in "${VERIFY_LOOP}p1" "${VERIFY_LOOP}p2" "${VERIFY_LOOP}p3" "${VERIFY_LOOP}p4" "${VERIFY_LOOP}p5"; do
    if [[ -b "$p" ]]; then
        mkdir -p /mnt/verify
        if mount -o rw "$p" /mnt/verify 2>/dev/null; then
            if [[ -f /mnt/verify/etc/os-release ]]; then
                VERIFY_ROOT="$p"
                break
            fi
            umount /mnt/verify 2>/dev/null
        fi
    fi
done

if [[ -n "$VERIFY_ROOT" ]]; then
    log "Mounted installed system root at ${VERIFY_ROOT} for verification"

    VERIFY_BOOT="${VERIFY_LOOP}p2"
    if [[ ! -b "$VERIFY_BOOT" ]]; then
        err "  [FAIL] expected /boot partition ${VERIFY_BOOT} is missing"
        exit 1
    fi
    mkdir -p /mnt/verify/boot
    mount "$VERIFY_BOOT" /mnt/verify/boot

    # Install the runtime hook after bootc/fisherman has laid down the target.
    # This is the point at which Phase 2 becomes bootable: dracut learns that
    # the target root lives in an NTFS-backed loop file, not on a raw disk.
    install -d /mnt/verify/usr/lib/dracut/modules.d/99wootc-boot
    cp -a /usr/lib/wootc/99wootc-boot/. \
        /mnt/verify/usr/lib/dracut/modules.d/99wootc-boot/

    HOST_UUID=$(blkid -s UUID -o value "$NTFS_PART")
    if [[ -z "$HOST_UUID" ]]; then
        err "  [FAIL] could not determine Windows NTFS UUID"
        exit 1
    fi
    shopt -s nullglob
    BLS_ENTRIES=(/mnt/verify/boot/loader/entries/*.conf)
    if (( ${#BLS_ENTRIES[@]} == 0 )); then
        err "  [FAIL] no BLS entries found on installed /boot"
        exit 1
    fi
    for entry in "${BLS_ENTRIES[@]}"; do
        sed -i '/^options / s|$| wootc.host_uuid='"$HOST_UUID"' loop=/wootc/disks/root.disk|' "$entry"
    done
    shopt -u nullglob

    # Regenerate every initramfs only after the module and BLS arguments exist.
    # Bind mounts provide dracut the minimal runtime view it expects in chroot.
    for fs in dev proc sys; do mount --bind "/$fs" "/mnt/verify/$fs"; done
    chroot /mnt/verify dracut --force --regenerate-all
    for fs in sys proc dev; do umount "/mnt/verify/$fs"; done

    # Check dracut module
    if [[ -d /mnt/verify/usr/lib/dracut/modules.d/99wootc-boot ]]; then
        log "  [PASS] dracut 99wootc-boot module installed"
    else
        err "  [FAIL] dracut 99wootc-boot module NOT found"
    fi

    # Check host bind service
    if [[ -f /mnt/verify/etc/systemd/system/wootc-host-bind.service ]]; then
        log "  [PASS] wootc-host-bind.service installed"
    else
        err "  [WARN] wootc-host-bind.service NOT found (fisherman may install it)"
    fi

    # Check passthrough service
    if [[ -f /mnt/verify/etc/systemd/system/wootc-passthrough.service ]]; then
        log "  [PASS] wootc-passthrough.service installed"
    else
        err "  [WARN] wootc-passthrough.service NOT found (may be generated post-boot)"
    fi

    # Check wootc-mount-user-dirs helper
    if [[ -f /mnt/verify/usr/local/bin/wootc-mount-user-dirs ]]; then
        log "  [PASS] wootc-mount-user-dirs helper installed"
    fi

    if grep -q 'wootc.host_uuid=.*loop=/wootc/disks/root.disk' /mnt/verify/boot/loader/entries/*.conf; then
        log "  [PASS] Phase 2 loop-root arguments in BLS entries"
    else
        err "  [FAIL] Phase 2 loop-root arguments missing from BLS entries"
        exit 1
    fi

    umount /mnt/verify/boot
    umount /mnt/verify
else
    err "  [WARN] Could not mount installed root for verification (checking via loop file only)"
fi

losetup -d "$VERIFY_LOOP"
VERIFY_LOOP=""

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

log "Verification complete. Rebooting..."
log "  [wootc] VERIFICATION_SUMMARY: deployer ready for migration phase"
sleep 3
sync || true
# reboot -f is systemctl reboot -f and hangs under emergency mode; use the
# direct syscall (everything is unmounted by this point).
reboot -ff || reboot -f
