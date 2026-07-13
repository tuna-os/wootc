#!/bin/bash
# module-setup.sh — dracut module for wootc deployer.
# Ensures the deployer script, init, and dependencies are in the initramfs.

check() {
    return 0
}

depends() {
    echo network kernel-modules
    return 0
}

install() {
    # Deployer script and init
    inst /usr/bin/wootc-deploy
    inst /init
    inst /usr/bin/fisherman

    # Required binaries (dracut auto-resolves libraries)
    inst_multiple \
        podman skopeo \
        ntfs3 mount.ntfs \
        parted mkfs.ext4 mkfs.vfat mkfs.xfs \
        losetup dmsetup \
        curl dhclient ip \
        mount umount reboot sleep

    # FUSE for ntfs-3g
    inst_multiple fusermount fusermount3
    inst_rules 99-fuse.rules

    # Loop module
    instmods loop
}
