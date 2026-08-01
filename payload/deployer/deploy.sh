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
    # Translate each internal phase into calm, non-technical reassurance on
    # the full-screen splash (North Star: a nervous Windows user must never
    # see console/kernel output and must feel that good things are happening).
    # Fields: <start%> <ceiling%> <friendly message>. The animator eases the
    # bar from start toward ceiling so it is always visibly moving.
    case "$1" in
        ntfs-mounted)       splash_set  6 12 "Preparing your disk..." ;;
        scratch-setup)      splash_set 12 18 "Preparing your disk..." ;;
        registry-preflight) splash_set 18 24 "Connecting to the software library..." ;;
        fisherman)          splash_set 26 86 "Downloading and installing your Linux system..." ;;
        verification)       splash_set 88 95 "Almost there - making sure everything is perfect..." ;;
        reboot)             splash_set 100 100 "All set! Starting your new Linux system..." ;;
        *) : ;;
    esac
}

# ── Reassuring full-screen install UI ───────────────────────────────────────
# The deployer's real work (kernel messages, container pulls, fisherman) goes
# to the SERIAL console + persistent log. On the SCREEN the user sees only
# this: a calm title, a friendly one-line status, a progress bar that is
# always moving, and a standing promise that their Windows and files are safe.
# Drawn on /dev/tty1 (the VGA text console; the deploy logs never touch it,
# so it stays clean). `wootc.debug` turns the splash off and shows raw console
# for troubleshooting.
SPLASH_TTY=/dev/tty1
SPLASH_STATE=/run/wootc-splash
SPLASH_PID=""
splash_on() { [[ "${DEBUG:-}" != 1 ]] && [[ -w "$SPLASH_TTY" ]]; }

# splash_set <start%> <ceiling%> <message> — the animator eases from start
# toward ceiling so the bar keeps creeping up within a phase (never frozen).
splash_set() {
    splash_on || return 0
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$SPLASH_STATE" 2>/dev/null || true
}

splash_paint() {  # <pct> <message> <spinner-char>
    local pct="$1" msg="$2" sp="$3" i filled bar=""
    filled=$(( pct * 46 / 100 ))
    for ((i = 0; i < 46; i++)); do (( i < filled )) && bar+="#" || bar+="-"; done
    # Repaint in place (cursor-home, clear-to-EOL per line) — no full-screen
    # clear, so it never flickers. \033[K wipes any leftover from a longer
    # previous message.
    {
        printf '\033[H\033[?25l'
        printf '\n\n\n\n'
        printf '\033[1;96m                     Setting up your new Linux system\033[0m\033[K\n\n\n'
        printf '\033[0;97m                     %s  %s\033[0m\033[K\n\n\n' "$sp" "$msg"
        printf '\033[1;96m                     [%s] %3d%%\033[0m\033[K\n\n\n\n\n' "$bar" "$pct"
        printf '\033[0;92m                [OK]  Your Windows and all of your files are safe.\033[0m\033[K\n\n'
        printf '\033[0;97m                   This usually takes about 5 to 15 minutes.\033[0m\033[K\n'
        printf '\033[0;97m                   Please keep your PC plugged in - no need to touch anything.\033[0m\033[K\n'
    } > "$SPLASH_TTY" 2>/dev/null || true
}

splash_start() {
    splash_on || return 0
    # Own the screen: hide cursor, disable console blanking (ESC[9;0]) so it
    # never goes black mid-deploy, and clear once (the animator repaints in
    # place after this).
    printf '\033[?25l\033[9;0]\033[2J\033[H' > "$SPLASH_TTY" 2>/dev/null || true
    setterm -blank 0 -powerdown 0 >"$SPLASH_TTY" 2>/dev/null || true
    splash_set 2 6 "Getting things ready..."
    (
        local frame=0 cur=2 spinners='|/-\' last=""
        while :; do
            local start ceil msg line
            line=$(cat "$SPLASH_STATE" 2>/dev/null || true)
            IFS=$'\t' read -r start ceil msg <<< "$line"
            [ -n "${start:-}" ] || { start=2; ceil=6; msg="Working..."; }
            # New phase → jump to its start; otherwise creep toward its ceiling.
            if [ "$line" != "$last" ]; then cur="$start"; last="$line"; fi
            if [ "$cur" -lt "$ceil" ]; then
                cur=$(( cur + ( (ceil - cur) / 12 ) + 1 ))
                [ "$cur" -gt "$ceil" ] && cur="$ceil"
            fi
            splash_paint "$cur" "$msg" "${spinners:frame%4:1}"
            frame=$(( frame + 1 ))
            sleep 2
        done
    ) &
    SPLASH_PID=$!
}
splash_stop() { [[ -n "$SPLASH_PID" ]] && kill "$SPLASH_PID" 2>/dev/null || true; SPLASH_PID=""; }

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
    local _rc=$? mount
    [[ -n "$JOURNAL_STREAM_PID" ]] && kill "$JOURNAL_STREAM_PID" 2>/dev/null || true
    [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null || true

    # On FAILURE, put the deployer's own log tail on the SERIAL. log() writes to
    # $PERSIST_LOG on the NTFS, and err() to stderr — so on a failed deploy,
    # where Windows never returns to hand the file back, the detailed record is
    # stranded on a disk image nobody can read without libguestfs (absent from
    # our runners). dakota died at t=1124s having emitted exactly two serial
    # lines: its version, and a cleanup warning. The reason was written down and
    # unreachable (himachal 20260727T082629Z, and the hosted cell before it).
    if [[ "$_rc" -ne 0 && -s "${PERSIST_LOG:-/nonexistent}" ]]; then
        err "──── deployer log, last 60 lines (exit $_rc) ────"
        tail -n 60 "$PERSIST_LOG" 2>/dev/null | while IFS= read -r _line; do
            printf '\033[1;31m[wootc]\033[0m   %s\n' "$_line" >&2
        done
        err "──── end deployer log ────"
    fi
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
    splash_stop
    # On any failure the user must not be left on a frozen "installing"
    # screen. A friendly, non-alarming message + the reassurance that Windows
    # is untouched; the technical detail is on the serial log for us.
    if [[ "${DEPLOY_OK:-0}" != 1 && "${DEBUG:-}" != 1 && -w "${SPLASH_TTY:-/dev/null}" ]]; then
        {
            printf '\033[H\033[2J\033[?25h\n\n\n\n'
            printf '\033[1;93m                     We could not finish setting up Linux this time.\033[0m\n\n\n'
            printf '\033[0;92m                [OK]  Your Windows and all of your files are completely safe.\033[0m\n\n'
            printf '\033[0;97m                   Your PC will restart back into Windows in a moment.\033[0m\n'
            printf '\033[0;97m                   You can simply try again — nothing was changed.\033[0m\n'
        } > "$SPLASH_TTY" 2>/dev/null || true
        sleep 6 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Name the command that aborts the deploy. `set -e` here is silent, and the
# "last 60 lines" dump only shows the last SUCCESSFUL log line — so a failing
# command that logs nothing is invisible. bluefin-dakota-win11pro (run
# 30267737413) exited 32 with its final line being "skipping dracut regen",
# leaving the actual failure unlocatable from a 60-minute run. -E is already
# set, so this propagates into functions and subshells.
wootc_report_abort() {
    local rc="$1" cmd="$2"
    case "$cmd" in exit*) return 0 ;; esac
    err "ABORT: line ${BASH_LINENO[0]:-?}: ${cmd} (exit ${rc})"
}
trap 'wootc_report_abort "$?" "$BASH_COMMAND"' ERR

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
# Keep the registry origin distinct from any transient local image that the
# deployer derives (for example localhost/wootc-ntfs-injected).  Phase 3 runs
# in the installed system, whose containers-storage does not contain the
# deployer's temporary tag, and needs this authoritative source to install a
# native disk.
SOURCE_IMAGE="$IMAGE"
FILESYSTEM="$(read_cmdline wootc.filesystem xfs)"
HOSTNAME="$(read_cmdline wootc.hostname tunaos)"
FLATPAKS="$(read_cmdline wootc.flatpaks)"
LUKS_TYPE="$(read_cmdline wootc.luks none)"
LUKS_PASSPHRASE="$(read_cmdline wootc.luks-passphrase)"
VAULT_PATH="$(read_cmdline wootc.vault)"
DEBUG="$(read_cmdline wootc.debug)"
# Bring up the reassuring full-screen install UI as early as possible so the
# very first thing on screen after "Booting wootc" is calm and friendly, not
# a black screen or console text.
splash_start
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
# Each mount is bounded by `timeout`: a BitLocker volume keeps an NTFS-shaped
# boot sector for compatibility, so ntfs3/ntfs-3g can STALL parsing the
# ciphertext. Without a bound, one bad partition wedges the whole scan before it
# reaches the plaintext volume that actually holds root.disk (#34). ntfs-3g is a
# FUSE daemon — `timeout` kills it cleanly on a hang.
try_mount_scan() {
    local dev="$1"
    timeout 30 mount -t ntfs3 -o ro "$dev" /mnt/scan 2>/dev/null && { echo "ntfs3"; return 0; }
    timeout 30 mount -t ntfs3 -o ro,force "$dev" /mnt/scan 2>/dev/null && { echo "ntfs3-force"; return 0; }
    command -v ntfs-3g >/dev/null 2>&1 &&
        timeout 30 ntfs-3g -o ro "$dev" /mnt/scan 2>/dev/null && { echo "ntfs-3g"; return 0; }
    return 1
}

