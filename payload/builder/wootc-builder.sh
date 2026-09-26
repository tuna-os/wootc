#!/bin/sh
# Shared functions so unit tests can exercise the contract without PID 1.
TARGET=/dev/vda
SCRATCH=/dev/vdb
IPC=/dev/virtio-ports/wootc.ipc
STAGE=bootstrap

emit() {
    # One bounded JSON record per write on the private host-created channel.
    printf '%s\n' "$1"
    printf '%s\n' "$1" > "$IPC"
}

stage() {
    STAGE=$1
    emit "$(jq -nc --arg step "$STAGE" '{step:$step,pct:0}')"
    printf 'wootc-builder: stage=%s\n' "$STAGE"
}

stop_vm() {
    sync
    poweroff -f
    # PID 1 must never continue after a failed poweroff, especially after fail().
    while :; do sleep 60; done
}

failed() {
    trap - EXIT
    printf 'wootc-builder: FAIL: stage=%s reason=%s\n' "$STAGE" "$1" >&2
    if [ -c "$IPC" ]; then
        emit "$(jq -nc --arg msg "$1" --arg stage "$STAGE" \
            --arg run "${RUN_ID:-}" --arg install "${INSTALL_ID:-}" \
            '{step:"error",pct:0,msg:$msg,stage:$stage,runId:$run,installId:$install}')" || true
    fi
    stop_vm
}

read_contract() {
    IMAGE="" RUN_ID="" INSTALL_ID=""
    for token in $(cat /proc/cmdline); do
        case "$token" in
            wootc.image=*) IMAGE=${token#*=} ;;
            wootc.run_id=*) RUN_ID=${token#*=} ;;
            wootc.install_id=*) INSTALL_ID=${token#*=} ;;
        esac
    done
    validate_contract
}

validate_contract() {
    printf '%s\n' "$IMAGE" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9._:/-]*@sha256:[a-f0-9]{64}$' ||
        failed 'image must be pinned by its sha256 digest'
    for id in "$RUN_ID" "$INSTALL_ID"; do
        printf '%s\n' "$id" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9_-]{7,63}$' ||
            failed 'invalid run or install identity'
    done
}

blank_disk() {
    disk=$1 expected=$2
    [ -b "$disk" ] || failed "missing dedicated disk $disk"
    [ "$(cat "/sys/block/${disk##*/}/serial")" = "$expected" ] ||
        failed "unexpected disk identity for $disk"
    [ "$(lsblk -dn -o TYPE "$disk")" = disk ] || failed 'target is not a whole virtual disk'
    [ "$(blockdev --getsize64 "$disk")" -ge 34359738368 ] || failed "disk $disk needs at least 32 GiB"
    [ "$(lsblk -nr -o NAME "$disk" | wc -l)" -eq 1 ] || failed "disk $disk already has partitions"
    [ "$(wipefs --no-act --json "$disk" | jq '.signatures | length')" -eq 0 ] ||
        failed "disk $disk already contains data"
    if findmnt -rn -S "$disk" >/dev/null; then failed "disk $disk is mounted"; fi
}

prepare_storage() {
    # Validate BOTH identities and signatures before the first destructive call.
    blank_disk "$TARGET" wootc-root
    blank_disk "$SCRATCH" wootc-scratch
    mkfs.ext4 -q -F "$SCRATCH"
    mkdir -p /run/wootc-scratch /var/lib/containers /var/tmp /run/containers
    mount "$SCRATCH" /run/wootc-scratch
    mkdir -p /run/wootc-scratch/containers /run/wootc-scratch/tmp
    mount --bind /run/wootc-scratch/containers /var/lib/containers
    mount --bind /run/wootc-scratch/tmp /var/tmp
    for path in /var/lib/containers /var/tmp; do
        [ "$(findmnt -n -o FSTYPE -T "$path")" = ext4 ] || failed 'scratch is not disk-backed'
    done
    cat > /etc/containers/storage.conf <<'CONFIG'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
CONFIG
    cat > /etc/containers/containers.conf <<'CONFIG'
# Initramfs rootfs cannot be the old root of pivot_root.
[engine]
no_pivot_root = true
cgroup_manager = "cgroupfs"
events_logger = "file"
CONFIG
    export CONTAINERS_STORAGE_CONF=/etc/containers/storage.conf
}

verify_disk() {
    partprobe "$TARGET"
    mdev -s
    EFI_OK=0 ROOT_OK=0
    mkdir -p /run/wootc-verify
    for part in "${TARGET}"[0-9]*; do
        [ -b "$part" ] || continue
        fs=$(blkid -o value -s TYPE "$part" || true)
        case "$fs" in
            vfat|ext4|xfs|btrfs) ;;
            *) continue ;;
        esac
        mount -o ro "$part" /run/wootc-verify || failed 'cannot mount installed partition'
        if [ -s /run/wootc-verify/EFI/BOOT/BOOTX64.EFI ]; then EFI_OK=1; fi
        # An actual deployment must exist, not just a formatted root partition.
        for release in /run/wootc-verify/ostree/deploy/*/deploy/*/usr/lib/os-release; do
            if [ -s "$release" ]; then ROOT_OK=1; fi
        done
        umount /run/wootc-verify
    done
    [ "$EFI_OK" -eq 1 ] || failed 'installed disk has no fallback EFI loader'
    [ "$ROOT_OK" -eq 1 ] || failed 'installed disk has no verified ostree deployment'
    DISK_ID=$(blkid -o value -s PTUUID "$TARGET")
    [ -n "$DISK_ID" ] || failed 'installed disk has no partition identity'
}

