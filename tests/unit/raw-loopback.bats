#!/usr/bin/env bats
# raw-loopback.bats — root.disk is a RAW image attached with losetup.
#
# This replaced VHDX + qemu-nbd, and the reason is one measured fact:
#
#     /usr/sbin/losetup   PRESENT in ghcr.io/tuna-os/yellowfin:gnome
#     qemu-nbd            ABSENT
#
# VHDX needs a format-aware driver, which target bootc images do not ship. That
# forced a foreign Fedora qemu-nbd plus its 26 NEEDED libraries, its ld.so and a
# --library-path wrapper into an initramfs assembled from the TARGET image's
# libraries — producing a libfuse3.so.4-vs-.so.3 soname mismatch and a silent
# failure inside the staging that cost most of a day to localise.
#
# A raw image needs `losetup --partscan`, the kernel loop driver, already present
# on both sides. Nothing staged, no cross-image binary, no closure. Deleting the
# component beat repairing it.
#
# It also removes the VHDX format driver from the boot-critical WRITE path, and
# with it QEMU's VHDX corruption reports — notably corruption on EXPANSION
# (gitlab #727), which is exactly what a dracut regen writing a ~130 MB
# initramfs does.
#
# Wubi — the design wootc is modelled on — used a raw root.disk on /dev/loop0.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    HOOK="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach-loop.sh"
    MODSETUP="$REPO_ROOT/platform/dracut/99wootc-boot/module-setup.sh"
    PS1="$REPO_ROOT/tests/e2e/setup-wootc.ps1"
}

@test "all scripts are syntactically valid" {
    run bash -n "$DEPLOY";   [ "$status" -eq 0 ]
    run bash -n "$HOOK";     [ "$status" -eq 0 ]
    run bash -n "$MODSETUP"; [ "$status" -eq 0 ]
}

# ── Windows side ────────────────────────────────────────────────────────────

@test "Windows creates a PREALLOCATED raw image, not a VHDX" {
    grep -q 'root.disk' "$PS1"
    grep -q 'SetLength' "$PS1"
    run grep -n 'create vdisk' "$PS1"
    [ "$status" -ne 0 ]
}

@test "the image is physically allocated to prevent ntfs3 sparse I/O errors" {
    grep -q 'Physical allocation is required' "$PS1"
    run grep -n 'sparse setflag' "$PS1"
    [ "$status" -ne 0 ]
}

@test "the created size is verified, not assumed" {
    grep -q 'expected \$sizeBytes' "$PS1"
}

# ── deployer side ───────────────────────────────────────────────────────────

@test "the deployer attaches with losetup --partscan" {
    grep -q 'losetup --find --show --partscan "\$DISK"' "$DEPLOY"
}

@test "--partscan is present everywhere a loop device is attached" {
    # Without it /dev/loopNpM never appears, so the root UUID never reaches
    # udev and sysroot.mount fails — the exact emergency-shell symptom.
    local attaches partscans
    attaches=$(grep -c 'losetup --find --show' "$DEPLOY")
    partscans=$(grep -c 'losetup --find --show --partscan' "$DEPLOY")
    [ "$attaches" -eq "$partscans" ]
}

@test "loop.max_part is set on the Phase-2 kernel cmdline, not just via modprobe" {
    # `modprobe loop max_part=16` applies only at module LOAD time, so it is a
    # no-op when loop is already loaded or built in (CONFIG_BLK_DEV_LOOP=y).
    # Everything downstream depends on /dev/loopNpM appearing, so this is
    # insurance that survives built-in-vs-modular.
    grep -q 'LOOP_KARG="loop.max_part=16"' "$DEPLOY"
    grep -q 'PHASE2_KARGS=.*\$LOOP_KARG' "$DEPLOY"
}

@test "the verify attach is guarded like the main attach" {
    # Asymmetric guards are how one path gets a clear error and the other a
    # confusing downstream failure.
    grep -q 'losetup could not attach \$DISK for verification' "$DEPLOY"
}

