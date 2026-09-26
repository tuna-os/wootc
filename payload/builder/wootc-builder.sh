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
    IMAGE="" RUN_ID="" INSTALL_ID="" ACCOUNT_MODE=image-default
    ACCOUNT_USER="" ACCOUNT_HASH="" ACCOUNT_OUTCOME=image-default
    for token in $(cat /proc/cmdline); do
        case "$token" in
            wootc.image=*) IMAGE=${token#*=} ;;
            wootc.run_id=*) RUN_ID=${token#*=} ;;
            wootc.install_id=*) INSTALL_ID=${token#*=} ;;
            wootc.account_mode=*) ACCOUNT_MODE=${token#*=} ;;
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

read_account() {
    case "$ACCOUNT_MODE" in
        image-default) return 0 ;;
        create) ;;
        *) failed 'unsupported account mode' ;;
    esac
    modprobe qemu_fw_cfg
    config=/sys/firmware/qemu_fw_cfg/by_name/opt/wootc/install/raw
    [ -r "$config" ] || failed 'private account input is unavailable'
    # Never echo this input or put its password hash into a child command line.
    account_json=$(head -c 8193 "$config")
    [ "${#account_json}" -le 8192 ] || failed 'account input is too large'
    validate_account "$account_json"
    unset account_json
}

validate_account() {
    account_json=$1
    printf '%s' "$account_json" | jq -e --arg run "$RUN_ID" --arg install "$INSTALL_ID" '
        type == "object" and .schemaVersion == 1 and
        .runId == $run and .installId == $install and
        (.username | type == "string") and (.passwordHash | type == "string") and
        (.username | test("\\A[a-z_][a-z0-9_-]{0,30}\\z")) and
        (.passwordHash | test("\\A\\$6\\$(rounds=[0-9]{4,9}\\$)?[a-zA-Z0-9./]{1,16}\\$[a-zA-Z0-9./]{86}\\z"))
    ' >/dev/null || failed 'invalid account input or identity'
    ACCOUNT_USER=$(printf '%s' "$account_json" | jq -r '.username')
    ACCOUNT_HASH=$(printf '%s' "$account_json" | jq -r '.passwordHash')
    case "$ACCOUNT_USER" in root|nobody|daemon|bin|sys) failed 'reserved account name' ;; esac
}

create_account() {  # mounted ostree root; same target-chroot contract as fisherman.
    sysroot=$1
    deployment=""
    for candidate in "$sysroot"/ostree/deploy/*/deploy/*; do
        [ -s "$candidate/usr/lib/os-release" ] || continue
        [ -z "$deployment" ] || failed 'account target has multiple deployments'
        deployment=$candidate
    done
    [ -n "$deployment" ] || failed 'account target has no supported deployment'
    state_var=${deployment%/deploy/*}/var
    # /home points into the stateroot's /var, not the deployment's seed /var.
    # Bind it before useradd so the created home survives the first real boot.
    mount --bind "$state_var" "$deployment/var"
    mount --bind /dev "$deployment/dev"
    if chroot "$deployment" id "$ACCOUNT_USER" >/dev/null 2>&1; then
        failed 'account already exists in the selected image'
    fi
    chroot "$deployment" getent group wheel >/dev/null || failed 'image has no wheel administrator group'
    chroot "$deployment" useradd --create-home --shell /bin/bash --groups wheel "$ACCOUNT_USER" ||
        failed 'account creation failed'
    printf '%s:%s\n' "$ACCOUNT_USER" "$ACCOUNT_HASH" | chroot "$deployment" chpasswd -e ||
        failed 'password setup failed'
    actual_hash=$(awk -F: -v user="$ACCOUNT_USER" '$1 == user { print $2 }' "$deployment/etc/shadow")
    [ "$actual_hash" = "$ACCOUNT_HASH" ] || failed 'password setup could not be verified'
    unset actual_hash ACCOUNT_HASH
    account_uid=$(chroot "$deployment" id -u "$ACCOUNT_USER")
    [ "$account_uid" -ge 1000 ] || failed 'created account is not a regular user'
    [ -d "$state_var/home/$ACCOUNT_USER" ] || failed 'created account has no persistent home'
    [ "$(stat -c %u "$state_var/home/$ACCOUNT_USER")" = "$account_uid" ] || failed 'home ownership is incorrect'
    mkdir -p "$deployment/etc/tmpfiles.d"
    printf 'Z /var/home/%s - %s %s - -\n' "$ACCOUNT_USER" "$ACCOUNT_USER" "$ACCOUNT_USER" > \
        "$deployment/etc/tmpfiles.d/wootc-user-home.conf"
    # Offline useradd may not retain SELinux labels when the helper kernel has
    # no active SELinux policy. Use the TARGET policy and tools explicitly.
    contexts=/etc/selinux/targeted/contexts/files/file_contexts
    if [ -f "$deployment$contexts" ]; then
        chroot "$deployment" setfiles -F "$contexts" /etc/passwd /etc/shadow /etc/group /etc/gshadow \
            "/var/home/$ACCOUNT_USER" /etc/tmpfiles.d/wootc-user-home.conf || failed 'account security labels failed'
    fi
    umount "$deployment/dev" "$deployment/var"
    ACCOUNT_OUTCOME=created
}

personalize_disk() {
    [ "$ACCOUNT_MODE" = create ] || return 0
    partprobe "$TARGET"
    udevadm settle --timeout=30
    mkdir -p /run/wootc-personalize
    for part in "${TARGET}"[0-9]*; do
        [ -b "$part" ] || continue
        fs=$(blkid -o value -s TYPE "$part" || true)
        case "$fs" in ext4|xfs|btrfs) ;; *) continue ;; esac
        mount "$part" /run/wootc-personalize
        if [ -d /run/wootc-personalize/ostree/deploy ]; then
            create_account /run/wootc-personalize
        fi
        umount /run/wootc-personalize
    done
    [ "$ACCOUNT_OUTCOME" = created ] || failed 'no supported account target'
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
    # PID 1 may inherit only /usr/bin:/bin. Target admin tools need sbin too.
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
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
    read_account
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
    stage personalizing
    personalize_disk
    stage verifying
    verify_disk
    sync
    umount /var/tmp /var/lib/containers /run/wootc-scratch
    emit "$(jq -nc --arg run "$RUN_ID" --arg install "$INSTALL_ID" \
        --arg image "$IMAGE" --arg disk "$DISK_ID" --arg account "$ACCOUNT_OUTCOME" --arg user "$ACCOUNT_USER" \
        '{type:"result",schemaVersion:1,status:"success",runId:$run,installId:$install,image:$image,diskId:$disk,filesystemVerified:true,efiVerified:true,accountOutcome:$account,username:$user}')"
    # Compatibility terminal: host must also bind the structured result to its run.
    emit 'STATUS=SUCCESS'
    trap - EXIT
    stop_vm
}
