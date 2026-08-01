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
    # virtio_scsi, virtio_pci, sd_mod, ahci — host disk controller drivers
    instmods loop fuse virtio_scsi virtio_pci sd_mod ahci nvme
    instmods ntfs3 2>/dev/null || :   # optional: not built on EL kernels
    # btrfs (#35): a btrfs root=UUID device stays SYSTEMD_READY=0 until the
    # btrfs module has it registered (udev 64-btrfs.rules), and dracut's own
    # 90btrfs module is only auto-selected when the image ships btrfs-progs.
    # The attach hook modprobes it for btrfs roots; make sure it is there.
    instmods btrfs 2>/dev/null || :   # optional: not built on all kernels
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
    # Do NOT also install an initqueue hook. The ostree Phase-2 initramfs DOES run
    # dracut-initqueue (contrary to the old assumption), and the hook fired at
    # t≈1.8s — before systemd-udevd was tracking devices — so the loop partitions
    # it created never became dev-disk-by-uuid-<root>.device UNITS, and it set the
    # /run/wootc-loop-attached guard so the correctly-ordered service then no-op'd.
    # Attach ONCE, from wootc-attach.service, at the right ordering point.

    # ── Clean hand-back of the Windows volume at Phase-2 shutdown ───────────
    # Phase 2 runs its root off a loop device backed by a file on the rw NTFS
    # mount, so nothing in the running system can release that volume: systemd
    # gives up with "Not all file systems unmounted, 1 left" / "Not all loop
    # devices detached, 1 left" and reboots into a Windows that then boot-loops
    # into Startup Repair (run 30704513401, both fedora-gnome cells).
    #
    # The fix is two hooks. The pre-pivot one stages /run/initramfs so
    # systemd-shutdown pivots back into an initramfs — which ostree/composefs
    # otherwise never gets, because dracut-initramfs-restore needs a
    # /boot/initramfs-$(uname -r).img that does not exist there. The shutdown
    # one then unmounts the volume once dracut's shutdown.sh has torn down
    # /oldroot and detached the loop. Both files carry the full rationale.
    #
    # Ordering: 99 in pre-pivot so the copy happens after every other hook has
    # finished writing into the initramfs; 50 in shutdown, which is after
    # dracut's own umount/losetup sweep either way (shutdown.sh runs the umount
    # loop to completion before it ever sources a shutdown hook).
    inst_hook pre-pivot 99 "$moddir/wootc-stage-shutdown.sh"
    inst_hook shutdown 50 "$moddir/wootc-umount-host.sh"
    # inst_hook dfatals on a missing source, but not on a hook that failed to
    # land — and a shutdown hook that is absent from the staged tree is the
    # difference between a clean hand-back and the corruption above, silently.
    local h
    for h in "/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh" \
             "/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"; do
        if [[ ! -f "$initdir$h" ]]; then
            dfatal "wootc-boot: $h did not install into the initramfs — Phase 2 could not hand a clean NTFS volume back to Windows"
            return 1
        fi
    done
    # `reboot -f -d -n` does not sync, and the staging hook copies a tree; both
    # hooks call sync explicitly, so the binary has to be there. mknod builds
    # the staged /dev, cp/rm/mkdir do the staging itself (all from 99base, but
    # named here so a base change cannot quietly remove them).
    inst_multiple sync mknod cp rm mkdir umount

    # losetup is all the hook needs — no staged binary, no closure. Target bootc
    # images already ship it (verified: yellowfin has /usr/sbin/losetup and no
    # qemu-nbd), which is exactly why root.disk is a raw image rather than VHDX.
    inst_multiple losetup

    # udevadm: the attach script settles udev and waits for the Windows NTFS
    # by-uuid symlink (a oneshot service gets one shot, no initqueue retry).
    inst_multiple mount mountpoint mkdir modprobe blockdev sleep udevadm
    # btrfs-progs, when the image has it: the attach hook registers btrfs
    # loop partitions with `btrfs device scan` so the udev readiness gate
    # (#35) clears. Optional — the udev builtin re-trigger is the fallback.
    inst_multiple -o btrfs
    # The userspace NTFS driver (ntfs-3g) for kernels without ntfs3 is added by
    # the deployer's regen via `dracut --install` — module-level inst does not
    # reliably resolve it there, but a regen-level --install does.
}