builder_main() {
    trap 'failed "unexpected command failure"' EXIT
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devtmpfs dev /dev
    mkdir -p /dev/pts /dev/shm /sys/fs/cgroup
    mount -t devpts devpts /dev/pts
    mount -t tmpfs tmpfs /dev/shm
    mount -t cgroup2 none /sys/fs/cgroup
    for driver in virtio_pci virtio_blk virtio_console virtio_net ext4 xfs btrfs overlay; do
        modprobe "$driver"
    done
    mkdir -p /run/udev
    udevd --daemon
    udevadm trigger --action=add
    udevadm settle --timeout=30
    mdev -s
    mkdir -p /dev/virtio-ports
    for port in /sys/class/virtio-ports/*; do
        [ -f "$port/name" ] || continue
        [ "$(cat "$port/name")" = wootc.ipc ] || continue
        ln -sf "/dev/${port##*/}" "$IPC"
    done
    [ -c "$IPC" ] || failed 'private result channel is unavailable'
    read_contract
    stage storage
    prepare_storage
    stage network
    NETWORK=""
    for interface in /sys/class/net/*; do
        [ -e "$interface/device" ] || continue
        [ -z "$NETWORK" ] || failed "expected one network device"
        NETWORK=${interface##*/}
    done
    [ -n "$NETWORK" ] || failed "network device unavailable"
    ip link set "$NETWORK" up
    udhcpc -i "$NETWORK" -n -q -t 5 -T 3 || failed 'network lease failed'
    stage pulling
    podman pull "$IMAGE" || failed 'image download failed'
    stage installing
    # TARGET is a real guest block device. --via-loopback is for FILE targets.
    # Disk-backed /var/tmp is also needed INSIDE the installation container.
    podman run --rm --privileged --pid=host --ipc=host --network=host \
        --security-opt label=disable \
        -v /dev:/dev -v /sys:/sys -v /run/udev:/run/udev \
        -v /var/lib/containers:/var/lib/containers \
        -v /var/tmp:/var/tmp \
        "$IMAGE" bootc install to-disk --generic-image "$TARGET" || failed 'bootc install failed'
    stage verifying
    verify_disk
    sync
    umount /var/tmp /var/lib/containers /run/wootc-scratch
    emit "$(jq -nc --arg run "$RUN_ID" --arg install "$INSTALL_ID" \
        --arg image "$IMAGE" --arg disk "$DISK_ID" \
        '{type:"result",schemaVersion:1,status:"success",runId:$run,installId:$install,image:$image,diskId:$disk,filesystemVerified:true,efiVerified:true,accountOutcome:"image-default"}')"
    # Compatibility terminal: host must also bind the structured result to its run.
    emit 'STATUS=SUCCESS'
    trap - EXIT
    stop_vm
}
