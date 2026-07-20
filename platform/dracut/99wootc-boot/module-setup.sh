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
    # systemd: the Phase-2 initramfs is systemd-based and we install a unit into
    # it (see install()). base: dracut-lib.sh for the hook fallback.
    echo "base systemd"
}

installkernel() {
    # loop  — attaches the raw root.disk (replaced nbd when VHDX was dropped)
    # fuse  — only for the ntfs-3g userspace fallback
    # ntfs3 — kernel NTFS; absent on some Enterprise Linux kernels
    instmods loop fuse
    instmods ntfs3 2>/dev/null || :   # optional: not built on EL kernels
}

install() {
    # A SYSTEMD SERVICE, not an initqueue hook.
    #
    # PROVEN the hard way (himachal, offline serial): the Phase-2 ostree
    # initramfs is a pure-systemd initramfs and runs dracut-initqueue ZERO times
    # — it boots root from a dev-disk-by-uuid-<root>.device unit. So ANY initqueue
    # hook (settled or plain) is dead code: the hook was present in the initramfs,
    # yet Phase 2 emitted not one line of its output and died on sysroot.mount.
    #
    # The systemd-correct mechanism is a oneshot unit ordered
    # After=systemd-udevd, Before=initrd-root-device.target/sysroot.mount. It
    # attaches root.disk before anything waits for the root device, so the
    # ordinary sysroot.mount just works.
    #
    # The script is installed at a fixed path the unit references, and made
    # re-entrant + self-diagnosing so it is safe to leave running.
    inst_simple "$moddir/wootc-attach-loop.sh" /usr/lib/wootc/wootc-attach-loop.sh

    # $systemdsystemunitdir is set by dracut's systemd module, but do not trust
    # it to be non-empty — fall back to the canonical path so the unit always
    # lands somewhere systemd will read it.
    local unitdir="${systemdsystemunitdir:-/usr/lib/systemd/system}"
    # The unit file MUST be present in $moddir, or inst_simple silently installs
    # nothing and the wants symlink below becomes a dangling link — systemd then
    # has no unit to start and Phase 2 never attaches root.disk. This exact bug
    # shipped once because the deployer's own module-setup.sh forgot to stage the
    # .service into the deployer initramfs. Fail the BUILD instead.
    if [[ ! -f "$moddir/wootc-attach.service" ]]; then
        dfatal "wootc-boot: $moddir/wootc-attach.service is missing — cannot install the unit (dangling wants would result)"
        return 1
    fi
    inst_simple "$moddir/wootc-attach.service" "$unitdir/wootc-attach.service"
    # Confirm the unit actually landed in the initramfs tree (not just that the
    # source existed): a wants symlink to a non-existent unit is a silent no-op.
    if [[ ! -f "$initdir$unitdir/wootc-attach.service" ]]; then
        dfatal "wootc-boot: wootc-attach.service did not install into $initdir$unitdir"
        return 1
    fi

    # Wire it into the initrd root-device bring-up so it actually runs, by
    # creating the wants symlink DIRECTLY, deterministically, in the SAME unit
    # dir the service lives in.
    #
    # Do NOT use `systemctl add-wants --root`: it writes the symlink under
    # <root>/etc/systemd/system/initrd-root-device.target.wants/, which is (a)
    # NOT where we verify ($unitdir = /usr/lib/systemd/system) and (b) not
    # reliably copied into the built initramfs by dracut. PROVEN on hosted run
    # 29712429479: add-wants "succeeded" into /etc, the /usr/lib check below then
    # found nothing, dfatal fired, and the entire Phase-2 dracut regen ABORTED —
    # so Phase 2 booted an initramfs with the service unwired, root.disk never
    # attached, and sysroot.mount timed out into the emergency shell.
    local wantsdir="$initdir$unitdir/initrd-root-device.target.wants"
    mkdir -p "$wantsdir"
    ln -sf "../wootc-attach.service" "$wantsdir/wootc-attach.service"
    # Verify the SYMLINK exists (-L), not that its target resolves (-e): a
    # transient target-ordering issue must not false-fail and abort the build.
    if [[ ! -L "$wantsdir/wootc-attach.service" ]]; then
        dfatal "wootc-boot: could not create initrd-root-device.target.wants/wootc-attach.service symlink in $wantsdir"
        return 1
    fi
    # Belt-and-braces for any non-systemd initramfs that still runs initqueue.
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
