#!/bin/sh
# Read-only export of the installed VM boot inputs, never a native-ready claim.
export_boot_inputs() {
    [ "$(cat /sys/block/vda/serial)" = wootc-root ] || failed 'unexpected export disk identity'
    [ "$(blockdev --getro "$TARGET")" = 1 ] || failed 'export target must be read-only'
    [ "$(blkid -o value -s PTUUID "$TARGET")" = "$EXPORT_DISK_ID" ] || failed 'export disk identity changed'
    partprobe "$TARGET"
    udevadm settle --timeout=30
    export_root=/run/wootc-export
    mkdir -p "$export_root"
    mount -t tmpfs tmpfs "$export_root"
    mkdir -p "$export_root/bundle"
    root_uuid="" deployment="" entry="" boot_root=""
    for part in "${TARGET}"[0-9]*; do
        [ -b "$part" ] || continue
        fs=$(blkid -o value -s TYPE "$part" || true)
        case "$fs" in
            xfs) options=ro,norecovery ;;
            ext4) options=ro,noload ;;
            btrfs) options=ro,nologreplay ;;
            vfat) options=ro ;;
            *) continue ;;
        esac
        point="$export_root/${part##*/}"
        mkdir -p "$point"
        mount -o "$options" "$part" "$point" || failed 'cannot mount export partition read-only'
        if [ -d "$point/ostree/deploy" ]; then
            [ -z "$root_uuid" ] || failed 'multiple installed roots in export target'
            root_uuid=$(blkid -o value -s UUID "$part")
            for candidate in "$point"/ostree/deploy/*/deploy/*; do
                [ -s "$candidate/usr/lib/os-release" ] || continue
                [ -z "$deployment" ] || failed 'multiple deployments in export target'
                resolved=$(readlink -f "$candidate")
                case "$resolved" in "$point"/*) ;; *) failed 'deployment escapes its partition' ;; esac
                deployment=$resolved
            done
        fi
        for base in "$point" "$point/boot"; do
            [ -d "$base/loader/entries" ] || continue
            resolved=$(readlink -f "$base")
            case "$resolved" in "$point"|"$point"/*) ;; *) failed 'boot directory escapes its partition' ;; esac
            base=$resolved
            for candidate in "$base"/loader/entries/*.conf; do
                [ -f "$candidate" ] || continue
                resolved=$(readlink -f "$candidate")
                case "$resolved" in "$base"/*) ;; *) failed 'boot entry escapes its partition' ;; esac
                [ ! -L "$candidate" ] || failed 'boot entry is a link'
                [ -z "$entry" ] || failed 'export requires one unambiguous installed boot entry'
                entry=$candidate boot_root=$base
            done
        done
    done
    [ -n "$root_uuid" ] && [ -n "$entry" ] || failed 'installed root or generic boot entry is unavailable'
    kernel=$(awk '$1 == "linux" { if (NF != 2) exit 1; print $2 }' "$entry")
    initramfs=$(awk '$1 == "initrd" { if (NF != 2) exit 1; print $2 }' "$entry")
    for path in "$kernel" "$initramfs"; do
        printf '%s\n' "$path" | grep -Eq '^/[A-Za-z0-9_./+-]+$' || failed 'unsupported boot artifact path'
        case "$path" in *..*|*//*) failed 'ambiguous boot artifact path' ;; esac
        resolved=$(readlink -f "$boot_root$path")
        case "$resolved" in "$boot_root"/*) ;; *) failed 'boot artifact escapes its partition' ;; esac
        [ -f "$resolved" ] && [ ! -L "$boot_root$path" ] || failed 'boot artifact is not a regular installed file'
    done
    total=$(( $(stat -c %s "$boot_root$kernel") + $(stat -c %s "$boot_root$initramfs") + $(stat -c %s "$entry") ))
    [ "$total" -le 536805376 ] || failed 'installed boot inputs exceed size limit'
    prepare_native_initramfs
    [ "$((total + $(stat -c %s "$export_root/bundle/native-initramfs")))" -le 536805376 ] || failed 'installed boot export exceeds size limit'
    cp "$boot_root$kernel" "$export_root/bundle/kernel"
    cp "$boot_root$initramfs" "$export_root/bundle/initramfs"
    cp "$entry" "$export_root/bundle/entry.conf"
    kernel_hash=$(sha256sum "$export_root/bundle/kernel"); kernel_hash=${kernel_hash%% *}
    initramfs_hash=$(sha256sum "$export_root/bundle/initramfs"); initramfs_hash=${initramfs_hash%% *}
    entry_hash=$(sha256sum "$export_root/bundle/entry.conf"); entry_hash=${entry_hash%% *}
    native_hash=$(sha256sum "$export_root/bundle/native-initramfs"); native_hash=${native_hash%% *}
    jq -nc --arg run "$RUN_ID" --arg install "$INSTALL_ID" --arg image "$IMAGE" \
        --arg disk "$EXPORT_DISK_ID" --arg root "$root_uuid" --arg kernel "$kernel_hash" \
        --arg initramfs "$initramfs_hash" --arg entry "$entry_hash" --arg native "$native_hash" --arg version "$kver" \
        '{schemaVersion:1,runId:$run,installId:$install,image:$image,diskId:$disk,rootUuid:$root,kernelVersion:$version,nativeReady:false,nativeClosurePrepared:true,files:{kernel:$kernel,initramfs:$initramfs,"entry.conf":$entry,"native-initramfs":$native}}' > "$export_root/bundle/manifest.json"
    [ -c /dev/virtio-ports/wootc.export ] || failed 'private boot export channel unavailable'
    tar -C "$export_root/bundle" -cf /dev/virtio-ports/wootc.export manifest.json entry.conf kernel initramfs native-initramfs
    emit 'STATUS=SUCCESS'
    trap - EXIT
    stop_vm
}

# Build in an ephemeral overlay of the installed deployment. Neither dracut nor
# its config/scripts can modify the person's read-only image or generic initrd.
prepare_native_initramfs() {
    [ -n "$deployment" ] || failed 'installed deployment is unavailable for native closure'
    kver=$(awk '$1 == "version" { if (NF != 2) exit 1; print $2 }' "$entry")
    printf '%s\n' "$kver" | grep -Eq '^[A-Za-z0-9_+.-]{1,128}$' || failed 'unsupported installed kernel version'
    [ -f "$deployment/usr/lib/modules/$kver/vmlinuz" ] || failed 'installed kernel has no matching module tree'
    modules=$(readlink -f "$deployment/usr/lib/modules/$kver")
    case "$modules" in "$deployment"/*) ;; *) failed 'kernel module tree escapes the deployment' ;; esac
    cmp "$boot_root$kernel" "$deployment/usr/lib/modules/$kver/vmlinuz" || failed 'boot kernel and module tree differ'
    overlay="$export_root/target"
    mkdir -p "$export_root/upper" "$export_root/work" "$overlay"
    mount -t overlay overlay -o "lowerdir=$deployment,upperdir=$export_root/upper,workdir=$export_root/work" "$overlay"
    mkdir -p "$overlay/usr/lib/dracut/modules.d/99wootc-boot"
    cp -a /lib/wootc-native-boot/. "$overlay/usr/lib/dracut/modules.d/99wootc-boot/"
    for fs in dev proc sys; do
        mount --bind "/$fs" "$overlay/$fs"
    done
    mount -t tmpfs tmpfs "$overlay/run"
    mount -t tmpfs tmpfs "$overlay/var"
    mkdir -p "$overlay/var/tmp" "$overlay/run/wootc"
    ntfs_bins=""
    for binary in /usr/bin/ntfs-3g /usr/sbin/ntfs-3g /bin/ntfs-3g /sbin/ntfs-3g; do
        if [ -x "$overlay$binary" ]; then ntfs_bins=$binary; break; fi
    done
    ntfs_module=""
    if [ -z "$ntfs_bins" ]; then
        ntfs_module=$(chroot "$overlay" modinfo -k "$kver" -F filename ntfs3) ||
            failed 'installed kernel and userspace have no NTFS driver'
    fi
    # Match the native deployer's explicit ostree + attach modules. Do not
    # inject foreign userspace binaries or libraries into this closure.
    mkdir -p "$overlay/run/wootc/nofw"
    timeout 900 chroot "$overlay" dracut --force --no-hostonly --kver "$kver" \
        --add 'wootc-boot ostree' --install "$ntfs_bins" --fwdir /run/wootc/nofw \
        --omit 'plymouth lvm mdraid multipath iscsi nfs cifs fcoe fcoe-uefi resume rescue network network-legacy network-manager kernel-network-modules cellular qemu-net memstrack nvmf nvdimm dm crypt systemd-cryptsetup clevis clevis-pin-null clevis-pin-sss clevis-pin-tang clevis-pin-tpm2' \
        /run/wootc/native-initramfs.img || failed 'target native initramfs construction failed'
    mkdir -p "$overlay/run/wootc/verify"
    timeout 60 chroot "$overlay" sh -c 'cd /run/wootc/verify && lsinitrd --unpack /run/wootc/native-initramfs.img' ||
        failed 'native initramfs extraction failed'
    unpacked="$overlay/run/wootc/verify"
    for path in usr/lib/wootc/wootc-attach-loop.sh \
        usr/lib/systemd/system/wootc-attach.service \
        lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh \
        lib/dracut/hooks/shutdown/50-wootc-umount-host.sh; do
        [ -s "$unpacked/$path" ] || failed 'native initramfs is missing a required boot or shutdown input'
    done
    [ -L "$unpacked/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service" ] ||
        failed 'native initramfs attach service is not enabled'
    for module in loop virtio_scsi virtio_pci sd_mod ahci nvme; do
        module_path=$(chroot "$overlay" modinfo -k "$kver" -F filename "$module") ||
            failed 'required native storage module is unavailable'
        if [ "$module_path" != "(builtin)" ]; then
            [ -s "$unpacked$module_path" ] ||
                failed 'native initramfs omitted a required storage module'
        fi
    done
    [ -x "$unpacked/usr/lib/ostree/ostree-prepare-root" ] ||
        failed 'native initramfs omitted ostree root preparation'
    if [ -n "$ntfs_bins" ]; then
        # Execute the unpacked binary through its own loader/libraries, rather
        # than treating an archive filename as proof of the userspace closure.
        timeout 10 chroot "$unpacked" "$ntfs_bins" --version >/dev/null 2>&1 ||
            failed 'native initramfs NTFS executable or library closure is broken'
    elif [ "$ntfs_module" != "(builtin)" ]; then
        [ -s "$unpacked$ntfs_module" ] ||
            failed 'native initramfs omitted the NTFS kernel module'
    fi
    cp "$overlay/run/wootc/native-initramfs.img" "$export_root/bundle/native-initramfs"
}
