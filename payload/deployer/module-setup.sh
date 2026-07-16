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
        losetup dmsetup blockdev blkid lsblk \
        fsfreeze fstrim swapon swapoff fuser \
        useradd chpasswd \
        curl dhclient ip NetworkManager \
        mount umount mountpoint reboot sleep cat sed grep cut \
        shred chroot install udevadm jq truncate

    # restorecon (policycoreutils) may not be installed in the build container.
    inst_multiple -o restorecon

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
    inst_simple "$(readlink -f /etc/pki/tls/certs/ca-bundle.crt)" \
        /etc/pki/tls/certs/ca-bundle.crt

    # Kernel modules for NTFS and loop
    instmods ntfs3 loop
}
