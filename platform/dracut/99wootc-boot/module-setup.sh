#!/bin/bash
# shellcheck disable=SC2154  # moddir is set by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/module-setup.sh
# Registers the loop-attach hook and kernel modules for loop-root booting.
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
    instmods ntfs3 loop
}

install() {
    inst_hook initqueue/settled 10 "$moddir/wootc-attach-loop.sh"
    inst_multiple losetup mount mountpoint mkdir modprobe blockdev sleep
}
