#!/bin/bash
# shellcheck disable=SC2154  # moddir is set by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/module-setup.sh
# Registers hooks, binaries, and kernel modules for loop-root booting.

check() {
    return 0
}

depends() {
    echo "base"
}

installkernel() {
    instmods ntfs3 loop xfs
}

install() {
    inst_hook cmdline 10 "$moddir/wootc-parse-cmdline.sh"
    inst_hook mount 99 "$moddir/wootc-mount-loop.sh"
    inst_multiple losetup mount mkdir modprobe blockdev sed sleep
}