scan_for_root_disk() {
    local dev drv fstype
    # Per-device findings are also collected here and replayed NEXT TO the
    # final error. The harness only dumps the last ~30 serial lines on failure,
    # so the per-device lines below scroll away and #34 kept arriving as a bare
    # "Could not find root.disk on any partition" with no evidence (BitLocker
    # run 30149803795). Adjacent beats earlier.
    SCAN_REPORT=""
    for dev in /dev/sd* /dev/nvme* /dev/vd*; do
        [[ -b "$dev" ]] || continue
        # Name every device's filesystem signature — a BitLocker path (#34)
        # otherwise leaves no trace of WHY a volume was passed over. blkid's
        # BitLocker prober reports TYPE=BitLocker for FVE-encrypted C:.
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
        if [[ "$fstype" == "BitLocker" ]]; then
            # root.disk is never on the encrypted C: — setup-wootc.ps1 carves a
            # separate PLAINTEXT NTFS volume (wootc-data) for it. Skip the
            # ciphertext explicitly: ntfs3/ntfs-3g would stall or mount garbage
            # on its NTFS-shaped boot sector and could wedge the scan.
            log "  ${dev}: BitLocker-encrypted (TYPE=BitLocker) — skipping; root.disk lives on the plaintext wootc-data volume"
            SCAN_REPORT="${SCAN_REPORT}${dev}=BitLocker(skipped) "
            continue
        fi
        mkdir -p /mnt/scan
        if drv=$(try_mount_scan "$dev"); then
            if [[ -f "/mnt/scan${ROOT_DISK_PATH}" ]]; then
                log "  found ${ROOT_DISK_PATH} on ${dev} (mounted via ${drv})"
                NTFS_PART="$dev"
                umount /mnt/scan 2>/dev/null || err "  [WARN] could not unmount /mnt/scan (busy?) — continuing"
                return 0
            fi
            # Say WHAT is on the volume instead of just "not here" — the BitLocker
            # path (#34) hinges on whether setup wrote root.disk to the right
            # place: "has wootc/disks but no root.disk" is a placement bug;
            # "no wootc/ at all" means the wrong volume; both are one glance now
            # instead of a VM session. (Serial-only: the persistent log lives on
            # the very volume we're hunting for.)
            log "  ${dev}: mounted via ${drv}, no ${ROOT_DISK_PATH}"
            SCAN_REPORT="${SCAN_REPORT}${dev}=${fstype:-?}/${drv}:no-root.disk[$(ls -A /mnt/scan 2>/dev/null | tr '\n' ',' | cut -c1-60)] "
            log "    top-level: $(ls -A /mnt/scan 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
            [[ -d /mnt/scan/wootc ]] && \
                log "    wootc/: $(ls -A /mnt/scan/wootc 2>/dev/null | tr '\n' ' ')" && \
                log "    wootc/disks/: $(ls -lA /mnt/scan/wootc/disks 2>/dev/null | tail -n +2 | tr '\n' ';' | cut -c1-200)"
            umount /mnt/scan 2>/dev/null || err "  [WARN] could not unmount /mnt/scan (busy?) — continuing"
        else
            # Silence here is what made #36 unattributable for two runs.
            log "  ${dev}: not mountable as NTFS (TYPE=${fstype:-none}; ntfs3, ntfs3+force, ntfs-3g all failed)"
            SCAN_REPORT="${SCAN_REPORT}${dev}=${fstype:-none}(unmountable) "
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
    err "scan verdict per device: ${SCAN_REPORT:-<none scanned>}"
    err "final /proc/partitions:"
    cat /proc/partitions >&2 || true
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi

# ── Mount NTFS read-write ───────────────────────────────────────────────────
mkdir -p /mnt/ntfs
if ! mount -t ntfs3 -o rw,force "$NTFS_PART" /mnt/ntfs 2>/dev/null && ! mount -t ntfs3 -o rw "$NTFS_PART" /mnt/ntfs; then
    err "cannot mount ${NTFS_PART} read-write — the NTFS volume is likely dirty"
    err "(Windows hibernated, Fast Startup, or an unclean shutdown)."
    err "Boot Windows once, perform a full shutdown, and retry."
    if [[ "$DEBUG" ]]; then exec /bin/bash; else exit 1; fi
fi
DISK="/mnt/ntfs/wootc/disks/root.disk"

# Ensure root.disk ValidDataLength (VDL) is advanced to the full file size on NTFS.
# ntfs3 returns EIO on loopback writes past VDL. Writing to the final byte of root.disk
# sets VDL = 32 GiB on host NTFS, allowing loopback writes across all sectors.
if [[ -f "$DISK" ]]; then
    _disk_size=$(stat -c%s "$DISK" 2>/dev/null || echo 0)
    if [[ "$_disk_size" -gt 0 ]]; then
        log "advancing NTFS ValidDataLength for root.disk (${_disk_size} bytes)..."
        dd if=/dev/zero of="$DISK" bs=1 count=1 seek=$((_disk_size - 1)) conv=notrunc status=none || true
        # This writes the WHOLE file (35 GiB) and used to run as a single
        # status=none dd, so the serial went SILENT for however long the write
        # took. That is indistinguishable from a hang: BitLocker cells sat at
        # >100% guest CPU with zero output for 89 minutes and blew the 90-minute
        # deploy budget, with the console dump ending at the block-device table
        # (runs 30165015199, 30173452904). Write in chunks and log each one, so
        # the step is visible, its rate is measurable, and a genuinely slow
        # volume is distinguishable from a wedge.
        _chunk_mb=4096
        _total_mb=$(( _disk_size / 1048576 + 1 ))
        _done_mb=0
        _vdl_t0=$(date +%s)
        while [ "$_done_mb" -lt "$_total_mb" ]; do
            _n_mb=$(( _total_mb - _done_mb ))
            [ "$_n_mb" -gt "$_chunk_mb" ] && _n_mb=$_chunk_mb
            tr '\0' '\377' < /dev/zero | \
                dd of="$DISK" bs=1M count="$_n_mb" seek="$_done_mb" conv=notrunc status=none 2>/dev/null || true
            _done_mb=$(( _done_mb + _n_mb ))
            log "  VDL: ${_done_mb}/${_total_mb} MiB after $(( $(date +%s) - _vdl_t0 ))s"
        done
        sync
    fi
fi

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
# 20G (was 13G): the scratch holds the ntfs-inject pull AND fisherman's
# pull — the full extracted image plus transient blob staging. 13G fit
# bluefin:lts but ENOSPC'd on bonito:gnome mid-unpack ("write /usr/bin/yq:
# no space left on device", GH run 20260723T2257), leaving a full scratch
# of partial-image junk for everything downstream. The target disk still
# holds only the ostree deployment.
#
# Reuse an existing scratch: containers-storage inside it caches the pulled
# image, turning the multi-minute pull into a digest check on retries.
if [[ ! -f "$SCRATCH_IMG" ]] || [[ "$(blkid -o value -s TYPE "$SCRATCH_IMG" 2>/dev/null)" != "ext4" ]]; then
    log "Initializing new scratch filesystem..."
    truncate -s 20G "$SCRATCH_IMG"
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

    # ── Optional registry mirror (E2E bandwidth relief) ─────────────────────
    # A mirror.txt beside vault.json names a pull-through cache (host:port).
    # Concurrent E2E instances pulling multi-GB images through one uplink
    # starved each other into podman exit-125 (runs 20260723T1130/1201); a
    # LAN cache makes every image cross the wifi once. Probed, never trusted:
    # unreachable or absent → normal direct pulls. Podman falls back to the
    # upstream registry on any mirror failure, so this cannot break a deploy.
    # Parameter expansion, NOT dirname: the initramfs has no dirname binary,
    # and under set -e the failed substitution killed every deploy at t=33s
    # (run 20260723T1331 — 90 minutes of heartbeats over a corpse).
    MIRROR_FILE="/mnt/ntfs${VAULT_PATH%/*}/mirror.txt"
    if [[ -f "$MIRROR_FILE" ]]; then
        WOOTC_MIRROR=$(tr -d ' \r\n' < "$MIRROR_FILE")
        if [[ -n "$WOOTC_MIRROR" ]] && curl -fsS -m 3 "http://${WOOTC_MIRROR}/v2/" >/dev/null 2>&1; then
            log "Registry mirror ${WOOTC_MIRROR} reachable — routing ghcr.io pulls through it"
            mkdir -p /etc/containers/registries.conf.d
            cat > /etc/containers/registries.conf.d/wootc-mirror.conf <<MIRRORCONF
[[registry]]
prefix = "ghcr.io"
location = "ghcr.io"

[[registry.mirror]]
location = "${WOOTC_MIRROR}"
insecure = true
MIRRORCONF
        else
            log "Registry mirror '${WOOTC_MIRROR:-}' not reachable — pulling direct"
        fi
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
    if timeout 60 podman run --rm "$IMAGE" sh -c \
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
    timeout 60 podman rm -f "$cname" >/dev/null 2>&1 || true
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
    # RETRY the network-dependent install: reaching EPEL/CRB mirrors from a
    # hosted runner's stripped initramfs is intermittently flaky, and a single
    # blip here is the difference between a bootable Phase 2 and an emergency
    # shell (el10-gnome-win10pro 20260724: injection failed on a transient
    # mirror error while the win11pro run of the SAME image succeeded — not an
    # edition bug, a missing retry). Same fix class as the go-native pull.
    local inj_ok=""
    # ACQUIRE FIRST. `podman run` on a non-local image PULLS it, and a multi-GB
    # bootc image cannot pull AND run dnf inside the 150s below — so injection
    # failed on every cold cache and blamed "(network/repo?)", which is not what
    # went wrong. It only ever succeeded when the image happened to be cached,
    # which is why this looked intermittent. Same defect as the backend probe
    # (375ae2f), one function later.
    if ! timeout 120 podman image exists "$IMAGE" 2>/dev/null; then
        log "  ntfs-3g injection: pulling ${IMAGE} first (not local yet)"
        if ! timeout "${WOOTC_PROBE_PULL_TIMEOUT:-1800}" podman pull "$IMAGE" >/dev/null 2>&1; then
            err "  [WARN] could not pull ${IMAGE} — the injection below will fail for that reason, not a repo one"
        fi
    fi
    local attempt inj_err
    inj_err="${TMPDIR:-/tmp}/wootc-ntfs-inject.err"
    for attempt in 1 2 3; do
        timeout 60 podman rm -f "$cname" >/dev/null 2>&1 || true
        if timeout 300 podman run --name "$cname" --network=host "$IMAGE" sh -c \
            'dnf install -y ntfs-3g qemu-guest-agent || \
             { { dnf install -y epel-release || \
                 dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm; } && \
               { dnf config-manager --set-enabled crb 2>/dev/null || true; } && \
               dnf install -y ntfs-3g qemu-guest-agent; } || \
             microdnf install -y ntfs-3g qemu-guest-agent || rpm-ostree install ntfs-3g qemu-guest-agent' 2>"$inj_err"; then
            inj_ok=1
            break
        fi
        err "  [WARN] ntfs-3g install attempt ${attempt}/3 failed in ${IMAGE}"
        # podman's OWN stderr, not just the container's: when the container
        # never starts (image not pulled, netavark, storage lock) `podman logs`
        # is EMPTY, which is exactly the case that kept being misread as a repo
        # problem. Print both.
        [ -s "$inj_err" ] && { err "  podman: $(tail -3 "$inj_err" | tr '\n' ' ')"; }
        timeout 60 podman logs "$cname" 2>&1 | tail -10 >&2 || true
        [ "$attempt" -lt 3 ] && sleep $((attempt * 10))
    done
    if [ -z "$inj_ok" ]; then
        err "  [WARN] ntfs-3g install failed after 3 attempts in ${IMAGE}; relying on the image's own NTFS support"
        timeout 60 podman rm -f "$cname" >/dev/null 2>&1 || true
        return 1
    fi
    if ! timeout 300 podman commit -q "$cname" "$derived" >/dev/null 2>&1; then
        err "  [WARN] could not commit the NTFS-injected image (disk space?); deploying the original"
        timeout 60 podman rm -f "$cname" >/dev/null 2>&1 || true
        return 1
    fi
    timeout 60 podman rm -f "$cname" >/dev/null 2>&1 || true
    IMAGE="$derived"
    log "  [PASS] injected ntfs-3g; deploying ${IMAGE}"
    # Prove it actually landed rather than trusting the commit.
    if ! timeout 60 podman run --rm "$IMAGE" sh -c 'command -v ntfs-3g >/dev/null && command -v qemu-ga >/dev/null'; then
        err "  [WARN] ntfs-3g or qemu-guest-agent still absent from ${IMAGE} after injection"
        return 1
    fi
    log "  [PASS] verified ntfs-3g + qemu-guest-agent present in the deployed image"
}
# "Using the image's own NTFS support" must be CHECKED, not hoped for. When
# injection fails on an image whose kernel has no ntfs3 — every EL-family image,
# yellowfin included — the deploy still "succeeds" and produces a system that
# CANNOT boot Phase 2. el10-gnome-win10pro (20260727T082625Z) spent 91 minutes
# proving it: three failed injection attempts at minute ~10, a full deploy, then
#     wootc: EXIT: cannot mount host NTFS rw (no ntfs3, no ntfs-3g)
#            /proc/filesystems ntfs3=0 ntfs-3g=no
# and an emergency shell. The information needed to predict that was available
# 80 minutes earlier. Fail there instead, naming the cause.
if ! ensure_ntfs_support; then
    log "NTFS injection unavailable; checking whether the image can mount NTFS on its own"
    # Use the IDENTICAL capability test ensure_ntfs_support uses. My first
    # version omitted the CONFIG_NTFS3_FS grep, and deploy.sh warns explicitly
    # why that matters: a kernel with CONFIG_NTFS3=y is built in, ships no .ko,
    # and mounts ntfs3 fine — "a run where this injection FAILED still booted
    # Phase-2 successfully ... making these failures fatal broke deploys that
    # worked". A weaker probe here would refuse deploys that work.
    # (`/proc/filesystems` inside the container reflects the DEPLOYER's kernel,
    # not the image's, so it is checked last and never alone.)
    if timeout 300 podman run --rm --network=host "$IMAGE" sh -c \
        'command -v ntfs-3g >/dev/null 2>&1 || command -v mount.ntfs >/dev/null 2>&1 || \
         ls /usr/lib/modules/*/kernel/fs/ntfs3/ntfs3.ko* >/dev/null 2>&1 || \
         grep -qxE "CONFIG_NTFS3_FS=[ym]" /usr/lib/modules/*/config 2>/dev/null' \
        >/dev/null 2>&1; then
        log "  image provides its own NTFS driver — continuing without injection"
    elif command -v ntfs-3g >/dev/null 2>&1; then
        # The DEPLOYER ships ntfs-3g (its Containerfile) and both Phase-2 paths
        # already take it from there when the image has none:
        #   composefs → the early cpio copies /usr/bin/ntfs-3g + libntfs-3g
        #   ostree    → the NTFS_BINS fallback copies it into the deployment
        # So an image without a driver is NOT unbootable; refusing here blocked
        # dakota on every runner whose initramfs cannot reach EPEL/CRB, which is
        # both self-hosted boxes (bluefin-dakota-win11pro-phase3, 2026-07-27:
        # three injection attempts over 10 minutes, then this refusal at 27m).
        log "  image has no NTFS driver and injection failed — Phase 2 will carry the DEPLOYER's ntfs-3g instead"
    else
        err "  [FAIL] ${IMAGE} has NO NTFS driver (no kernel ntfs3, no ntfs-3g) and injection failed."
        err "         Phase 2 could not mount the Windows volume that holds root.disk, so it would"
        err "         drop to an emergency shell. Refusing to write an unbootable deployment."
        err "         Cause is almost always the ntfs-3g install above: network or repo reachability"
        err "         from the deployer (EPEL/CRB for EL-family images)."
        exit 1
    fi
