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
    inst /usr/bin/fisherman

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
        mount umount mountpoint reboot sleep cat sed grep cut sync \
        shred chroot install udevadm jq truncate df awk qemu-ga journalctl \
        tee which basename date chown cp ln ls mkdir head wc tail

    # restorecon (policycoreutils) may not be installed in the build container.
    inst_multiple -o restorecon
    inst /usr/lib/systemd/systemd-cryptsetup

    # The 99wootc-boot dracut module payload, injected into the installed
    # system during verification (deploy.sh copies this tree into the
    # target's /usr/lib/dracut/modules.d/).
    inst /usr/lib/wootc/99wootc-boot/module-setup.sh
    inst /usr/lib/wootc/99wootc-boot/wootc-attach-loop.sh

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
    inst /usr/lib/wootc/migration/wootc-go-native

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
