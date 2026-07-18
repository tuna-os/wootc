#!/bin/bash
# shellcheck disable=SC2154  # moddir is set by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/module-setup.sh
# Registers the NBD attach hook and kernel modules for VHDX-root booting.
#
# Design: the BLS entry keeps its normal root=UUID=<target-root> argument.
# The initqueue hook mounts the Windows NTFS partition and attaches
# root.vhdx with partition scanning, which makes that UUID appear; systemd's
# standard sysroot.mount and ostree-prepare-root handle the rest.

check() {
    return 0
}

depends() {
    echo "base"
}

installkernel() {
    # ntfs3 (kernel NTFS, absent on Enterprise Linux) + nbd (VHDX loopback) +
    # fuse (for the ntfs-3g userspace fallback when ntfs3 is missing).
    instmods nbd fuse
    instmods ntfs3 2>/dev/null || :   # optional: not built on EL kernels
}

install() {
    inst_hook initqueue/settled 10 "$moddir/wootc-attach-loop.sh"
    inst "$moddir/qemu-nbd" /usr/bin/qemu-nbd
    inst_multiple mount mountpoint mkdir modprobe blockdev sleep
    # The userspace NTFS driver (ntfs-3g) for kernels without ntfs3 is added by
    # the deployer's regen via `dracut --install` — module-level inst does not
    # reliably resolve it there, but a regen-level --install does.
}