fi

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
GENERIC_IMAGE=0   # set to 1 for ostree images with no bootupd (see below)
if [[ "$COMPOSEFS" == auto || "$BOOTLOADER" == auto ]]; then
    # ACQUIRE before INSPECTING. `podman run` on an image that is not local must
    # PULL it first, and a multi-GB bootc image cannot land inside a 30s probe
    # timeout — so the probe "failed", fell back to ostree/grub2, and
    # composefs-native images (dakota, marlin) were silently deployed down the
    # OSTREE path with none of the branch logic below ever running. That is why
    # the composefs axis never moved: dilli's dakota run logged
    # "podman run image inspection timed out/failed" at 12 minutes in.
    #
    # $IMAGE is local already when ntfs-3g injection succeeded (it becomes
    # localhost/wootc-ntfs-injected), and remote when injection failed — which
    # is precisely when the fallback fired. `podman image exists` covers both
    # without trying to pull a localhost-only tag.
    # EVERY podman call here is bounded. An unbounded one is a silent hang: the
    # ntfs-3g injection immediately above ends with `podman rm -f`, and podman
    # storage can still be locked when the next command arrives. dakota on
    # himachal (2026-07-27) went completely silent right here at t=571s and
    # produced NOTHING for the remaining 80 minutes — fisherman never started,
    # so the run burned its whole budget with no output to say why.
    #
    # The announcement comes FIRST, so the next occurrence proves whether this
    # point was even reached rather than leaving it to inference.
    log "  backend probe: checking whether $IMAGE is already local"
    if ! timeout 120 podman image exists "$IMAGE" 2>/dev/null; then
        log "  backend probe: pulling $IMAGE (not local yet)"
        if ! timeout "${WOOTC_PROBE_PULL_TIMEOUT:-1800}" podman pull "$IMAGE" >/dev/null 2>&1; then
            err "  [WARN] could not pull $IMAGE for backend detection (network/registry?)"
        fi
    fi
    log "  backend probe: image ready, inspecting"
    if ! DETECT="$(timeout 120 podman run --rm --network=host "$IMAGE" sh -c '
        if { ls /usr/lib/bootupd/updates/EFI/*/grubx64.efi >/dev/null 2>&1 ||
             { test -f /usr/lib/bootupd/updates/EFI.json &&
               find /usr/lib/efi/grub2 -type f -name grubx64.efi -print -quit 2>/dev/null | grep -q . &&
               find /usr/lib/efi/shim -type f -name shimx64.efi -print -quit 2>/dev/null | grep -q .; }; }; then
            echo BACKEND=ostree
        elif grep -A8 "^\[composefs\]" /usr/lib/ostree/prepare-root.conf 2>/dev/null \
             | grep -qiE "enabled[[:space:]]*=[[:space:]]*(yes|true|1|signed)"; then
            # Reaching here means the image has NO bootupd PAYLOAD (branch 1
            # failed), so an ostree install is impossible — bootc aborts with
            # "bootupd is required for ostree-based installs". If composefs is
            # enabled, this is a composefs-native image.
            #
            # The old test was `systemd-boot present && ! command -v bootupctl`,
            # which mis-classified exactly these images: marlin (Arch) ships the
            # bootupctl BINARY at /usr/sbin/bootupctl but has no
            # /usr/lib/bootupd payload, so the test failed, the image fell
            # through to "unknown", and we forced ostree/grub2 onto a
            # composefs-native image (probe: bootc 1.16.3, bootupd_dir=NONE,
            # composefs-info + mkcomposefs present, prepare-root
            # "[composefs] enabled = yes"). Per the bootc docs a composefs
            # install may use EITHER bootupd/GRUB or systemd-boot, so the
            # bootloader is not a backend signal at all.
            #
            # Order matters: bootupd-payload images (bluefin, yellowfin, bonito)
            # are matched by branch 1 first, so composefs-SEALED ostree images
            # keep the ostree path even though they also set enabled=yes here.
            echo BACKEND=composefs-native
        elif test -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi; then
            # No bootupd payload and no composefs marker, but it ships
            # systemd-boot: still the composefs-native path (the dakota shape).
            echo BACKEND=composefs-native
        else
            echo BACKEND=unknown
        fi
        grep -A8 "^\[composefs\]" /usr/lib/ostree/prepare-root.conf 2>/dev/null \
          | grep -qiE "enabled[[:space:]]*=[[:space:]]*(yes|true|1|signed)" && echo SEALED=1 || echo SEALED=0
    ' 2>/dev/null)"; then
        err "  [WARN] backend probe failed against $IMAGE; falling back to default backend (ostree/grub2, ext4 sealed)"
        err "  [WARN] a composefs-native image WILL be mis-deployed as ostree when this fires — treat any resulting pass as untested for composefs"
        err "  [WARN] image local? $(timeout 60 podman image exists "$IMAGE" 2>/dev/null && echo yes || echo NO)"
        DETECT="BACKEND=ostree
SEALED=1"
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
        # Neither bootupd-managed grub NOR systemd-boot: an ostree image that
        # ships no bootupd (non-Fedora/EL bootc images, e.g. Arch/Debian). bootc
        # install to-filesystem would abort "bootupd is required for ostree-based
        # installs" (arch-gnome, debian-gnome GH matrix 20260724). Deploy as
        # ostree/grub2 but pass --generic-image so bootc skips the bootupd check;
        # Phase 2 boots via the signed shim+grub wootc stages on the ESP anyway.
        log "  [WARN] no bootupd and no systemd-boot → ostree/grub2 + --generic-image (image ships no bootupd)"
        [[ "$COMPOSEFS"  == auto ]] && COMPOSEFS=0
        [[ "$BOOTLOADER" == auto ]] && BOOTLOADER=grub2
        GENERIC_IMAGE=1
    fi
    grep -q 'SEALED=1' <<<"$DETECT" && ROOTFS_SEALED=1 || ROOTFS_SEALED=0
fi
# Any lingering auto (e.g. an explicit wootc.composefs but auto bootloader) falls
# back to safe defaults.
[[ "$BOOTLOADER" == auto ]] && BOOTLOADER=grub2
[[ "$COMPOSEFS"  == auto ]] && COMPOSEFS=0

# A composefs-SEALED rootfs (native OR traditional ostree) needs fs-verity,
# which xfs lacks — so the deployer default cannot serve sealed images. ext4
# (mkfs -O verity) is the PROVEN sealed fallback (bluefin:lts 29/29 green,
# 2026-07-23). btrfs has native fs-verity and formats fine, but the ostree
# Phase-2 boot cannot mount the btrfs deployment — sysroot.mount times out on
# gpt-auto-root (GUI takes 9+10, 2026-07-24) — tracked as #35. Until that is
# fixed ext4 is the sealed default; btrfs stays reachable via
# wootc.filesystem=btrfs. Keyed off SEALED, NOT the backend — bonito-class
# ostree images can be sealed too.
if [[ "${ROOTFS_SEALED:-0}" == 1 || "$COMPOSEFS" == 1 ]] && \
   [[ "$FILESYSTEM" == xfs && -z "$(read_cmdline wootc.filesystem)" ]]; then
    FILESYSTEM=ext4
    log "  composefs-sealed rootfs → ext4 (fs-verity, proven); btrfs blocked on #35"
fi

# ── btrfs preflight: can the TARGET kernel actually LOAD btrfs? ─────────────
# Knowable here in seconds, otherwise it costs a full deploy plus a Phase-2
# emergency shell to discover. bluefin-lts-win11pro-btrfs (hosted matrix run
# 30700616717) formatted btrfs happily, deployed green, and then Phase 2 said:
#   Loading of module with unavailable key is rejected
#   [FAILED] Failed to start systemd-modules-load.service
#   wootc: btrfs /dev/loop0p3: module loaded=0 ID_BTRFS_READY=0 SYSTEMD_READY=0
# and sat in emergency until the harness gave up 25 minutes later. CentOS
# Stream 10 has no in-tree btrfs, so bluefin:lts carries an out-of-tree kmod
# signed with a key that kernel does not trust; under Secure Boot the kernel
# is locked down and rejects it, the udev readiness gate never clears, and the
# root=UUID device unit never activates (#35's shape, different cause).
#
# The SIGNER is the observable, not the module's presence: a kmod signed by
# the kernel's own key loads fine, and an unsigned-module kernel has no
# signature to reject. Compare btrfs's signer against the signer of a module
# that ships WITH the kernel, and only refuse on a positive mismatch.
if [[ "$FILESYSTEM" == btrfs ]]; then
    if ! timeout 120 podman image exists "$IMAGE" 2>/dev/null; then
        log "  btrfs preflight: pulling $IMAGE (not local yet)"
        timeout "${WOOTC_PROBE_PULL_TIMEOUT:-1800}" podman pull "$IMAGE" >/dev/null 2>&1 || true
    fi
    BTRFS_PROBE="$(timeout 120 podman run --rm --network=host "$IMAGE" sh -c '
        KV=$(ls /usr/lib/modules 2>/dev/null | head -1)
        [ -n "$KV" ] || exit 0
        echo "KVER=$KV"
        KO=$(modinfo -k "$KV" -n btrfs 2>/dev/null || true)
        echo "BTRFS_KO=$KO"
        [ -n "$KO" ] || exit 0
        echo "BTRFS_SIGNER=$(modinfo -k "$KV" -F signer btrfs 2>/dev/null | head -1)"
        # Any module under the kernel package'"'"'s own tree carries the key the
        # locked-down kernel trusts; out-of-tree kmods land in extra/ or
        # weak-updates/ and are exactly what this compares against.
        REF=$(find "/usr/lib/modules/$KV/kernel" -name "*.ko*" -print 2>/dev/null | head -1)
        [ -n "$REF" ] || exit 0
        echo "REF_KO=$REF"
        echo "REF_SIGNER=$(modinfo -F signer "$REF" 2>/dev/null | head -1)"
    ' 2>/dev/null || true)"
    BTRFS_KO="$(sed -n 's/^BTRFS_KO=//p' <<<"$BTRFS_PROBE")"
    BTRFS_SIGNER="$(sed -n 's/^BTRFS_SIGNER=//p' <<<"$BTRFS_PROBE")"
    REF_SIGNER="$(sed -n 's/^REF_SIGNER=//p' <<<"$BTRFS_PROBE")"
    if [[ -z "$BTRFS_PROBE" ]]; then
        err "  [WARN] btrfs preflight could not inspect $IMAGE — proceeding blind"
    elif [[ -z "$BTRFS_KO" ]]; then
        err "  [FAIL] wootc.filesystem=btrfs but $IMAGE ships no btrfs module for its kernel"
        err "         Phase 2 could not mount a btrfs root; refusing to deploy one."
        exit 1
    elif [[ -n "$BTRFS_SIGNER" && -n "$REF_SIGNER" && "$BTRFS_SIGNER" != "$REF_SIGNER" ]]; then
        err "  [FAIL] wootc.filesystem=btrfs but $BTRFS_KO is an out-of-tree module"
        err "         signed by '$BTRFS_SIGNER', while the kernel's own modules are"
        err "         signed by '$REF_SIGNER'. Under Secure Boot the target kernel"
        err "         rejects it, the btrfs udev readiness gate never clears, and"
        err "         Phase 2 lands in an emergency shell. Refusing to deploy."
        err "         Use an image whose kernel has btrfs in-tree, or enrol the key."
        exit 1
    else
        log "  btrfs preflight: $BTRFS_KO loads under the kernel's own signing key"
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

# Build user JSON if vault provided credentials.
# groups: wheel ONLY. useradd --root consults just the target's /etc/group; on
# EL10-family ostree images (bluefin:lts) video/audio live in /usr/lib/group
# (systemd userdb) and useradd dies with exit 6 "group does not exist" —
# fisherman then aborts the whole install (proven live, run 20260723T0122).
# Modern desktops grant device access via logind session ACLs, so the legacy
# video/audio memberships add nothing; wheel is what admin/sudo needs and is
# present in /etc/group across every supported image family.
USER_JSON=""
if [[ -n "$VAULT_USER" && -n "$VAULT_PASSWORD_HASH" ]]; then
    USER_JSON=",\"user\": { \"username\": \"${VAULT_USER}\", \"password\": \"${VAULT_PASSWORD_HASH}\", \"groups\": [\"wheel\"] }"
fi

RECIPE="/tmp/recipe.json"
cat > "$RECIPE" << EOF
{
  "disk": "${LOOP_DEV}",
  "filesystem": "${FILESYSTEM}",
  "composeFsBackend": $([[ "$COMPOSEFS" == 1 ]] && echo true || echo false),
  "genericImage": $([[ "$GENERIC_IMAGE" == 1 ]] && echo true || echo false),
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

# ── [generic] Early-cpio overlay helpers ─────────────────────────────────────
# Three Phase-2 staging branches (composefs+systemd-boot, generic
# systemd-boot, ostree/grub2 with a target initramfs that cannot be
# regenerated) prepend the same wootc-boot overlay onto the target's own
# initrd. They used to carry three hand-copied variants of this code, and two
# of them looked for ntfs-3g under a /mnt/sysroot that never exists in this
# initramfs — silently falling through to a deployer binary shipped WITHOUT
# its library closure (the exact cross-image soname failure documented in
# docs/agent-lessons.md §8). One implementation, used by all branches.

# stage_wootc_overlay <ovl-dir>
# The attach unit, its wants edge, and the loop script — the minimum that
# makes root.disk appear to the base initrd's ordinary sysroot.mount.
stage_wootc_overlay() {
    local ovl="$1"
    # early_cpio marker: makes lsinitrd/skipcpio recognise this as a leading
    # (early) cpio and skip past it to show the base initrd — honest
    # introspection. Harmless to the kernel (same as microcode).
    : > "$ovl/early_cpio"
    install -D -m0644 /usr/lib/wootc/99wootc-boot/wootc-attach.service \
        "$ovl/usr/lib/systemd/system/wootc-attach.service"
    install -D -m0755 /usr/lib/wootc/99wootc-boot/wootc-attach-loop.sh \
        "$ovl/usr/lib/wootc/wootc-attach-loop.sh"
    mkdir -p "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants"
    ln -sf ../wootc-attach.service \
        "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"
}

# stage_ntfs3g_closure <ovl-dir>
# Stage a userspace NTFS driver into the overlay for kernels without ntfs3.
# Source order matters (agent-lessons §8 — never mix libraries across images):
#   1. the TARGET deployment's own ntfs-3g: the binary plus its
#      libntfs-3g/libfuse from the SAME tree. The rest of its closure (libc,
#      loader) is the base initrd's own — coherent, both come from the image.
#   2. the DEPLOYER's ntfs-3g as a COMPLETE private closure: binary, every
#      ldd-resolved library, and the dynamic loader under
#      /usr/lib/wootc/ntfs3g/, invoked through a wrapper. The target's
#      libraries are never mixed in (measured skew that motivated this:
#      libfuse3.so.4 vs .so.3 — lands, then dies exactly like a missing one).
# Returns 0 when a driver was staged, 1 when none was available (the caller
# decides whether kernel ntfs3 makes that survivable).
stage_ntfs3g_closure() {
    local ovl="$1" d tsrc="" lib nbin ldso=""
    for d in /usr/bin /usr/sbin /bin /sbin; do
        [[ -x "$DEPLOY_ROOT$d/ntfs-3g" ]] && { tsrc="$DEPLOY_ROOT$d/ntfs-3g"; break; }
    done
    if [[ -n "$tsrc" ]]; then
        install -D -m0755 "$tsrc" "$ovl/usr/bin/ntfs-3g"
        # Its NTFS/FUSE libraries from the same tree, symlink chains intact
        # (libntfs-3g.so.N is a link to .so.N.0.0 — both must land). $lib is
        # the path with the deployment prefix stripped, so it doubles as the
        # destination inside the overlay.
        while IFS= read -r lib; do
            mkdir -p "$ovl${lib%/*}" 2>/dev/null || true
            cp -a "$DEPLOY_ROOT$lib" "$ovl${lib%/*}/" 2>/dev/null || true
        done < <(find "$DEPLOY_ROOT/usr/lib64" "$DEPLOY_ROOT/lib64" \
                      "$DEPLOY_ROOT/usr/lib" "$DEPLOY_ROOT/lib" \
                      -maxdepth 1 \( -name 'libntfs-3g*' -o -name 'libfuse*' \) \
                      2>/dev/null | sed "s|^$DEPLOY_ROOT||")
        mkdir -p "$ovl/usr/sbin"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs-3g"
        log "  early-cpio: staged the TARGET's own ntfs-3g (+libs) from the deployment"
        return 0
    fi
    nbin=$(command -v ntfs-3g 2>/dev/null || true)
    if [[ -n "$nbin" ]]; then
        local pdir="usr/lib/wootc/ntfs3g"
        install -D -m0755 "$nbin" "$ovl/$pdir/ntfs-3g"
        # Every ldd-resolved dependency AND the loader (the line without "=>").
        while IFS= read -r lib; do
            [[ -f "$lib" ]] || continue
            install -D -m0755 "$lib" "$ovl/$pdir/${lib##*/}"
            case "$lib" in
                */ld-linux*|*/ld64.so*|*/ld.so*) ldso="${lib##*/}" ;;
            esac
        done < <(ldd "$nbin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}')
        if [[ -z "$ldso" ]]; then
            err "  [FAIL] early-cpio: ldd on the deployer's ntfs-3g surfaced no dynamic loader — cannot build a self-contained closure"
            rm -rf "${ovl:?}/$pdir"
            return 1
        fi
        # PROVE the closure is complete by RUNNING it (ldd reports only the
        # first missing library; execution reports the truth). This is the
        # deployer's own binary on the deployer's own kernel, so it can run
        # here — pinned to the staged loader + staged libs only.
        if ! "$ovl/$pdir/$ldso" --library-path "$ovl/$pdir" "$ovl/$pdir/ntfs-3g" --version >/dev/null 2>&1; then
            err "  [FAIL] early-cpio: staged ntfs-3g closure does not execute against its own libraries"
            rm -rf "${ovl:?}/$pdir"
            return 1
        fi
        # The wrapper the attach hook's mount_host() will find as `ntfs-3g`.
        # Needs only a POSIX sh, which the hook (bash) already requires.
        mkdir -p "$ovl/usr/bin" "$ovl/usr/sbin"
        cat > "$ovl/usr/bin/ntfs-3g" <<NTFSWRAP
#!/bin/sh
exec /$pdir/$ldso --library-path /$pdir /$pdir/ntfs-3g "\$@"
NTFSWRAP
        chmod 0755 "$ovl/usr/bin/ntfs-3g"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs-3g"
        log "  early-cpio: staged the DEPLOYER's ntfs-3g as a private closure (loader=$ldso, exec-verified)"
        return 0
    fi
    return 1
}

