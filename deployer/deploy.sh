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

log() { printf '\033[1;32m[wootc]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[wootc]\033[0m %s\n' "$*" >&2; }

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
DEBUG="$(read_cmdline wootc.debug)"

if [[ -z "$IMAGE" ]]; then
    err "wootc.image= not set on kernel command line"
    err "Add wootc.image=ghcr.io/tuna-os/yellowfin:gnome to the GRUB menu entry"
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

ROOT_DISK_PATH="/wootc/disks/root.disk"

# ── Find NTFS partition containing root.disk ────────────────────────────────
log "Searching for ${ROOT_DISK_PATH}..."

NTFS_PART=""
for dev in /dev/sd* /dev/nvme* /dev/vd*; do
    [[ -b "$dev" ]] || continue
    mkdir -p /mnt/scan
    if mount -t ntfs3 -o ro "$dev" /mnt/scan 2>/dev/null; then
        if [[ -f "/mnt/scan${ROOT_DISK_PATH}" ]]; then
            NTFS_PART="$dev"
            log "Found ${ROOT_DISK_PATH} on ${NTFS_PART}"
            umount /mnt/scan
            break
        fi
        umount /mnt/scan
    fi
done

if [[ -z "$NTFS_PART" ]]; then
    err "Could not find ${ROOT_DISK_PATH} on any partition"
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

# ── Mount NTFS read-write ───────────────────────────────────────────────────
mkdir -p /mnt/ntfs
mount -t ntfs3 -o rw "$NTFS_PART" /mnt/ntfs
DISK="/mnt/ntfs/wootc/disks/root.disk"

# ── Set up loop device ──────────────────────────────────────────────────────
losetup -fP "$DISK"
LOOP_DEV=$(losetup -j "$DISK" | cut -d: -f1)
log "Loop device: ${LOOP_DEV}"

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
  "flatpaks": ${FLATPAKS_JSON}
}
EOF

log "Fisherman recipe:"
cat "$RECIPE"

# ── Run fisherman ───────────────────────────────────────────────────────────
log "Running fisherman — this pulls the image and deploys it..."
fisherman "$RECIPE"

# ── Cleanup ─────────────────────────────────────────────────────────────────
losetup -d "$LOOP_DEV"
umount /mnt/ntfs

log "Deployment complete. Rebooting..."
sleep 3
reboot -f
