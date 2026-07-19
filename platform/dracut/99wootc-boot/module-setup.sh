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
    inst_hook initqueue/settled 10 "$moddir/wootc-attach-loop.sh"

    # losetup is all the hook needs — no staged binary, no closure. Target bootc
    # images already ship it (verified: yellowfin has /usr/sbin/losetup and no
    # qemu-nbd), which is exactly why root.disk is a raw image rather than VHDX.
    inst_multiple losetup

    inst_multiple mount mountpoint mkdir modprobe blockdev sleep
    # The userspace NTFS driver (ntfs-3g) for kernels without ntfs3 is added by
    # the deployer's regen via `dracut --install` — module-level inst does not
    # reliably resolve it there, but a regen-level --install does.
}
