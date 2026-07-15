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

    # Required binaries
    inst_multiple \
        podman skopeo \
        parted mkfs.ext4 mkfs.vfat mkfs.xfs mkfs.btrfs \
        losetup dmsetup \
        curl dhclient ip NetworkManager \
        mount umount reboot sleep cat sed grep cut shred blkid chroot

    # Kernel modules for NTFS and loop
    instmods ntfs3 loop
}
