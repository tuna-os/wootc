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
        podman skopeo \
        parted sfdisk partprobe wipefs \
        mkfs.ext4 mkfs.vfat mkfs.fat mkfs.xfs mkfs.btrfs mkswap \
        losetup dmsetup blockdev blkid lsblk \
        fsfreeze fstrim swapon swapoff fuser \
        useradd chpasswd restorecon \
        curl dhclient ip NetworkManager \
        mount umount mountpoint reboot sleep cat sed grep cut \
        shred chroot install udevadm jq

    # Kernel modules for NTFS and loop
    instmods ntfs3 loop
}
