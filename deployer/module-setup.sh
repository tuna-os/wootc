#!/bin/bash
# module-setup.sh — dracut module for wootc deployer initramfs.
# Ensures the deployer script, init, fisherman, and network stack
# are included in the initramfs.

check() {
    return 0
}

depends() {
    echo "network kernel-modules"
    return 0
}

install() {
    # Deployer script and init
    inst /usr/bin/wootc-deploy
    inst /init
    inst /usr/bin/fisherman

    # Required binaries
    inst_multiple \
        podman skopeo \
        parted mkfs.ext4 mkfs.vfat mkfs.xfs mkfs.btrfs \
        losetup dmsetup \
        curl dhclient ip NetworkManager \
        mount umount reboot sleep cat sed

    # Kernel modules for NTFS and loop
    instmods ntfs3 loop
}
