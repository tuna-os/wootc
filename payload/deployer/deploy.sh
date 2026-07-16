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

# ── Live telemetry ──────────────────────────────────────────────────────────
# Stream the journal to NTFS continuously: the exit-trap post-mortem is
# written by exactly the code that can hang, so a wedge must still leave a
# fresh journal on disk. Heartbeat gives the serial monitor a liveness and
# resource signal (a 7-minute image pull must look different from a hang).
LOG_DIR=/mnt/ntfs/wootc/logs
mkdir -p "$LOG_DIR"
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
# must fit in C:'s free space alongside the fully-allocated root.disk.
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

# Re-mount the installed disk while its NTFS backing mount is still live.
VERIFY_LOOP=$(losetup -fP --show "$DISK")
udevadm settle --timeout=10 2>/dev/null || true

# Find the root partition inside the loop device. bootc/ostree roots have no
# top-level /etc — the OS tree lives under /ostree/deploy/<stateroot>/deploy/.
VERIFY_ROOT=""
for p in "${VERIFY_LOOP}"p*; do
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

    # Install the runtime hook after bootc/fisherman has laid down the target.
    # This is the point at which Phase 2 becomes bootable: the initramfs
    # learns to attach the NTFS-backed loop so the root UUID appears.
    install -d "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot"
    cp -a /usr/lib/wootc/99wootc-boot/. \
        "$DEPLOY_ROOT/usr/lib/dracut/modules.d/99wootc-boot/"

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
        chroot "$DEPLOY_ROOT" dracut --force --hostonly \
            --fwdir /run/wootc-nofw \
            --omit "plymouth crypt lvm mdraid dm multipath iscsi nbd nfs cifs fcoe fcoe-uefi resume rescue network network-legacy network-manager kernel-network-modules cellular qemu-net memstrack" \
            "$INITRD_CHROOT_PATH" "$KVER"
        REGEN_SIZE=$(ls -l "${OSTREE_INITRDS[0]}" | awk '"'"'{print $5}'"'"')
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

    # Check host bind service
    if [[ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-host-bind.service" ]]; then
        log "  [PASS] wootc-host-bind.service installed"
    else
        err "  [WARN] wootc-host-bind.service NOT found (fisherman may install it)"
    fi

    # Check passthrough service
    if [[ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-passthrough.service" ]]; then
        log "  [PASS] wootc-passthrough.service installed"
    else
        err "  [WARN] wootc-passthrough.service NOT found (may be generated post-boot)"
    fi

    if grep -q 'wootc.host_uuid=.*loop=/wootc/disks/root.disk' "$DEPLOY_ROOT"/boot/loader/entries/*.conf; then
        log "  [PASS] Phase 2 loop-root arguments in BLS entries"
    else
        err "  [FAIL] Phase 2 loop-root arguments missing from BLS entries"
        exit 1
    fi

    # ── ESP kernel-sync for Phase-2 Secure Boot boot ──────────────────────
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

            if [[ -n "$KERNEL_SRC" && -s "$KERNEL_SRC" ]] && \
               [[ -n "$INITRD_SRC" && -s "$INITRD_SRC" ]] && \
               cp "$KERNEL_SRC" /mnt/esp/EFI/wootc/phase2-vmlinuz && \
               cp "$INITRD_SRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                log "  Copied kernel and initramfs to ESP:EFI/wootc/"

                # Kernel cmdline from the patched BLS entry (keeps root=UUID
                # and ostree=; the loop-attach hook makes that UUID appear).
                ROOT_OPTIONS=$(grep '^options ' "$DEPLOY_ROOT"/boot/loader/entries/*.conf 2>/dev/null | head -1 | sed 's/^options *//')
                # BLS $kernelopts-style variables never resolve in our
                # grub.cfg; drop tokens containing '$'.
                ROOT_OPTIONS=$(printf '%s' "$ROOT_OPTIONS" | tr ' ' '\n' | grep -v '\$' | tr '\n' ' ')

                # Write Phase-2 grub.cfg at the signed GRUB's embedded prefix.
                mkdir -p /mnt/esp/EFI/fedora
                cat > /mnt/esp/EFI/fedora/grub.cfg <<GRUBEOF
# wootc Phase 2 — boot installed system from root.disk
set default=0
set timeout=5

menuentry "wootc Linux" {
    linux /EFI/wootc/phase2-vmlinuz ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200
    initrd /EFI/wootc/phase2-initramfs.img
}
GRUBEOF
                log "  [PASS] Phase-2 grub.cfg written to EFI/fedora/grub.cfg"
            else
                # Never leave the ESP kernel-less: the deployer pair was
                # removed above to make room, so restore it from the
                # canonical NTFS copies before failing.
                err "  [FAIL] Phase-2 ESP sync failed (missing or unwritable kernel/initramfs)"
                rm -f /mnt/esp/EFI/wootc/phase2-vmlinuz /mnt/esp/EFI/wootc/phase2-initramfs.img
                cp /mnt/ntfs/wootc/install/deployer-vmlinuz /mnt/esp/EFI/wootc/deployer-vmlinuz 2>/dev/null || true
                cp /mnt/ntfs/wootc/install/deployer-initramfs.img /mnt/esp/EFI/wootc/deployer-initramfs.img 2>/dev/null || true
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

phase "reboot"
log "Verification complete. Rebooting..."
log "  [wootc] VERIFICATION_SUMMARY: deployer ready for migration phase"
sleep 3
sync || true
# reboot -f is systemctl reboot -f and hangs under emergency mode; use the
# direct syscall (everything is unmounted by this point).
reboot -ff || reboot -f
