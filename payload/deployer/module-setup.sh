#!/bin/bash
# module-setup.sh — dracut module for wootc deployer initramfs.
# Ensures the deployer script, fisherman, and network stack
# are included in the initramfs.

check() {
    return 0
}

depends() {
    echo "network kernel-modules"
    return 0
}

install() {
    # dracut generates /init itself; run the deployer once networking is online.
    inst /usr/bin/wootc-deploy
    # dracut defines moddir before invoking module install hooks.
    # shellcheck disable=SC2154
    inst "$moddir/deploy-hook.sh" /usr/lib/dracut/hooks/initqueue/online/99-wootc-deploy.sh
    # The SAME hook at initqueue/settled, so a machine with no network — a
    # laptop whose Wi-Fi does not exist in this initramfs — still starts
    # deploying (docs/branding-and-distribution.md §3). The hook's
    # /run/wootc-deployer-started guard keeps the two instances from
    # double-starting, and deploy.sh owns the decision from there: offline
    # bundle found → proceed with zero network; none → bounded network wait.
    inst "$moddir/deploy-hook.sh" /usr/lib/dracut/hooks/initqueue/settled/99-wootc-deploy.sh
    # First paint happens BEFORE udev settle + network wait: the black-screen
    # stretch between GRUB and the deployer's animated splash is the moment a
    # nervous user is most primed to see "my PC is broken".
    inst "$moddir/early-splash.sh" /usr/lib/dracut/hooks/pre-trigger/10-wootc-early-splash.sh
    inst /usr/bin/fisherman

    # Drop systemd's GPT auto-discovery generator.
    #
    # This initramfs is a one-shot DEPLOYER: it runs entirely from the initrd
    # and never switches root, so no boot path passes root= (see the deployer
    # menuentries in installer_esp.go and setup-wootc.ps1 — all of them pass
    # only wootc.* args). systemd does not know that, so gpt-auto-generator
    # synthesises a dev-gpt-auto-root.device, initrd-root-fs.target waits on
    # it, the device never appears, and at the 90s device timeout systemd
    # prints the full failure cascade and "Entering emergency mode" over the
    # friendly splash:
    #
    #   Timed out waiting for device dev-gpt-auto-root.device
    #    -> Dependency failed for sysroot.mount - Root Partition
    #    -> Dependency failed for initrd-root-fs.target
    #    -> Entering emergency mode.
    #
    # It is cosmetic — dracut-initqueue keeps running our hook and the deploy
    # completes — but it looks exactly like a fatal error to a user watching
    # their machine migrate, which is the worst possible moment for it.
    #
    # rd.systemd.gpt_auto=0 is the documented switch, but systemd's generators
    # read /proc/cmdline only; dracut's --kernel-cmdline lands in
    # /etc/cmdline.d/, which just dracut's own shell helpers parse. Setting it
    # for real would mean editing every menuentry template in both the Go and
    # PowerShell installers and remembering to do so for every future one.
    # Removing the generator here fixes all boot paths at the source. The
    # deployer mounts everything it needs explicitly, so nothing else the
    # generator provides (ESP/home/srv/swap auto-mount) is wanted either.
    #
    # 99wootc sorts after 00systemd, so the generator is already installed
    # into $initdir by the time this runs. dracut defines initdir, like
    # moddir above, before invoking module install hooks.
    # shellcheck disable=SC2154
    rm -f "$initdir/usr/lib/systemd/system-generators/systemd-gpt-auto-generator"

    # Required binaries. fisherman's host-tool contract (checkRequiredTools in
    # cmd/fisherman/main.go plus its runner.Run call sites) needs sfdisk,
    # mkfs.fat, partprobe, blockdev, fsfreeze, fstrim, wipefs, lsblk, mkswap,
    # swapon/swapoff, fuser, useradd, chpasswd, restorecon. deploy.sh itself
    # needs install, mountpoint, udevadm, jq.
    inst_multiple \
        podman skopeo conmon crun \
        parted sfdisk partprobe wipefs \
        mkfs.ext4 mkfs.vfat mkfs.fat mkfs.xfs mkfs.btrfs mkswap \
        losetup qemu-img qemu-nbd dmsetup cryptsetup systemd-cryptenroll blockdev blkid lsblk \
        fsfreeze fstrim swapon swapoff fuser \
        useradd chpasswd \
        curl dhclient ip NetworkManager \
        mount umount mountpoint reboot sleep cat sed grep cut sync tr \
        shred chroot install udevadm jq truncate fallocate dd df awk qemu-ga journalctl \
        tee which basename date chown cp ln ls mkdir head wc tail

    # restorecon (policycoreutils) may not be installed in the build container.
    # ldd is a glibc-common shell script, not a binary pulled in by any
    # library dependency — without naming it here the initramfs has no ldd at
    # all, which is how the qemu-ga closure builder aborted with exit 127
    # (bluefin-dakota-win11pro, run 30707067821). deploy.sh's dso_closure()
    # no longer needs it (it drives the loader directly), so this is the
    # belt-and-braces second path, hence -o.
    inst_multiple -o restorecon ldd
    inst /usr/lib/systemd/systemd-cryptsetup

    # The 99wootc-boot dracut module payload, injected into the installed
    # system during verification (deploy.sh copies this tree into the
    # target's /usr/lib/dracut/modules.d/).
    inst /usr/lib/wootc/99wootc-boot/module-setup.sh
    inst /usr/lib/wootc/99wootc-boot/wootc-attach-loop.sh
    # THE UNIT FILE ITSELF — do not drop this. It was missing here after the
    # initqueue-hook→systemd-service switch, so the Phase-2 regen's
    # inst_simple "$moddir/wootc-attach.service" found nothing, silently
    # installed no unit, yet the wants symlink was still created — a DANGLING
    # symlink. systemd then had nothing to start: root.disk never attached and
    # every Phase-2 boot timed out into the emergency shell. Proven by reading
    # the booted ESP initramfs out of data.qcow2: the .wants symlink was present
    # but usr/lib/systemd/system/wootc-attach.service was absent.
    inst /usr/lib/wootc/99wootc-boot/wootc-attach.service
    # The Phase-2 shutdown pair. deploy.sh stages these BY HAND into the
    # early-cpio overlay on the branches that cannot regenerate the target's
    # initramfs, so they have to survive into the deployer initramfs as files,
    # exactly like wootc-attach-loop.sh and the unit above. Omitting them here
    # is the same class of bug as the dangling-wants one described above: the
    # overlay builder would find nothing to copy, Phase 2 would boot fine, and
    # the breakage would only show up as a corrupt Windows on the way back.
    inst /usr/lib/wootc/99wootc-boot/wootc-stage-shutdown.sh
    inst /usr/lib/wootc/99wootc-boot/wootc-umount-host.sh

    # User Data Bridge (native passthrough) unit files, injected into the
    # installed system during verification the same way as 99wootc-boot.
    inst /usr/lib/wootc/migration/wootc-host-bind.service
    inst /usr/lib/wootc/migration/wootc-passthrough.service
    inst /usr/lib/wootc/migration/wootc-mount-user-dirs
    inst /usr/lib/wootc/migration/wootc-umount-user-dirs
    inst /usr/lib/wootc/migration/wootc-steam-bridge
    inst /usr/lib/wootc/migration/wootc-import-browser
    inst /usr/lib/wootc/migration/wootc-convert-dir
    inst /usr/lib/wootc/migration/org.tunaos.wootc.policy
    inst /usr/lib/wootc/migration/wootc-esp-sync
    inst /usr/lib/wootc/migration/wootc-esp-sync.service
    inst /usr/lib/wootc/migration/wootc-esp-sync.path
    inst /usr/lib/wootc/migration/wootc-shim-trust
    inst /usr/lib/wootc/migration/wootc-apply-look
    inst /usr/lib/wootc/migration/wootc-apply-look.desktop
    inst /usr/lib/wootc/migration/wootc-detect-apps
    inst /usr/lib/wootc/migration/wootc-office-bridge
    inst /usr/lib/wootc/migration/wootc-wsl-bridge
    inst /usr/lib/wootc/migration/wootc-wifi-bridge
    inst /usr/lib/wootc/migration/wootc-wifi-import.service
    inst /usr/lib/wootc/migration/wootc-import
    inst /usr/lib/wootc/migration/wootc-import-gui
    inst /usr/lib/wootc/migration/wootc-import.desktop
    inst /usr/lib/wootc/migration/wootc-manifest
    inst /usr/lib/wootc/migration/wootc-manifest-gui
    inst /usr/lib/wootc/migration/wootc-manifest.desktop
    # First-login welcome (North Star landing). Omitting a migration payload
    # here while deploy.sh stages it is exactly how the whole 7d45616 smoke
    # matrix died ("ABORT: line 2616: install ... wootc-welcome"): the file
    # was referenced by every deploy and present in none of the initramfses.
    inst /usr/lib/wootc/migration/wootc-welcome
    inst /usr/lib/wootc/migration/wootc-welcome.desktop
    inst /usr/lib/wootc/migration/wootc-identity
    inst /usr/lib/wootc/migration/wootc-user-gui
    inst /usr/lib/wootc/migration/wootc-user.desktop
    inst /usr/lib/wootc/migration/wootc-selection
    inst /usr/lib/wootc/migration/wootc-go-native
    inst /usr/lib/wootc/migration/wootc-go-native-gui
    inst /usr/lib/wootc/migration/wootc-go-native.desktop
    inst /usr/lib/wootc/migration/wootc-e2e-phase3-dispatch
    inst /usr/lib/wootc/migration/wootc-e2e-phase3.service
    inst /usr/lib/wootc/migration/wootc-e2e-phase3.path
    inst /usr/lib/wootc/migration/wootc-firstboot-evidence
    inst /usr/lib/wootc/migration/wootc-firstboot-evidence.service

    # podman network backend for podman run (bootc install stage).
    inst_multiple -o \
        /usr/libexec/podman/netavark \
        /usr/libexec/podman/aardvark-dns

    # podman/skopeo runtime prerequisites: without policy.json podman pull
    # fails instantly with exit 125, and Go's TLS stack needs the CA bundle.
    inst_multiple -o \
        /etc/containers/policy.json \
        /etc/containers/registries.conf \
        /etc/containers/registries.conf.d/*.conf
    inst_simple /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
        /etc/pki/tls/certs/ca-bundle.crt

    # Kernel modules for NTFS and VHDX-through-NBD attachment.
    instmods ntfs3 nbd
}