# stage_qemu_ga_into_target
# Give the deployed system a guest agent the E2E control plane can reach, on
# images that ship none.
#
# The previous implementation wrote the binary to $DEPLOY_ROOT/usr/bin/qemu-ga
# and the unit to $DEPLOY_ROOT/usr/lib/systemd/system/. On a composefs
# deployment both writes SUCCEED and both are INVISIBLE at runtime: the sealed
# .cfs image is mounted over /usr, so the deployment directory's own /usr is
# shadowed. dakota booted Phase 2 all the way to a login prompt carrying
# `systemd.wants=qemu-guest-agent.service`, with no such unit anywhere in the
# booted system, while the deployer logged "[PASS] qemu-guest-agent installed
# from deployer into target" (run 30703716667). The harness then reported
# "the Phase-2 guest agent never answered". A PASS derived from a write
# landing rather than from the runtime seeing it.
#
# /etc and /var ARE the runtime ones under composefs. Ground truth from that
# same boot: wootc-passthrough.service (installed into $DEPLOY_ROOT/etc with
# ExecStart=/var/usrlocal/bin/wootc-mount-user-dirs) started and finished.
# So stage into those, never into /usr:
#   binary + full ldd closure  → /var/usrlocal/lib/wootc-qga/
#   wrapper                    → /var/usrlocal/bin/qemu-ga
#   unit + wants symlink       → /etc/systemd/system/
#
# The closure is the agent-lessons §8 rule that stage_ntfs3g_closure follows:
# never mix the deployer's binary with the target's libraries: ship every
# ldd-resolved library plus the loader, invoke through the staged loader, and
# PROVE it by running it (ldd reports only the first missing library).
#
# The unit is named wootc-qemu-ga.service and gated on
# ConditionPathExists=!/usr/bin/qemu-ga so it can never displace an agent the
# image ships itself. That condition is evaluated in the booted real root,
# the only place where "does this image have qemu-ga" is observable. A chroot
# probe here cannot answer it: under composefs $DEPLOY_ROOT/usr is empty, so
# the probe reports "absent" for every image, including ones that have it.
stage_qemu_ga_into_target() {
    local src pdir="var/usrlocal/lib/wootc-qga" lib ldso=""
    src=$(command -v qemu-ga 2>/dev/null || true)
    if [[ -z "$src" ]]; then
        err "  [WARN] qga: the deployer initramfs carries no qemu-ga to stage"
        return 1
    fi
    rm -rf "${DEPLOY_ROOT:?}/$pdir"
    install -D -m0755 "$src" "$DEPLOY_ROOT/$pdir/qemu-ga"
    while IFS= read -r lib; do
        [[ -f "$lib" ]] || continue
        install -D -m0755 "$lib" "$DEPLOY_ROOT/$pdir/${lib##*/}"
        case "$lib" in
            */ld-linux*|*/ld64.so*|*/ld.so*) ldso="${lib##*/}" ;;
        esac
    done < <(ldd "$src" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}')
    if [[ -z "$ldso" ]]; then
        err "  [FAIL] qga: ldd on the deployer's qemu-ga surfaced no dynamic loader; cannot build a self-contained closure"
        rm -rf "${DEPLOY_ROOT:?}/$pdir"
        return 1
    fi
    if ! "$DEPLOY_ROOT/$pdir/$ldso" --library-path "$DEPLOY_ROOT/$pdir" \
            "$DEPLOY_ROOT/$pdir/qemu-ga" --version >/dev/null 2>&1; then
        err "  [FAIL] qga: staged qemu-ga closure does not execute against its own libraries"
        rm -rf "${DEPLOY_ROOT:?}/$pdir"
        return 1
    fi
    install -d -m0755 "$DEPLOY_ROOT/var/usrlocal/bin"
    cat > "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga" <<QGAWRAP
#!/bin/sh
exec /$pdir/$ldso --library-path /$pdir /$pdir/qemu-ga "\$@"
QGAWRAP
    chmod 0755 "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga"
    install -d -m0755 "$DEPLOY_ROOT/etc/systemd/system" \
                      "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
    cat > "$DEPLOY_ROOT/etc/systemd/system/wootc-qemu-ga.service" <<'QGAUNIT'
[Unit]
Description=QEMU Guest Agent (staged by the wootc deployer)
Documentation=https://github.com/tuna-os/wootc
# Never displace an agent the image ships itself.
ConditionPathExists=!/usr/bin/qemu-ga
ConditionPathExists=!/usr/sbin/qemu-ga
ConditionPathExists=/var/usrlocal/bin/qemu-ga
After=local-fs.target
# The virtio-serial port can appear after this unit is first tried; Restart
# handles that, so the default 5-starts-in-10s limit must not give up on it.
StartLimitIntervalSec=0

[Service]
# A breadcrumb on the console: the serial log is the only Phase-2 evidence the
# harness can read when the agent is the thing that is broken, so "the unit was
# tried" must be distinguishable from "the unit does not exist".
ExecStartPre=/bin/sh -c 'echo "wootc: starting staged qemu-ga" > /dev/kmsg'
ExecStart=/var/usrlocal/bin/qemu-ga --method=virtio-serial --path=/dev/virtio-ports/org.qemu.guest_agent.0
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
QGAUNIT
    ln -sf ../wootc-qemu-ga.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service"
    # Assert the runtime view, not the writes: the wants symlink must resolve
    # to the unit, and the unit's ExecStart must exist under the deployment.
    if [[ ! -e "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service" ]]; then
        err "  [FAIL] qga: multi-user.target.wants/wootc-qemu-ga.service dangles; the agent would never start"
        return 1
    fi
    if [[ ! -x "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga" ]]; then
        err "  [FAIL] qga: /var/usrlocal/bin/qemu-ga is not executable in the deployment"
        return 1
    fi
    log "  [PASS] fallback qemu-ga staged (loader=$ldso, exec-verified) at /var/usrlocal/bin/qemu-ga, enabled as wootc-qemu-ga.service"
    return 0
}

# ── initramfs introspection ────────────────────────────────────────────────
# An initramfs image is a CONCATENATION, not one archive: zero or more
# UNCOMPRESSED early-cpio segments (CPU microcode, ACPI overrides) followed by
# the compressed main archive. `cpio -it` stops at the first TRAILER!!!, so on
# a Fedora/bootc image it lists the microcode segment — a handful of paths
# under kernel/x86/microcode — and exits 0. That non-empty listing was then
# read as proof that the initrd shipped no bash/losetup/udevadm/mount, and it
# killed every dakota run at the Phase-2 gate (run 30700616717) on an initrd
# that ships all four. Missing ALL FOUR is not a thing a bootable initrd does;
# the listing was of the wrong segment. Walk the chain instead.