@test "detach uses losetup -d, not qemu-nbd --disconnect" {
    grep -q 'losetup -d "\$LOOP_DEV"' "$DEPLOY"
    grep -q 'losetup -d "\$VERIFY_LOOP"' "$DEPLOY"
    run grep -nE '^[^#]*qemu-nbd --disconnect' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "no qemu-nbd remains in deployer CODE" {
    # Comments recording the history are fine and wanted; code is not.
    run grep -nE '^[^#]*qemu-nbd' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the closure staging is gone entirely" {
    run grep -nE '^[^#]*(NBD_DIR|NBD_STAGE_RC|nbd-closure|wootc-nbd)' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the VHDX format check is gone" {
    run grep -nE '^[^#]*(VHDX_FORMAT|--format=vhdx)' "$DEPLOY"
    [ "$status" -ne 0 ]
}

# ── Phase-2 hook ────────────────────────────────────────────────────────────

@test "the boot hook attaches with losetup --partscan" {
    grep -q 'losetup --find --show --partscan "\$FULL_LOOP_PATH"' "$HOOK"
}

@test "the hook's failure message names losetup and the loop module" {
    # Each EXIT line must state a reason specific enough to act on.
    grep -q 'EXIT: losetup failed to attach' "$HOOK"
    grep -q 'loop module loaded=' "$HOOK"
}

@test "the hook loads the loop module, not nbd" {
    grep -q 'modprobe loop max_part=16' "$HOOK"
    run grep -nE '^[^#]*modprobe nbd' "$HOOK"
    [ "$status" -ne 0 ]
}

@test "post-attach partitions are reported from the actual loop device" {
    # Hardcoding /dev/nbd0p* was wrong once losetup picks the device.
    grep -q 'post-attach partitions: .*\${LOOP_DEV}p\*' "$HOOK"
}

# ── dracut module ───────────────────────────────────────────────────────────

@test "the attach mechanism is a systemd SERVICE, not just an initqueue hook" {
    # PROVEN on himachal: the Phase-2 ostree initramfs is pure-systemd and runs
    # dracut-initqueue ZERO times (it boots root from a .device unit). An
    # initqueue hook is therefore dead code — it was present and produced no
    # output while sysroot.mount timed out. A systemd unit is the correct tool.
    grep -q 'wootc-attach.service' "$MODSETUP"
    grep -q 'inst_simple "$moddir/wootc-attach.service"' "$MODSETUP"
}

@test "Phase-2 prefers the proven plain ntfs3 mount and preserves FUSE fallback" {
    grep -q 'mount -t ntfs3 -o rw "\$HOST_DEV" "\$HOST_MNT"' "$HOOK"
    run grep -n 'nobarrier,async,prealloc' "$HOOK"
    [ "$status" -ne 0 ]
    grep -q '^KillMode=process$' "$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach.service"
}

@test "the service is ordered before sysroot.mount and after udev" {
    local svc="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach.service"
    grep -qE 'Before=.*sysroot.mount|Before=.*initrd-root-device.target' "$svc"
    grep -qE 'After=.*systemd-udevd' "$svc"
}

@test "the service is WIRED into initrd-root-device.target, verified at build" {
    # A unit installed but not wanted is the same silent no-op as the old hook.
    grep -q 'initrd-root-device.target.wants/wootc-attach.service' "$MODSETUP"
    grep -q 'initrd-root-device.target' "$MODSETUP"
}

@test "module-setup falls back when systemdsystemunitdir is empty" {
    grep -q 'systemdsystemunitdir:-/usr/lib/systemd/system' "$MODSETUP"
}

@test "the module depends on systemd so the unit dir exists" {
    grep -qE '^\s*echo "base systemd"' "$MODSETUP"
}

@test "the initramfs guard checks the WIRED service, not the hook" {
    grep -q "grep -cE 'initrd-root-device.target.wants/wootc-attach.service'" "$DEPLOY"
    run grep -nE "grep -cE 'hooks/initqueue" "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the module installs losetup and the loop kernel module" {
    grep -q 'inst_multiple losetup' "$MODSETUP"
    grep -q 'instmods loop' "$MODSETUP"
}

@test "the module stages NO foreign binary" {
    # The entire cross-image binary problem is deleted, not mitigated.
    run grep -nE '^[^#]*(nbd-closure|qemu-nbd|wootc-nbd)' "$MODSETUP"
    [ "$status" -ne 0 ]
}
