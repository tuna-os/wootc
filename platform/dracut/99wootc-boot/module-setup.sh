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

    # qemu-nbd ships as a self-contained closure (binary + every NEEDED library
    # + its own ld.so), staged by the deployer into $moddir/nbd-closure. It must
    # be installed as plain FILES, not via inst_binary: dracut would resolve the
    # binary's libraries against the target image and re-introduce exactly the
    # mismatch the closure exists to avoid (the deployer is Fedora-based, target
    # images generally are not — measured skew: libfuse3.so.4 vs .so.3).
    #
    # $moddir/qemu-nbd is a wrapper script that execs the bundled loader with an
    # explicit --library-path, so the hook can call `qemu-nbd` unchanged.
    if [ -d "$moddir/nbd-closure" ]; then
        for f in "$moddir"/nbd-closure/*; do
            [ -e "$f" ] || continue
            inst_simple "$f" "/usr/lib/wootc-nbd/${f##*/}"
        done
        inst_simple "$moddir/qemu-nbd" /usr/bin/qemu-nbd
    else
        # No closure staged — the deployer did not run its staging step. Fail
        # loudly at build time rather than at Phase-2 boot.
        dfatal "wootc-boot: nbd-closure missing; Phase 2 could not attach the VHDX"
        return 1
    fi

    inst_multiple mount mountpoint mkdir modprobe blockdev sleep
    # The userspace NTFS driver (ntfs-3g) for kernels without ntfs3 is added by
    # the deployer's regen via `dracut --install` — module-level inst does not
    # reliably resolve it there, but a regen-level --install does.
}