# _initrd_segment_end <image> <offset>
# Echo the offset just past the newc cpio archive that starts at <offset>
# (i.e. past its TRAILER!!! member). Fails if no archive starts there.
_initrd_segment_end() {
    local img="$1" off="$2" hdr namesize filesize name
    while :; do
        hdr=$(dd if="$img" bs=1 skip="$off" count=110 status=none 2>/dev/null || true)
        # 6-byte magic + 13 eight-digit hex fields = 110 ASCII bytes.
        [[ "$hdr" =~ ^070701[0-9a-fA-F]{104}$ ]] || return 1
        filesize=$((16#${hdr:54:8}))
        namesize=$((16#${hdr:94:8}))
        name=$(dd if="$img" bs=1 skip=$((off + 110)) count="$namesize" status=none 2>/dev/null | tr -d '\0')
        # Header+name and then the file data are each padded to 4 bytes.
        off=$(( (off + 110 + namesize + 3) / 4 * 4 ))
        off=$(( (off + filesize + 3) / 4 * 4 ))
        if [[ "$name" == "TRAILER!!!" ]]; then
            printf '%s' "$off"
            return 0
        fi
    done
}

# _initrd_skip_padding <image> <offset> <size>
# Early-cpio segments are zero-padded (to 4 or to 512 bytes) before the next
# segment begins. Echo the first non-padding offset, bounded so a corrupt
# image cannot spin here.
_initrd_skip_padding() {
    local img="$1" off="$2" size="$3" limit nonzero
    limit=$(( off + 4096 ))
    (( limit > size )) && limit=$size
    while (( off < limit )); do
        nonzero=$(dd if="$img" bs=1 skip="$off" count=4 status=none 2>/dev/null | tr -d '\0' | wc -c)
        if (( nonzero > 0 )); then
            break
        fi
        off=$(( off + 4 ))
    done
    printf '%s' "$off"
}

# list_initrd_members <image>
# Echo the member names of EVERY segment of an initramfs image. Empty output
# means "unlistable here" (unknown compression), never "the initrd is empty".
list_initrd_members() {
    local img="$1" size off=0 seg dec end
    size=$(wc -c < "$img" 2>/dev/null || echo 0)
    while (( off < size )); do
        if [[ $(dd if="$img" bs=1 skip="$off" count=6 status=none 2>/dev/null || true) == 070701 ]]; then
            # An uncompressed segment: list it, then step over it.
            seg=$(tail -c +$((off + 1)) "$img" 2>/dev/null | cpio -it --quiet 2>/dev/null || true)
            [[ -n "$seg" ]] && printf '%s\n' "$seg"
            end=$(_initrd_segment_end "$img" "$off") || break
            off=$(_initrd_skip_padding "$img" "$end" "$size")
            continue
        fi
        # Anything else is the compressed main archive, and it is last.
        for dec in "zstd -qdc" "gzip -dc" "xz -dc" "lz4 -dc" "bzip2 -dc" "lzop -dc"; do
            seg=$(tail -c +$((off + 1)) "$img" 2>/dev/null | $dec 2>/dev/null | cpio -it --quiet 2>/dev/null || true)
            if [[ -n "$seg" ]]; then
                printf '%s\n' "$seg"
                break
            fi
        done
        break
    done
    return 0
}

# build_phase2_initrd <ovl-dir> <base-initrd> <out-path>
# Pack the overlay ahead of the base initrd and VERIFY the result by
# inspection — "the concatenated file is non-empty" validated nothing (a
# hookless or interpreter-less initramfs is non-empty too, and costs a full
# VM run to diagnose). Fails closed on a defective overlay; base-initrd
# introspection is best-effort (its compression varies by image) and only
# fails when a successful listing PROVES a required piece missing.
build_phase2_initrd() {
    local ovl="$1" base="$2" out="$3"
    # The overlay must be verifiably complete BEFORE packing: unit file,
    # wants edge (a dangling wants is a proven silent no-op), executable hook.
    if [[ ! -f "$ovl/usr/lib/systemd/system/wootc-attach.service" ]] || \
       [[ ! -L "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service" ]] || \
       [[ ! -x "$ovl/usr/lib/wootc/wootc-attach-loop.sh" ]]; then
        err "  [FAIL] early-cpio overlay is incomplete (unit/wants/hook) — refusing to build a Phase-2 initrd that cannot attach root.disk"
        return 1
    fi
    if ! ( cd "$ovl" && find . | cpio -o -H newc --quiet ) > "$ovl.cpio" || \
       ! cat "$ovl.cpio" "$base" > "$out" || [[ ! -s "$out" ]]; then
        rm -f "$ovl.cpio"
        err "  [FAIL] early-cpio: cpio prepend failed — Phase-2 initrd would be hookless"
        return 1
    fi
    rm -f "$ovl.cpio"
    # The overlay supplies unit+hook (+ possibly ntfs-3g); everything else the
    # hook needs at runtime must come from the BASE initrd: its interpreter
    # (bash — the hook's shebang), losetup, udevadm, mount. Listing walks every
    # segment of the image; an empty result just means "unverifiable here",
    # which must WARN, not fail a deploy that may be good.
    local listing=""
    listing=$(list_initrd_members "$base")
    if [[ -z "$listing" ]]; then
        log "  [WARN] early-cpio: could not list the base initrd (unknown compression) — interpreter/tool presence unverified"
        return 0
    fi
    # Only a listing that actually holds a root filesystem can prove a tool
    # absent. A microcode-only early-cpio listing has no bin/ tree at all, and
    # calling that proof is how a good initrd got declared unbootable.
    if ! grep -qE '(^|/)(usr/)?s?bin/' <<<"$listing"; then
        log "  [WARN] early-cpio: the base initrd listing holds no bin/ tree (early-cpio segment only?) — tool presence unverified"
        return 0
    fi
    local missing=() tool found
    for tool in bash losetup udevadm mount; do
        found=0
        grep -qE "(^|/)(usr/)?s?bin/$tool$" <<<"$listing" && found=1
        # busybox-style initrds provide tools as applet symlinks with the
        # same basename; the grep above already matches those. A systemd
        # UKI initrd without a shell at all is the real failure mode here.
        [[ "$found" == 1 ]] || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        err "  [FAIL] the target's base initrd lacks: ${missing[*]} — the wootc-attach hook cannot run in Phase 2"
        err "         (every segment listed and a bin/ tree was found, so this is proof, not a probe failure; the image's initrd must ship these or the hook must be rewritten against what it ships)"
        return 1
    fi
    log "  early-cpio: base initrd verified (bash/losetup/udevadm/mount present)"
    return 0
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
# Wait for the LAST partition, not for "p3". An ostree install lays down
# ESP/boot/root (p3 = root); a composefs-native install lays down only ESP+root,
# so p3 never appears and this loop burned its full 20s on every dakota run
# before warning about nodes that were never going to exist. Confirmed from the
# partition table this warning now prints: /dev/loop1p1 = 2G EFI System,
# /dev/loop1p2 = 33G Linux root, and nothing else (run 30234854504).
for _ in {1..20}; do
    udevadm settle --timeout=1 2>/dev/null || true
    [[ -b "${VERIFY_LOOP}p2" ]] && break
    sleep 1
done
if [[ ! -b "${VERIFY_LOOP}p2" ]]; then
    # Say WHICH nodes are missing. This loop only ever probed p3, but reported
    # "partition nodes did not appear" — two very different situations wearing
    # one message: (a) the partition scan produced nothing at all, or (b) it
    # worked and this image simply does not put root on p3. A composefs-native
    # install need not share the ostree layout. dakota (20260726T234428Z) died
    # here after fisherman had written 34 GB, and the log could not tell which.
    err "  [WARN] ${VERIFY_LOOP}p2 did not appear for verification (no partitions at all?)"
    err "  [WARN] partition nodes present: $(ls -1d "${VERIFY_LOOP}"p* 2>/dev/null | tr '\n' ' ' || true)"
    err "  [WARN] partition table as the kernel sees it:"
    sfdisk -l "$VERIFY_LOOP" 2>&1 | sed 's/^/    /' >&2 || true
fi

# Fisherman closes its mapper before returning. Re-open an encrypted root for
# post-install verification; TPM modes use the token enrolled by fisherman,
# while passphrase-only mode feeds the key over stdin (never argv or logs).
# The LAST partition is root in BOTH layouts: ostree lays down ESP/boot/root
# (p3), composefs-native lays down ESP/root (p2). Hardcoding p3 meant an
# encrypted composefs root was never opened here at all.
shopt -s nullglob
_verify_parts=("${VERIFY_LOOP}"p*)
shopt -u nullglob
VERIFY_ROOT_DEVICE="${VERIFY_LOOP}p2"
(( ${#_verify_parts[@]} > 0 )) && VERIFY_ROOT_DEVICE="${_verify_parts[${#_verify_parts[@]}-1]}"
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
        # A composefs-native install has NEITHER /ostree/deploy NOR a top-level
        # /etc/os-release — its tree lives under /state/deploy/<hash>/ (the same
        # path fisherman's composefs useradd targets). Without this arm the probe
        # found no root, skipped the ENTIRE verification+Phase-2 staging block
        # ("Could not mount installed root for verification"), and Phase 2 had no
        # kernel to boot: the firmware loaded the deployer's grub and fell
        # straight back to Windows (dakota GH matrix 20260725T0208).
        if [[ -d /mnt/verify/ostree/deploy || -f /mnt/verify/etc/os-release || -d /mnt/verify/state/deploy ]]; then
            VERIFY_ROOT="$p"
            break
        fi
        umount /mnt/verify 2>/dev/null || true
    fi
done

if [[ -n "$VERIFY_ROOT" ]]; then
    log "Mounted installed system root at ${VERIFY_ROOT} for verification"

    # Resolve the OS tree: the ostree deployment dir when present, the
    # filesystem root otherwise (classic layout).
    shopt -s nullglob
    deployments=(/mnt/verify/ostree/deploy/*/deploy/*.0)
    # composefs-native: the OS tree is /state/deploy/<hash>/ with no ostree/
    # hierarchy. Without this the root resolved to /mnt/verify (the sysroot),
    # so every post-install write and the Phase-2 staging looked at an empty
    # tree instead of the deployment.
    cfs_deployments=(/mnt/verify/state/deploy/*/)
    shopt -u nullglob
    if (( ${#deployments[@]} > 0 )); then
        DEPLOY_ROOT="${deployments[0]}"
        log "  ostree deployment: ${DEPLOY_ROOT#/mnt/verify}"
    elif (( ${#cfs_deployments[@]} > 0 )); then
        DEPLOY_ROOT="${cfs_deployments[0]%/}"
        log "  composefs deployment: ${DEPLOY_ROOT#/mnt/verify}"
    else
        DEPLOY_ROOT="/mnt/verify"
    fi

    # OSTree keeps the persistent /var at
    #   /ostree/deploy/<stateroot>/var
    # and bind-mounts it over the deployment's own /var at boot. Writing via
    # $DEPLOY_ROOT/usr/local (a ../var/usrlocal symlink) without that bind puts
    # files in deployment-local /var, where the real boot immediately hides
    # them. Proven on himachal: wootc-go-native existed at
    # deploy/<checksum>.0/var/usrlocal/bin but was command-not-found in Phase 2.
    # Recreate the runtime view before any chroot or post-install writes so
    # /usr/local, /var/tmp, and /var/lib/wootc all target persistent state.
    DEPLOY_VAR_BOUND=false
    if [[ "$DEPLOY_ROOT" == *"/ostree/deploy/"* ]]; then
        DEPLOY_PARENT="${DEPLOY_ROOT%/*}"
        OSTREE_STATEROOT="${DEPLOY_PARENT%/*}"
        OSTREE_VAR_ROOT="$OSTREE_STATEROOT/var"
        install -d "$OSTREE_VAR_ROOT" "$DEPLOY_ROOT/var"
        mount --bind "$OSTREE_VAR_ROOT" "$DEPLOY_ROOT/var"
        DEPLOY_VAR_BOUND=true
        log "  [PASS] OSTree stateroot /var bound into deployment for post-install writes"
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
            DEPLOY_PARENT="${DEPLOY_ROOT%/*}"
            OSTREE_STATEROOT="${DEPLOY_PARENT%/*}"
            SSH_ROOTHOME="$OSTREE_STATEROOT/var/roothome"
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
    # composefs+systemd-boot has NO separate /boot partition: p1 is the ESP and
    # p2 IS the root, so the p2-as-/boot mount above simply mounted the root a
    # second time (proven by the failure dump: "boot contents: ... composefs
    # state var" — the sysroot, which even contains boot/ itself). The kernels
    # and BLS entries live on the ESP. Mount it at boot/efi, which is exactly
    # where the BLS_DIR fallback below and the composefs Phase-2 staging further
    # down (TESP="$DEPLOY_ROOT/boot/efi") both already look. Keeping the p2 mount
    # costs nothing and keeps $DEPLOY_ROOT/boot writable for the stage marker.
    if [[ ! -d "$DEPLOY_ROOT/boot/loader/entries" ]]; then
        VERIFY_ESP_DEV="${VERIFY_LOOP}p1"
        if [[ -b "$VERIFY_ESP_DEV" ]] && ! mountpoint -q "$DEPLOY_ROOT/boot/efi"; then
            mkdir -p "$DEPLOY_ROOT/boot/efi"
            if mount -t vfat "$VERIFY_ESP_DEV" "$DEPLOY_ROOT/boot/efi" 2>/dev/null; then
                ESP_BOUND_AT="$DEPLOY_ROOT/boot/efi"
                log "  composefs: mounted target ESP ${VERIFY_ESP_DEV} at boot/efi"
            else
                err "  [WARN] could not mount target ESP ${VERIFY_ESP_DEV} at boot/efi"
            fi
        fi
    fi

    # Where the installed system keeps its BLS entries depends on the backend:
    #   ostree/grub2        → <deploy>/boot/loader/entries
    #   composefs + systemd → <deploy>/boot/efi/loader/entries  (the target ESP)
    # This block hardcoded the ostree path and exited 1 on composefs ("no BLS
    # entries found on installed /boot", dakota GH matrix 20260725T0330) —
    # killing the deploy BEFORE the composefs Phase-2 staging further down, which
    # already knew the boot/efi location. Resolve once and reuse.
    shopt -s nullglob
    BLS_DIR="$DEPLOY_ROOT/boot/loader/entries"
    BLS_ENTRIES=("$BLS_DIR"/*.conf)
    if (( ${#BLS_ENTRIES[@]} == 0 )); then
        BLS_DIR="$DEPLOY_ROOT/boot/efi/loader/entries"
        BLS_ENTRIES=("$BLS_DIR"/*.conf)
        (( ${#BLS_ENTRIES[@]} > 0 )) && log "  composefs: BLS entries under ${BLS_DIR#"$DEPLOY_ROOT"}"
    fi
    if (( ${#BLS_ENTRIES[@]} == 0 )); then
        err "  [FAIL] no BLS entries found on installed /boot (checked boot/loader/entries and boot/efi/loader/entries)"
        err "  boot contents: $(ls -A "$DEPLOY_ROOT/boot" 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
    for entry in "${BLS_ENTRIES[@]}"; do
        grep -q 'wootc.host_uuid=' "$entry" || \
            sed -i '/^options / s|$| wootc.host_uuid='"$HOST_UUID"' loop=/wootc/disks/root.disk|' "$entry"
    done
    shopt -u nullglob

    # Regenerate the initramfs with the module and BLS arguments in place.
    # bootc deployments may leave the mutable /var skeleton empty until first
    # boot. dracut resolves its default TMPDIR before doing any work and aborts
    # with "Invalid tmpdir '/var/tmp'" if that directory is absent. Prepare the
    # standard sticky temporary directories explicitly in the chroot.
    # A composefs-native deployment is a READ-ONLY image tree with no dev/proc/sys
    # directories, and the branch below performs NO chroot for that layout — so
    # preparing a chroot here is both impossible and pointless. It was fatal:
    # `mount --bind` failed with "mount point does not exist" and set -e killed
    # the deployer outright at t=659s, after which the harness sat through its
    # entire 90-minute budget waiting for a process that had already died
    # (bluefin-dakota-win11pro, run 30234854504 — every heartbeat in that run
    # reads fisherman=absent because the install had already finished).
    #
    # Keyed on the deployment SHAPE as well as $COMPOSEFS, so a probe that fell
    # back to ostree cannot drag a composefs tree down this path anyway.
    if [[ "$COMPOSEFS" == 1 || "$DEPLOY_ROOT" == */state/deploy/* ]]; then
        log "  verify: composefs deployment — skipping chroot preparation (this layout regenerates no initramfs here)"
    else
        install -d -m 1777 "$DEPLOY_ROOT/tmp"
        mkdir -p "$DEPLOY_ROOT/var/tmp"
        chmod 1777 "$DEPLOY_ROOT/var/tmp"
        # ostree keeps the live initramfs on the boot partition under
        # /boot/ostree/<stateroot>-<csum>/ — regenerate that exact file.
        for fs in dev proc sys; do
            mkdir -p "$DEPLOY_ROOT/$fs" 2>/dev/null || true
            mount --bind "/$fs" "$DEPLOY_ROOT/$fs" || {
                err "  [FAIL] cannot bind /$fs into $DEPLOY_ROOT — deployment root is read-only or missing $fs"
                exit 1
            }
        done
    fi
    # Pick the module tree that owns the BOOTABLE kernel (has vmlinuz), highest
    # version if several. `ls | head -1` chose 6.12.0-225 over -233 in
    # bluefin:lts, where -225 is a stripped leftover (no vmlinuz) — dracut then
    # built a 225-module initramfs that BOOTED under the 233 kernel, so not one
    # storage driver could load: 60s of "Present devices: none" and an
    # emergency shell (run 20260723T0016). A mismatched initramfs fails with
    # no error message anywhere — guard the pairing, not just the pick.
    KVER=$(for d in "$DEPLOY_ROOT"/usr/lib/modules/*/; do
        [[ -f "$d/vmlinuz" ]] && basename "$d"
    done | sort -V | tail -1 || true)
    # `|| true` is load-bearing under `set -o pipefail`. A composefs deployment's
    # /usr/lib/modules is EMPTY or absent (its content lives in the .ostree.cfs),
    # so `ls` fails, the pipeline fails, and as the last command of an `||` list
    # that aborts the deployer under set -e — with NO message. dakota died
    # exactly here: the log ends at "skipping chroot preparation" and the next
    # line is the exit-1 post-mortem (himachal 20260727T114614Z).
    # An empty KVER is FINE for composefs: the branch below needs both a KVER
    # and ostree initramfs images, and composefs regenerates nothing here.
    [[ -n "$KVER" ]] || KVER=$(ls "$DEPLOY_ROOT/usr/lib/modules" 2>/dev/null | sort -V | tail -1 || true)
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
        # Explicitly add BOTH sides of Phase-2 root setup. wootc-boot exposes
        # root.disk as the root=UUID device; ostree-prepare-root then turns that
        # repository filesystem into the selected deployment from ostree=.
        # In a foreign chroot dracut did not auto-select 50ostree, even though
        # the target image contained it. The resulting initramfs mounted
        # /sysroot successfully and then failed initrd-switch-root because it
        # had no ostree-prepare-root at all (himachal run
        # 20260721T062450Z-himachal-4126879). The archive guard below enforces
        # both modules' observable boot machinery.
        # nvmf/systemd-cryptsetup are auto-pulled but depend on the network/dm
        # modules we omit; omit them too so they don't error the run.
        DRACUT_OMIT="plymouth lvm mdraid dm multipath iscsi nfs cifs fcoe fcoe-uefi resume rescue network network-legacy network-manager kernel-network-modules cellular qemu-net memstrack nvmf nvdimm"
        # clevis (+ its pins) is a crypt dependent: images that ship it
        # (bonito) make dracut abort "Module 'clevis' depends on module
        # 'crypt', which can't be installed" the moment crypt is omitted
        # (GH bonito repro 20260724T0709). Phase 2 loop-attaches an
        # unencrypted root — no network-bound encryption — so drop the whole
        # clevis family alongside crypt.
        [[ "$LUKS_TYPE" == "none" ]] && DRACUT_OMIT="$DRACUT_OMIT crypt systemd-cryptsetup clevis clevis-pin-null clevis-pin-sss clevis-pin-tang clevis-pin-tpm2"
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
        # Fallback: the DEPLOYER always ships ntfs-3g (see its Containerfile)
        # and has just used it to mount the host NTFS. If the deployment has
        # none — the injection step failed, and EL kernels carry no ntfs3 —
        # copy ours in rather than building a Phase-2 initramfs that provably
        # cannot mount the volume holding root.disk.
        #
        # el10-gnome-win10pro (20260727T082625Z) deployed "successfully", then
        # Phase 2 emergency-shelled with:
        #   wootc: EXIT: cannot mount host NTFS rw (no ntfs3, no ntfs-3g)
        #   /proc/filesystems ntfs3=0 ntfs-3g=no
        # 91 minutes to discover something knowable at deploy time.
        if (( ${#NTFS_BINS[@]} == 0 )); then
            _ntfs_src="$(command -v ntfs-3g 2>/dev/null || true)"
            if [[ -n "$_ntfs_src" && -x "$_ntfs_src" ]]; then
                mkdir -p "$DEPLOY_ROOT/usr/local/sbin"
                if cp -a "$_ntfs_src" "$DEPLOY_ROOT/usr/local/sbin/ntfs-3g" 2>/dev/null; then
                    # Carry its shared libraries too: dracut resolves an
                    # installed binary's deps INSIDE the chroot, so a bare copy
                    # would be installed and then fail to run for want of
                    # libntfs-3g.
                    ldd "$_ntfs_src" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | \
                    while read -r _lib; do
                        [[ -e "$DEPLOY_ROOT$_lib" ]] && continue
                        mkdir -p "$DEPLOY_ROOT${_lib%/*}" 2>/dev/null || continue
                        cp -a "$_lib" "$DEPLOY_ROOT$_lib" 2>/dev/null || true
                    done
                    NTFS_BINS+=("/usr/local/sbin/ntfs-3g")
                    log "  Injected the deployer's own ntfs-3g into the deployment (the image had none)"
                fi
            fi
        fi

        # Fail CLOSED. Without an NTFS driver Phase 2 cannot reach root.disk, so
        # deploying is guaranteed to end in an emergency shell. Say so now.
        if (( ${#NTFS_BINS[@]} == 0 )) && \
           ! find "$DEPLOY_ROOT/usr/lib/modules/$KVER" -name 'ntfs3.ko*' -print -quit 2>/dev/null | grep -q .; then
            err "  [FAIL] no NTFS driver for Phase 2: the image has no ntfs-3g and kernel $KVER has no ntfs3"
            err "         Phase 2 could not mount the Windows volume that holds root.disk."
            err "         Refusing to finish a deployment that cannot boot."
            exit 1
        fi

        DRACUT_INSTALL_ARGS=()
        if (( ${#NTFS_BINS[@]} > 0 )); then
            DRACUT_INSTALL_ARGS=(--install "${NTFS_BINS[*]}")
            log "  Including userspace NTFS driver in Phase-2 initramfs: ${NTFS_BINS[*]}"
        else
            log "  [WARN] no ntfs-3g in the deployment — Phase-2 relies on a kernel ntfs3"
        fi
        # btrfs root (#35): udev's 64-btrfs.rules keeps every btrfs partition
        # SYSTEMD_READY=0 until the btrfs module has it registered, so the
        # root=UUID device unit never activates if btrfs.ko is not loaded when
        # the attach's partition events land — sysroot.mount then times out
        # with the UUID sitting right there in by-uuid. The attach hook may
        # not modprobe (Secure Boot lockdown lesson), so load it the
        # systemd-native way: a modules-load.d entry baked into the initramfs;
        # systemd-modules-load runs at initrd sysinit, dependency-resolved,
        # long before wootc-attach.service.
        DRACUT_INCLUDE_ARGS=()
        if [[ "$FILESYSTEM" == btrfs ]]; then
            # Under $DEPLOY_ROOT/run (same trick as wootc-nofw): dracut runs
            # chrooted, so the path handed to --include must exist inside it.
            mkdir -p "$DEPLOY_ROOT/run/wootc-btrfs-inc/usr/lib/modules-load.d"
            echo btrfs > "$DEPLOY_ROOT/run/wootc-btrfs-inc/usr/lib/modules-load.d/wootc-btrfs.conf"
            DRACUT_INCLUDE_ARGS=(--include /run/wootc-btrfs-inc /)
            log "  btrfs root: baking modules-load.d/wootc-btrfs.conf into the Phase-2 initramfs (#35)"
        fi
        # BOUNDED. An unbounded chroot dracut is a prime suspect for the
        # 31-minute silent hang: it writes nothing to the journal, so a block
        # here looks exactly like a dead deployer. A regen legitimately takes a
        # few minutes; 15 is generous and still finite.
        log "  verify: regenerating Phase-2 initramfs (dracut, up to 15m)"
        set +e
        timeout 900 chroot "$DEPLOY_ROOT" dracut --force --no-hostonly \
            --add "ostree wootc-boot" \
            "${DRACUT_INSTALL_ARGS[@]}" \
            "${DRACUT_INCLUDE_ARGS[@]}" \
            --fwdir /run/wootc-nofw \
            --omit "$DRACUT_OMIT" \
            "$INITRD_CHROOT_PATH" "$KVER" > /tmp/dracut-regen.log 2>&1
        REGEN_RC=$?
        set -e
        # Route dracut's own words through the logger: bare stderr reaches
        # only the serial console, which the harness does not surface and CI
        # truncates — three separate regen failures (LUKS take 6, bonito
        # 20260724T0132) reported nothing but "exit=1". Prefixed lines land
        # in the persistent deployer.log too.
        while IFS= read -r dline; do err "  dracut: $dline"; done \
            < <(tail -25 /tmp/dracut-regen.log 2>/dev/null)
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
        # Add ostree as well: attachment without prepare-root still leaves
        # systemd trying to switch into the repository's top level.
        if [[ "$COMPOSEFS" == 1 ]]; then
            # composefs-native: do NOT regenerate here. The deployment's
            # /usr/lib/modules is EMPTY (its content lives in the .ostree.cfs),
            # so a chroot dracut has no modules to build from — it grinds and
            # cannot produce a usable initramfs. dakota burned the entire 90-min
            # deploy budget at ~62% CPU with a silent serial doing exactly this
            # (GH run 30143688589), timing out before it ever reached the ESP
            # staging. The composefs Phase-2 path instead PREPENDS an early cpio
            # carrying wootc-attach.service + the loop script onto the target's
            # own UKI initrd (see the composefs staging further down), which is
            # why no regen is needed at all.
            log "  verify: composefs-native → skipping dracut regen (Phase 2 gets an early-cpio overlay instead)"
        else
            log "  verify: regenerating ALL initramfses WITH ostree+wootc-boot (dracut, up to 15m)"
            if ! timeout 900 chroot "$DEPLOY_ROOT" dracut --force --regenerate-all --add "ostree wootc-boot"; then
                err "  [FAIL] dracut --regenerate-all failed or timed out"
                exit 1
            fi
            log "  verify: regenerate-all complete"
        fi
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
            | grep -cE 'initrd-root-device.target.wants/wootc-attach.service' || true)
        log "  guard: lsinitrd listed $GUARD_ENTRIES entries, wootc-attach-loop matches=$GUARD_HITS"
        # The wants symlink alone is NOT enough: it can dangle. Proven the hard
        # way — the symlink was present but usr/lib/systemd/system/
        # wootc-attach.service was ABSENT (the deployer initramfs never staged
        # the unit file), so systemd had no unit to start and root.disk never
        # attached. Require the actual UNIT FILE too, matched at end-of-line so a
        # wants symlink of the same name does not satisfy it.
        GUARD_UNIT=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null \
            | grep -cE 'usr/lib/systemd/system/wootc-attach\.service$' || true)
        log "  guard: wootc-attach.service unit file present=$GUARD_UNIT"
        if [[ "${GUARD_UNIT:-0}" -lt 1 ]]; then
            err "  [FAIL] Phase-2 initramfs has the wants symlink but NO wootc-attach.service unit file (dangling) — root.disk would never attach; aborting deploy"
            exit 1
        fi
        # The UUID becoming mountable proves only that wootc-attach worked.
        # An OSTree deployment additionally requires prepare-root to pivot
        # /sysroot from the repository filesystem to the deployment named by
        # ostree=. Verify the executable and its activation edge in the actual
        # archive, not merely the presence of 50ostree in the deployed image.
        GUARD_OSTREE_BINARY=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null \
            | grep -cE 'usr/lib/ostree/ostree-prepare-root$' || true)
        GUARD_OSTREE_WANTS=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null \
            | grep -cE 'initrd-root-fs.target.wants/ostree-prepare-root.service( ->|$)' || true)
        log "  guard: ostree-prepare-root binary=$GUARD_OSTREE_BINARY wired=$GUARD_OSTREE_WANTS"
        if [[ "${GUARD_OSTREE_BINARY:-0}" -lt 1 || "${GUARD_OSTREE_WANTS:-0}" -lt 1 ]]; then
            err "  [FAIL] Phase-2 initramfs lacks wired ostree-prepare-root — switch-root would target the repository top level; aborting deploy"
            exit 1
        fi
        # With a raw root.disk the hook needs only losetup, which the target
        # image already provides — so there is no staged binary to verify. The
        # hook's own presence is now the whole requirement.
        GUARD_LOSETUP=$(chroot "$DEPLOY_ROOT" lsinitrd "$INITRD_CHROOT_PATH" 2>/dev/null | grep -c 'losetup' || true)
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

    # Unmount only what was actually mounted. The composefs path SKIPS the
    # dev/proc/sys binds (its tree is read-only and it runs no chroot), so an
    # unconditional umount fails there — and umount's exit 32 became the
    # deployer's exit status under set -e, killing it immediately after
    # "[PASS] Phase-2 setup completed with no problems". The deploy had
    # SUCCEEDED; the teardown reported it as a dead deployer, and Phase 2 never
    # got its reboot (himachal 20260727T124314Z).
    for fs in sys proc dev; do
        mountpoint -q "$DEPLOY_ROOT/$fs" 2>/dev/null && umount "$DEPLOY_ROOT/$fs" 2>/dev/null || true
    done

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
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants" \
             "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants" \
             "$DEPLOY_ROOT/etc/qemu"
    ln -sf ../wootc-host-bind.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-host-bind.service"
    # passthrough needs /var mounted (it writes under /home → var/home), so
    # it is wanted by multi-user, NOT local-fs — see the unit's own comment.
    ln -sf ../wootc-passthrough.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-passthrough.service"

    # Enable QGA guest-exec and guest-file RPCs for Phase 3 control plane
    # Fedora packages default FILTER_RPC_ARGS in /etc/sysconfig/qemu-ga to restrict RPCs.
    mkdir -p "$DEPLOY_ROOT/etc/sysconfig" "$DEPLOY_ROOT/etc/qemu"
    cat > "$DEPLOY_ROOT/etc/sysconfig/qemu-ga" <<'QGAEOF'
# Enable all QGA RPCs (guest-exec, guest-file-*) for wootc Phase 3 control plane
FILTER_RPC_ARGS=""
FSFREEZE_HOOK_PATHNAME=/etc/qemu-ga/fsfreeze-hook
QGAEOF
    cat > "$DEPLOY_ROOT/etc/qemu/qemu-ga.conf" <<'QGAEOF'
[main]
daemon=1
blacklist=
block-rpcs=
QGAEOF
    cp "$DEPLOY_ROOT/etc/qemu/qemu-ga.conf" "$DEPLOY_ROOT/etc/qemu-ga.conf" 2>/dev/null || true

    # A fallback guest agent for images that ship none, staged where the
    # runtime can actually see it. See stage_qemu_ga_into_target.
    if ! stage_qemu_ga_into_target; then
        err "  [WARN] no fallback qemu-ga staged; Phase 2 is reachable only if the image ships its own agent"
    fi

    # Set SELinux to permissive mode so Phase 3 QGA & User Data Bridge are not blocked by virt_qemu_ga_t
    if [[ -f "$DEPLOY_ROOT/etc/selinux/config" ]]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$DEPLOY_ROOT/etc/selinux/config" 2>/dev/null || true
        log "  [PASS] SELinux configured to permissive in /etc/selinux/config"
    fi
    # ostree images intentionally ship /usr/local as ../var/usrlocal, while a
    # fresh bootc deployment may not create the mutable backing directory until
    # first boot. Without it every install to /usr/local/bin fails through the
    # dangling symlink.
    install -d -m755 "$DEPLOY_ROOT/var/usrlocal/bin"
    install -m755 /usr/lib/wootc/migration/wootc-mount-user-dirs \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-mount-user-dirs"
    install -m755 /usr/lib/wootc/migration/wootc-umount-user-dirs \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-umount-user-dirs"
    # Extra bridge categories (SPEC §4.1–4.2): Steam, browser import, and
    # the stage-4 folder conversion used by the migration dashboard.
    install -m755 /usr/lib/wootc/migration/wootc-steam-bridge \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-steam-bridge"
    install -m755 /usr/lib/wootc/migration/wootc-import-browser \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-import-browser"
    install -m755 /usr/lib/wootc/migration/wootc-convert-dir \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-convert-dir"
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
    mig_opt 755 wootc-import     "$DEPLOY_ROOT/var/usrlocal/bin/wootc-import"
    mig_opt 755 wootc-import-gui "$DEPLOY_ROOT/var/usrlocal/bin/wootc-import-gui"
    mig_opt 644 wootc-import.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-import.desktop"
    # Migration chooser (§4.6): discover everything migratable, default-on, opt-out.
    mig_opt 755 wootc-manifest "$DEPLOY_ROOT/var/usrlocal/bin/wootc-manifest"
    mig_opt 755 wootc-manifest-gui "$DEPLOY_ROOT/var/usrlocal/bin/wootc-manifest-gui"
    mig_opt 644 wootc-manifest.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-manifest.desktop"
    # Identity prefill/copy (§4.6): account name + picture (never the password).
    mig_opt 755 wootc-identity "$DEPLOY_ROOT/var/usrlocal/bin/wootc-identity"
    # Account setup screen: pre-fills the identity, asks for the one thing that
    # cannot be migrated (the password). Never persists the secret.
    mig_opt 755 wootc-user-gui "$DEPLOY_ROOT/var/usrlocal/bin/wootc-user-gui"
    mig_opt 644 wootc-user.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-user.desktop"
    # Gates the bridges on the migration chooser's opt-out selection.
    mig_opt 755 wootc-selection "$DEPLOY_ROOT/var/usrlocal/bin/wootc-selection"
    # Phase 3 (§4.2 stage 5-6): "move to Linux only" planner. Analysis path is
    # live; the destructive repartition path is guarded off until rung-3 proof.
    # fisherman is not in the migration directory (it is built from Go in the
    # Containerfile and baked into the deployer initramfs via dracut --install),
    # but wootc-go-native calls it for Phase 3 native disk graduation.  Copy it
    # in directly.
    install -D -m755 /usr/bin/fisherman "$DEPLOY_ROOT/var/usrlocal/bin/fisherman"
    mig_opt 755 wootc-go-native  "$DEPLOY_ROOT/var/usrlocal/bin/wootc-go-native"
    mig_opt 755 wootc-go-native-gui "$DEPLOY_ROOT/var/usrlocal/bin/wootc-go-native-gui"
    mig_opt 644 wootc-go-native.desktop "$DEPLOY_ROOT/usr/share/applications/wootc-go-native.desktop"
    # QGA commands run in virt_qemu_ga_t, which SELinux prevents from executing podman/bootc.
    # Stage a narrow systemd request bridge so PID 1 runs the migration engine in a normal domain.
    mkdir -p "$DEPLOY_ROOT/var/usrlocal/libexec" "$DEPLOY_ROOT/var/usrlocal/libexec" 2>/dev/null || true
    install -D -m755 /usr/lib/wootc/migration/wootc-e2e-phase3-dispatch "$DEPLOY_ROOT/var/usrlocal/libexec/wootc-e2e-phase3-dispatch"
    mig_opt 644 wootc-e2e-phase3.service "$DEPLOY_ROOT/etc/systemd/system/wootc-e2e-phase3.service"
    mig_opt 644 wootc-e2e-phase3.path "$DEPLOY_ROOT/etc/systemd/system/wootc-e2e-phase3.path"
    # PASS only when every piece is verifiably in the target root — a dangling
    # wants symlink (units skipped by mig_opt) previously still printed PASS,
    # and the failure surfaced two reboots later as "dispatch never ran".
    if [[ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-e2e-phase3.service" \
       && -f "$DEPLOY_ROOT/etc/systemd/system/wootc-e2e-phase3.path" ]]; then
        mkdir -p "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf ../wootc-e2e-phase3.path \
            "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-e2e-phase3.path"
        log "  [PASS] Phase-3 systemd request bridge enabled (units + wants link in target /etc)"
    else
        log "  [FAIL] Phase-3 request bridge units missing from initramfs — dispatch will never trigger"
    fi
    # WSL migration (§4.6): dotfiles + Brewfile from a WSL install.
    mig_opt 755 wootc-wsl-bridge "$DEPLOY_ROOT/var/usrlocal/bin/wootc-wsl-bridge"
    # Wi-Fi migration (§4.6): the bridge needs python3 + nmcli, so it runs on
    # first boot (oneshot service), not in this minimal initramfs. Stage the
    # exported profiles into the deployment; the bridge imports then shreds them.
    mig_opt 755 wootc-wifi-bridge "$DEPLOY_ROOT/var/usrlocal/bin/wootc-wifi-bridge"
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
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-esp-sync"
    install -m644 /usr/lib/wootc/migration/wootc-esp-sync.service \
        "$DEPLOY_ROOT/etc/systemd/system/wootc-esp-sync.service"
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../wootc-esp-sync.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-esp-sync.service"
    install -m755 /usr/lib/wootc/migration/wootc-detect-apps \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-detect-apps"
    install -m755 /usr/lib/wootc/migration/wootc-office-bridge \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-office-bridge"
    # Windows-Style Mode: per-user look apply on first login.
    install -m755 /usr/lib/wootc/migration/wootc-apply-look \
        "$DEPLOY_ROOT/var/usrlocal/bin/wootc-apply-look"
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
    mkdir -p "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants" \
             "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../wootc-host-bind.service \
        "$DEPLOY_ROOT/etc/systemd/system/local-fs.target.wants/wootc-host-bind.service"
    # passthrough needs /var mounted — multi-user, not local-fs (unit comment).
    ln -sf ../wootc-passthrough.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-passthrough.service"

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

    if grep -q 'wootc.host_uuid=.*loop=/wootc/disks/root.disk' "${BLS_DIR:-$DEPLOY_ROOT/boot/loader/entries}"/*.conf; then
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
            # The deployer kernel is Fedora-signed → shim-trusted. Composefs
            # Phase 2 reuses it (the UKI vmlinuz has no individual PE sig).
            # Keep it on the ESP for composefs; delete for ostree where the
            # target kernel replaces it.
            if [[ "$COMPOSEFS" != 1 || "$BOOTLOADER" != systemd ]]; then
                rm -f /mnt/esp/EFI/wootc/deployer-vmlinuz
            fi
            rm -f /mnt/esp/EFI/wootc/deployer-initramfs.img \
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
                cfs_linux=$(grep -m1 '^linux '  "${cfs_entries[0]}" | awk '{print $2}' || true)
                cfs_initrd=$(grep -m1 '^initrd ' "${cfs_entries[0]}" | awk '{print $2}' || true)
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
                stage_wootc_overlay "$OVL"
                # EL-class kernels have no ntfs3, so Phase 2 needs a userspace
                # driver. Sourced coherently (target first, then the deployer's
                # complete private closure) — the old inline copy here looked
                # under a /mnt/sysroot that never exists and shipped the
                # deployer binary without its closure (agent-lessons §8).
                if ! stage_ntfs3g_closure "$OVL"; then
                    log "  [WARN] no ntfs-3g stageable for the composefs Phase-2 initrd — relying on kernel ntfs3"
                fi
                # NOTHING guest-agent-related belongs in this overlay. It is a
                # cpio unpacked into the INITRAMFS: at switch-root the whole
                # tree is discarded, so a qemu-ga binary at $OVL/usr/bin and a
                # multi-user.target.wants symlink (a target the initrd never
                # reaches) cannot put an agent in the booted system: they only
                # made the initrd bigger and the intent look satisfied. The
                # real-root staging is stage_qemu_ga_into_target, above.

                # The deployer kernel needs its OWN kernel modules — the UKI
                # initrd has modules for the composefs kernel (vermagic
                # mismatch).  Copy the deployer's complete module tree into
                # the cpio overlay.  The UKI initrd modules will be skipped
                # by modprobe (wrong vermagic); the deployer copies match
                # and are signed with the Fedora key the deployer kernel trusts.
                _dkver=$(ls /lib/modules | head -1)
                if [[ -n "$_dkver" && -d "/lib/modules/$_dkver" ]]; then
                    mkdir -p "$OVL/lib/modules"
                    cp -a "/lib/modules/$_dkver" "$OVL/lib/modules/"
                    depmod -b "$OVL" "$_dkver" 2>/dev/null || true
                    # Load essential modules before wootc-attach via a
                    # systemd service (dracut pre-udev hooks may not fire
                    # in the UKI initrd's minimal init).
                    mkdir -p "$OVL/usr/lib/systemd/system" \
                             "$OVL/usr/lib/systemd/system/initrd-root-device.target.wants"
                    cat > "$OVL/usr/lib/systemd/system/wootc-load-modules.service" <<'SMOD'
[Unit]
Description=Load wootc essential kernel modules
DefaultDependencies=no
Before=wootc-attach.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/wootc/load-modules.sh

[Install]
WantedBy=initrd-root-device.target
SMOD
                    mkdir -p "$OVL/usr/lib/wootc"
                    cat > "$OVL/usr/lib/wootc/load-modules.sh" <<'SMODSH'
#!/bin/sh
echo "wootc: load-modules starting (kver=$(uname -r))" > /dev/console
_kver=$(uname -r)
for _mod in virtio_pci virtio_scsi ahci sd_mod; do
    _path=$(find "/lib/modules/$_kver" -name "${_mod}.ko" -print -quit 2>/dev/null)
    if [ -n "$_path" ] && [ -f "$_path" ]; then
        echo "wootc: insmod $_mod ($_path)" > /dev/console
        insmod "$_path" 2>/dev/null || modprobe "$_mod" 2>/dev/null || true
    else
        echo "wootc: module $_mod NOT FOUND in /lib/modules/$_kver" > /dev/console
    fi
done
echo "wootc: load-modules done" > /dev/console
SMODSH
                    chmod +x "$OVL/usr/lib/wootc/load-modules.sh"
                    ln -sf ../wootc-load-modules.service \
                        "$OVL/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-load-modules.service"
                    log "  Staged deployer kernel modules ($_dkver) for Phase 2"
                fi

                if build_phase2_initrd "$OVL" "$ISRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                    rm -rf "$OVL"
                    log "  [PASS] composefs Phase-2 initrd patched with wootc-boot (prepend-cpio, contents verified)"
                else
                    rm -rf "$OVL"
                    err "  [FAIL] composefs: Phase-2 initrd build/verify failed — aborting before the ESP advertises an unbootable Phase 2"
                    exit 1
                fi
                # Keep root=UUID + composefs=<hash>; drop unresolved \$vars + quiet.
                cfs_opts=$(printf '%s' "$cfs_opts" | tr ' ' '\n' | grep -v '\$' | grep -vE '^(quiet|rhgb)$' | tr '\n' ' ' || true)
                mkdir -p /mnt/esp/loader/entries
                cat > /mnt/esp/loader/entries/wootc.conf <<BLSEOF
title wootc Linux
linux /EFI/wootc/phase2-vmlinuz
initrd /EFI/wootc/phase2-initramfs.img
options ${cfs_opts} loop=/wootc/disks/root.disk wootc.host_uuid=${HOST_UUID} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${PHASE2_KARGS}
BLSEOF
                rm -f /mnt/esp/loader/entries/wootc-deployer.conf

                # The composefs UKI vmlinuz has no individual PE signature
                # (only the .efi wrapper is signed), so `linux` with it would
                # fail shim verification.  Use the deployer kernel instead —
                # it is Fedora-signed and trusted by the ESP's Fedora shim.
                # The Phase-2 initrd is the patched UKI initrd (cpio prepend).
                PHASE2_LINUX="/EFI/wootc/deployer-vmlinuz ${cfs_opts} loop=/wootc/disks/root.disk wootc.host_uuid=${HOST_UUID} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${PHASE2_KARGS}"
                for _gd in /mnt/esp/EFI/fedora /mnt/esp/EFI/redhat /mnt/esp/EFI/wootc; do
                    mkdir -p "$_gd"
                    cat > "$_gd/grub.cfg" <<GRUBCFGEOF
# wootc Phase 2 (composefs) — deployer kernel + patched UKI initrd
set default=0
set timeout=3

menuentry "wootc Linux" {
    linux ${PHASE2_LINUX}
    initrd /EFI/wootc/phase2-initramfs.img
}
GRUBCFGEOF
                done

                ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
                if [[ -n "$ESP_UUID" ]]; then
                    mkdir -p "$DEPLOY_ROOT/etc/wootc"
                    printf 'HOST_ESP_UUID=%s\nBOOTLOADER=systemd\nSOURCE_IMAGE_REF=%s\nSOURCE_FILESYSTEM=%s\n' \
                        "$ESP_UUID" "$SOURCE_IMAGE" "$FILESYSTEM" > "$DEPLOY_ROOT/etc/wootc/host-esp.conf"
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
                if [[ -n "$KERNEL_SRC" && -s "$KERNEL_SRC" && -n "$INITRD_SRC" && -s "$INITRD_SRC" ]]; then
                    cp "$KERNEL_SRC" /mnt/esp/EFI/wootc/phase2-vmlinuz
                    OVL="/tmp/wootc-ovl-$$"
                    rm -rf "$OVL"; mkdir -p "$OVL"
                    stage_wootc_overlay "$OVL"
                    if ! stage_ntfs3g_closure "$OVL"; then
                        log "  [WARN] no ntfs-3g stageable for the systemd-boot Phase-2 initrd — relying on kernel ntfs3"
                    fi

                    # NOTE: Storage kernel modules are intentionally NOT staged here.
                    # See branch-1 comment above for rationale (Secure Boot lockdown rejection).

                    if ! build_phase2_initrd "$OVL" "$INITRD_SRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                        rm -rf "$OVL"
                        err "  [FAIL] systemd-boot: Phase-2 initrd build/verify failed"
                        exit 1
                    fi
                    rm -rf "$OVL"

                    ROOT_OPTIONS=$(grep '^options ' "${BLS_DIR:-$DEPLOY_ROOT/boot/loader/entries}"/*.conf 2>/dev/null | head -1 | sed 's/^options *//')
                    ROOT_OPTIONS=$(printf '%s' "$ROOT_OPTIONS" | tr ' ' '\n' | grep -v '\$' | grep -v -E '^(quiet|rhgb)$' | tr '\n' ' ' || true)
                    mkdir -p /mnt/esp/loader/entries
                    cat > /mnt/esp/loader/entries/wootc.conf <<BLSEOF
title wootc Linux
linux /EFI/wootc/phase2-vmlinuz
initrd /EFI/wootc/phase2-initramfs.img
options ${ROOT_OPTIONS} console=tty1 console=ttyS0,115200 ${PHASE2_KARGS}
BLSEOF
                    rm -f /mnt/esp/loader/entries/wootc-deployer.conf
                    log "  [PASS] Phase-2 systemd-boot entry written with wootc-boot & ntfs-3g patched initrd"
                else
                    err "  [FAIL] Phase-2 systemd-boot ESP sync failed"
                    exit 1
                fi
                ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
                if [[ -n "$ESP_UUID" ]]; then
                    mkdir -p "$DEPLOY_ROOT/etc/wootc"
                    printf 'HOST_ESP_UUID=%s\nBOOTLOADER=systemd\nSOURCE_IMAGE_REF=%s\nSOURCE_FILESYSTEM=%s\n' \
                        "$ESP_UUID" "$SOURCE_IMAGE" "$FILESYSTEM" > "$DEPLOY_ROOT/etc/wootc/host-esp.conf"
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
                TARGET_GRUB=$(find "$DEPLOY_ROOT/usr/lib/efi/grub2" -type f \
                    -name grubx64.efi -print -quit 2>/dev/null || true)
                if [[ -n "$TARGET_GRUB" ]]; then
                    vendor_dir=${TARGET_GRUB%/grubx64.efi}
                    vendor_dir=${vendor_dir##*/}
                    TARGET_SHIM=$(find "$DEPLOY_ROOT/usr/lib/efi/shim" -type f \
                        -path "*/EFI/$vendor_dir/shimx64.efi" -print -quit 2>/dev/null || true)
                    TARGET_VENDOR="$vendor_dir"
                fi
            fi
            shopt -u nullglob

            log "  ESP source kernel=${KERNEL_SRC:-missing}"
            log "  ESP source initramfs=${INITRD_SRC:-missing}"
            log "  ESP source shim=${TARGET_SHIM:-missing}"
            log "  ESP source grub=${TARGET_GRUB:-missing}"

            if [[ -n "$KERNEL_SRC" && -s "$KERNEL_SRC" ]] && \
               [[ -n "$INITRD_SRC" && -s "$INITRD_SRC" ]] && \
               [[ -n "$TARGET_SHIM" && -n "$TARGET_GRUB" ]]; then
                log "  Staging Phase-2 kernel and initramfs to ESP:EFI/wootc/..."
                cp "$KERNEL_SRC" /mnt/esp/EFI/wootc/phase2-vmlinuz
                # Patch Phase-2 initrd with wootc-boot via prepend-cpio. The target image
                # (e.g. yellowfin) may lack ntfs3/ntfs-3g, so a userspace driver is
                # staged too — coherently sourced (the old inline copy staged the
                # deployer's libraries at the TARGET's library paths, overriding the
                # base initrd's own libc-adjacent files: cross-image soname roulette).
                OVL="/tmp/wootc-ovl-$$"
                rm -rf "$OVL"; mkdir -p "$OVL"
                stage_wootc_overlay "$OVL"
                if ! stage_ntfs3g_closure "$OVL"; then
                    log "  [WARN] no ntfs-3g stageable for the Phase-2 initrd — relying on kernel ntfs3"
                fi

                # NOTE: Storage kernel modules are intentionally NOT staged here.
                # See branch-1 comment above for rationale (Secure Boot lockdown rejection).

                if ! build_phase2_initrd "$OVL" "$INITRD_SRC" /mnt/esp/EFI/wootc/phase2-initramfs.img; then
                    rm -rf "$OVL"
                    err "  [FAIL] Phase-2 initrd build/verify failed"
                    exit 1
                fi
                rm -rf "$OVL"
                log "  [PASS] Phase-2 initrd patched with wootc-boot & ntfs-3g (prepend-cpio, contents verified)"

                # BCD loads \EFI\fedora\shimx64.efi; the target shim then loads
                # grubx64.efi from that same dir. Overwrite both with the
                # target-signed pair (deployment is done — this ESP now boots
                # Phase-2, not the deployer).
                cp "$TARGET_SHIM" /mnt/esp/EFI/fedora/shimx64.efi
                cp "$TARGET_GRUB" /mnt/esp/EFI/fedora/grubx64.efi
                TARGET_MM="$DEPLOY_ROOT/usr/lib/bootupd/updates/EFI/$TARGET_VENDOR/mmx64.efi"
                if [[ ! -f "$TARGET_MM" ]]; then
                    TARGET_MM=$(find "$DEPLOY_ROOT/usr/lib/efi/shim" -type f \
                        -path "*/EFI/$TARGET_VENDOR/mmx64.efi" -print -quit 2>/dev/null || true)
                fi
                [[ -f "$TARGET_MM" ]] && cp "$TARGET_MM" /mnt/esp/EFI/fedora/mmx64.efi || true
                log "  Installed target-signed shim+grub (vendor: $TARGET_VENDOR)"

                # Kernel cmdline from the patched BLS entry (keeps root=UUID
                # and ostree=; the loop-attach hook makes that UUID appear).
                ROOT_OPTIONS=$(grep '^options ' "${BLS_DIR:-$DEPLOY_ROOT/boot/loader/entries}"/*.conf 2>/dev/null | head -1 | sed 's/^options *//')
                # BLS $kernelopts-style variables never resolve in our
                # grub.cfg; drop tokens containing '$'. Also drop quiet/rhgb —
                # a silent early-boot panic (all 4 vCPUs parked in
                # stop_this_cpu() at an identical RIP, confirmed via QEMU
                # monitor `info registers` across CPUs) showed zero output on
                # serial OR framebuffer, meaning the panic happens before any
                # console driver registers. earlycon+ignore_loglevel force the
                # UART console up immediately so the actual panic prints.
                ROOT_OPTIONS=$(printf '%s' "$ROOT_OPTIONS" | tr ' ' '\n' | grep -v '\$' | grep -v -E '^(quiet|rhgb)$' | tr '\n' ' ' || true)

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
    linux /EFI/wootc/phase2-vmlinuz ${ROOT_OPTIONS} loop=/wootc/disks/root.disk wootc.host_uuid=${HOST_UUID} console=tty1 console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200n8 ignore_loglevel ${PHASE2_KARGS}
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
                    mkdir -p "$DEPLOY_ROOT/etc/wootc" 2>/dev/null || true
                    printf 'HOST_ESP_UUID=%s\nSOURCE_IMAGE_REF=%s\nSOURCE_FILESYSTEM=%s\n' \
                        "$ESP_UUID" "$SOURCE_IMAGE" "$FILESYSTEM" \
                        > "$DEPLOY_ROOT/etc/wootc/host-esp.conf" 2>/dev/null || true
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
                umount /mnt/esp 2>/dev/null || true
                exit 1
            fi
            fi
            fi   # close CFS_HANDLED guard (generic ostree/BLS staging path)
            umount /mnt/esp 2>/dev/null || err "  [WARN] could not unmount /mnt/esp (busy?) — continuing"
        else
            err "  [WARN] Could not mount ESP ${ESP_DEV}; Phase-2 boot will fail"
        fi
    fi

    # Files written by this initramfs do not automatically inherit the target
    # deployment's SELinux labels. Mode 0755 is not enough: on enforcing
    # Bluefin an unlabeled /var/usrlocal/bin/wootc-go-native exists and resolves
    # through /usr/local, but execve returns EACCES. Apply the target image's
    # own file-context policy after every post-install and bootloader write.
    # /var is still bound to the real OSTree stateroot here, so relabeling
    # /usr/local reaches the exact files the running system will see.
    log "  verify: applying target SELinux labels to post-install payload"
    SELINUX_FILE_CONTEXTS=""
    for _fc in "$DEPLOY_ROOT"/etc/selinux/*/contexts/files/file_contexts; do
        if [[ -f "$_fc" ]]; then
            SELINUX_FILE_CONTEXTS="${_fc#"$DEPLOY_ROOT"}"
            break
        fi
    done
    # restorecon is deliberately not used here. It returns success but is a
    # no-op when the deployer kernel has SELinux disabled. setfiles applies the
    # target policy directly and writes security.selinux xattrs regardless;
    # this was verified against the mounted Bluefin deployment on himachal.
    if [[ -n "$SELINUX_FILE_CONTEXTS" ]] && chroot "$DEPLOY_ROOT" env PATH=/usr/sbin:/sbin:$PATH sh -c 'command -v setfiles >/dev/null 2>&1'; then
        RELABEL_PATHS=()
        for _path in \
            /var/usrlocal \
            /usr/local \
            /usr/share/applications \
            /usr/share/polkit-1/actions \
            /usr/share/wootc \
            /etc/systemd/system \
            /etc/xdg/autostart \
            /etc/wootc \
            /var/lib/wootc; do
            [[ -e "$DEPLOY_ROOT$_path" ]] && RELABEL_PATHS+=("$_path")
        done
        if ! chroot "$DEPLOY_ROOT" env PATH=/usr/sbin:/sbin:$PATH setfiles -F "$SELINUX_FILE_CONTEXTS" "${RELABEL_PATHS[@]}"; then
            err "  [FAIL] setfiles failed for installed runtime payload — enforcing SELinux would deny execution"
            exit 1
        fi
        GO_NATIVE_CONTEXT=$(chroot "$DEPLOY_ROOT" env PATH=/usr/sbin:/sbin:$PATH ls -Zd /var/usrlocal/bin/wootc-go-native 2>/dev/null || true)
        log "  guard: Phase-3 executable SELinux context: ${GO_NATIVE_CONTEXT:-missing}"
        if [[ -f "$DEPLOY_ROOT/var/usrlocal/bin/wootc-go-native" && ( -z "$GO_NATIVE_CONTEXT" || "$GO_NATIVE_CONTEXT" == *"? "* ) ]]; then
            err "  [FAIL] wootc-go-native remains unlabeled after setfiles — Phase 3 would get Permission denied"
            exit 1
        fi
    elif [[ -f "$DEPLOY_ROOT/var/usrlocal/bin/wootc-go-native" ]]; then
        # setfiles / policycoreutils is missing, but the deployer already
        # set SELinux to permissive above (§SELINUX_RELAX).  Only fail when
        # the target would actually enforce — composefs images (dakota)
        # often ship libselinux-utils but not the policy tools, and that
        # is fine because the permissive config means labels are advisory.
        if grep -q '^SELINUX=enforcing' "$DEPLOY_ROOT/etc/selinux/config" 2>/dev/null; then
            err "  [FAIL] target has Phase-3 executable but no setfiles policy/tool — cannot make it executable under enforcing SELinux"
            exit 1
        fi
        log "  [PASS] Phase-3 executable present; SELinux is permissive/disabled — labels not required (setfiles absent)"
    fi

    vstage "verify-complete (all stages passed; Phase-2 ESP is staged)"
    # The composefs target ESP is mounted UNDER boot/, so it must go first or
    # the boot umount fails busy.
    [[ -n "${ESP_BOUND_AT:-}" ]] && umount "$ESP_BOUND_AT" 2>/dev/null || true
    # Unmount defensively: a busy unmount here would abort the script under
    # set -e with umount's exit 32, AFTER verification has fully passed —
    # turning a successful deploy into a dead deployer that never reboots into
    # Phase 2. Report, do not die.
    umount "$DEPLOY_ROOT/boot" 2>/dev/null || err "  [WARN] could not unmount $DEPLOY_ROOT/boot (busy?) — continuing"
    if [[ "$DEPLOY_VAR_BOUND" == true ]]; then
        umount "$DEPLOY_ROOT/var" 2>/dev/null || err "  [WARN] could not unmount $DEPLOY_ROOT/var (busy?) — continuing"
    fi
    umount /mnt/verify 2>/dev/null || err "  [WARN] could not unmount /mnt/verify (busy?) — continuing"
else
    # FAIL CLOSED (#45). No mountable, recognized installed root means Phase 2
    # cannot be verified OR staged — the ESP never gets a Phase-2 kernel, and
    # the firmware would fall straight back to Windows (exactly the recorded
    # composefs failure shape). "Checking via loop file only" verified nothing;
    # advertising deploy-ready here misattributes the later boot failure and
    # shows the user a success path for an unbootable system. Say precisely
    # what was found instead, then refuse.
    err "  [FAIL] no mountable, recognized installed root on ${VERIFY_LOOP} — cannot verify or stage Phase 2"
    err "         partition table as the kernel sees it:"
    sfdisk -l "$VERIFY_LOOP" 2>&1 | sed 's/^/    /' >&2 || true
    for _p in "${VERIFY_LOOP}"p*; do
        [[ -b "$_p" ]] || continue
        err "         $_p: $(blkid "$_p" 2>/dev/null || echo 'blkid: no signature')"
        _mnt_err=$(timeout 15 mount -o ro "$_p" /mnt/verify 2>&1) && {
            err "           mounts, but no ostree/composefs deployment or /etc/os-release inside"
            umount /mnt/verify 2>/dev/null || true
        } || err "           mount: $(printf '%s' "$_mnt_err" | head -c 300)"
    done
    err "         The install is either unstaged or in a layout this deployer does not recognize."
    err "         Refusing to advertise deploy-ready for a system that cannot boot."
    exit 1
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

phase "reboot"
DEPLOY_OK=1   # success — the EXIT trap shows "starting Linux", not the failure card
log "Verification complete. Deployer requested reboot..."
log "  [wootc] VERIFICATION_SUMMARY: deployer ready for migration phase"
log "deployer requested reboot"
# Let the "All set! Starting your new Linux system..." splash sit for a beat so
# the reboot doesn't yank a mid-progress screen away from the user.
splash_set 100 100 "All set! Starting your new Linux system..."
sleep 2 2>/dev/null || true
splash_stop
sync || true

# Tear down the scratch store and leave the NTFS volume clean before the
# forced reboot (reboot -f syncs but does not unmount; a still-mounted rw
# NTFS would be flagged dirty and block the Phase 2 rw mount).
umount /var/tmp 2>/dev/null || true
umount /var/lib/containers 2>/dev/null || true
umount /var/fisherman-tmp 2>/dev/null || true
[[ -n "$SCRATCH_LOOP" ]] && losetup -d "$SCRATCH_LOOP" 2>/dev/null || true
SCRATCH_LOOP=""
rm -f "$SCRATCH_IMG"

# Robustly unmount the host NTFS. (The verify path that reached here having
# failed to mount the installed root is now fatal — #45 — but a loop device or
# overlay can still pin a file under /mnt/ntfs) — a plain `umount /mnt/ntfs` blocks
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

sleep 3
sync || true
# reboot -f is systemctl reboot -f and hangs under emergency mode; use the
# direct syscall (everything is unmounted by this point).
reboot -ff || reboot -f
