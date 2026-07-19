#!/bin/bash
# shellcheck disable=SC2154  # moddir is set by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/module-setup.sh
# Registers the loop attach hook and kernel modules for raw-root.disk booting.
#
# Design: the BLS entry keeps its normal root=UUID=<target-root> argument.
# The initqueue hook mounts the Windows NTFS partition and attaches
# root.disk with partition scanning, which makes that UUID appear; systemd's
# standard sysroot.mount and ostree-prepare-root handle the rest.

check() {
    return 0
}

depends() {
    echo "base"
}

installkernel() {
    # loop  — attaches the raw root.disk (replaced nbd when VHDX was dropped)
    # fuse  — only for the ntfs-3g userspace fallback
    # ntfs3 — kernel NTFS; absent on some Enterprise Linux kernels
    instmods loop fuse
    instmods ntfs3 2>/dev/null || :   # optional: not built on EL kernels
}

install() {
    # PLAIN initqueue, NOT initqueue/settled.
    #
    # dracut-initqueue's main loop is:
    #     for job in $hookdir/initqueue/*.sh;   do ... done   <- always runs
    #     udevadm settle --timeout=0 || continue              <- instant check!
    #     for job in $hookdir/initqueue/settled/*.sh; do ...  <- often skipped
    #
    # `--timeout=0` asks whether udev has settled RIGHT NOW. While the host NTFS
    # is being mounted and loop devices are being probed, udev is busy, so the
    # loop `continue`s and the settled hooks are never reached. That is exactly
    # what we observed: the guard confirmed wootc-attach-loop.sh was in the
    # initramfs, yet Phase 2 produced not one line of hook output — not even its
    # unconditional entry marker — and died on sysroot.mount because root.disk
    # was never attached.
    #
    # The plain queue runs on every iteration regardless of udev state. The hook
    # is already written to be re-entrant (it returns 0 early once
    # /run/wootc-loop-attached exists), so repeated invocation is by design.
    inst_hook initqueue 10 "$moddir/wootc-attach-loop.sh"

    # losetup is all the hook needs — no staged binary, no closure. Target bootc
    # images already ship it (verified: yellowfin has /usr/sbin/losetup and no
    # qemu-nbd), which is exactly why root.disk is a raw image rather than VHDX.
    inst_multiple losetup

    inst_multiple mount mountpoint mkdir modprobe blockdev sleep
    # The userspace NTFS driver (ntfs-3g) for kernels without ntfs3 is added by
    # the deployer's regen via `dracut --install` — module-level inst does not
    # reliably resolve it there, but a regen-level --install does.
}
