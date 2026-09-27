#!/bin/sh
# Authenticated initrd functions only. No guest request accepts paths/commands.
# No invocation from the builder until the explicit observer contract is armed.

observer_identity() {
    value=$(timeout 2 stat -c '%d:%i' "$1") || return 1
    printf '%s\n' "$value" | grep -Eq '^[0-9]+:[0-9]+$' || return 1
    printf '%s\n' "$value"
}

observer_directory() {
    cursor=$1 depth=0
    case "$cursor" in /*) ;; *) return 1 ;; esac
    canonical=$(timeout 2 readlink -f "$cursor") || return 1
    [ "$canonical" = "$cursor" ] || return 1
    while :; do
        facts=$(timeout 2 stat -c '%u %f' "$cursor") || return 1
        uid=${facts%% *} mode=${facts#* }
        [ "$uid" = 0 ] || return 1
        printf '%s\n' "$mode" | grep -Eq '^[0-9a-f]+$' || return 1
        bits=$((0x$mode))
        [ "$((bits & 61440))" -eq 16384 ] && [ "$((bits & 18))" -eq 0 ] || return 1
        [ "$cursor" != / ] || return 0
        cursor=${cursor%/*}; [ -n "$cursor" ] || cursor=/
        depth=$((depth + 1)); [ "$depth" -lt 64 ] || return 1
    done
}

observer_is_mounted() {
    inventory=$(timeout 2 head -c 2097153 /proc/self/mountinfo) || return 2
    [ -n "$inventory" ] && [ "${#inventory}" -le 2097152 ] || return 2
    printf '%s\n' "$inventory" | awk -v target="$1" '
      NF < 10 || $3 !~ /^[0-9]+:[0-9]+$/ { bad=1 }
      $5 == target { count++ }
      END { if (bad || count>1) exit 2; if (count==1) exit 0; exit 1 }
    '
}

observer_view_readback() {
    target=$1 expected_inode=$2
    observer_is_mounted "$target" || return 1
    current=$(observer_identity "$target") || return 1
    [ "$current" = "$expected_inode" ] || return 1
    row=$(timeout 2 findmnt --json --output TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN --mountpoint "$target") || return 1
    [ "${#row}" -le 131072 ] || return 1
    printf '%s' "$row" | jq -e --arg target "$target" '
      type=="object" and (keys==["filesystems"]) and
      (.filesystems|type=="array" and length==1) and
      .filesystems[0] as $r | $r.target==$target and
      ($r.source|type=="string" and length>0) and
      ($r["maj:min"]|type=="string" and test("^[0-9]+:[0-9]+$")) and
      ($r.options|split(",")|index("ro")!=null and index("rw")==null)
    ' >/dev/null || return 1
}

observer_bind_view() {
    kind=$1 source=$2 target=$3
    # Sources and target suffixes are fixed by the authenticated caller.
    [ -n "${OBS_DEPLOYMENT:-}" ] || return 1
    case "$kind" in
        input) [ "$source" = /usr/lib/wootc-observer ] && [ "$target" = "$OBS_DEPLOYMENT/run/wootc-observer-input" ] || return 1 ;;
        sysroot) [ "$source" = /run/wootc-personalize ] && [ "$target" = "$OBS_DEPLOYMENT/run/wootc-observer-sysroot" ] || return 1 ;;
        proc) [ "$source" = /proc ] && [ "$target" = "$OBS_DEPLOYMENT/proc" ] || return 1 ;;
        sys) [ "$source" = /sys ] && [ "$target" = "$OBS_DEPLOYMENT/sys" ] || return 1 ;;
        usr) [ "$source" = "$OBS_DEPLOYMENT/usr" ] && [ "$target" = "$OBS_DEPLOYMENT/usr" ] || return 1 ;;
        boot) [ "$source" = /run/wootc-personalize/boot ] && [ "$target" = "$OBS_DEPLOYMENT/run/wootc-observer-sysroot/boot" ] || return 1 ;;
        *) return 1 ;;
    esac
    observer_directory "$source" && observer_directory "${target%/*}" || return 1
    if observer_is_mounted "$target"; then return 1; else status=$?; [ "$status" -eq 1 ] || return 1; fi
    if [ "$kind" = proc ] || [ "$kind" = sys ] || [ "$kind" = boot ] || [ "$kind" = usr ]; then
        observer_directory "$target" || return 1
        contents=$(timeout 2 ls -A "$target") || return 1
        if [ "$kind" != boot ] && [ "$kind" != usr ]; then [ -z "$contents" ] || return 1; fi
    else
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
        mkdir -m 700 "$target" || return 1
    fi
    original=$(observer_identity "$target") || return 1
    from=$(observer_identity "$source") || return 1
    # Record ownership before the first side effect; failed calls may have acted.
    case "$kind" in
        input) OBS_INPUT="$target" OBS_INPUT_OWN="$original" OBS_INPUT_SOURCE="$from" ;;
        sysroot) OBS_SYSROOT="$target" OBS_SYSROOT_OWN="$original" OBS_SYSROOT_SOURCE="$from" ;;
        proc) OBS_PROC="$target" OBS_PROC_OWN="$original" OBS_PROC_SOURCE="$from" ;;
        sys) OBS_SYS="$target" OBS_SYS_OWN="$original" OBS_SYS_SOURCE="$from" ;;
        usr) OBS_USR="$target" OBS_USR_OWN="$original" OBS_USR_SOURCE="$from" ;;
        boot) OBS_BOOT_VIEW="$target" OBS_BOOT_VIEW_OWN="$original" OBS_BOOT_VIEW_SOURCE="$from" ;;
    esac
    timeout 3 mount --bind "$source" "$target" || return 1
    observer_is_mounted "$target" || return 1
    [ "$(observer_identity "$target")" = "$from" ] || return 1
    timeout 3 mount -o remount,bind,ro "$target" || return 1
    observer_view_readback "$target" "$from" || return 1
    if [ "$kind" = proc ]; then
        row=$(timeout 2 findmnt --noheadings --raw --output FSTYPE --mountpoint "$target") || return 1
        [ "$row" = proc ] || return 1
        observer_proc_current "$target" || return 1
    elif [ "$kind" = sys ]; then
        row=$(timeout 2 findmnt --noheadings --raw --output FSTYPE --mountpoint "$target") || return 1
        [ "$row" = sysfs ] || return 1
        observer_sys_current "$target" || return 1
    fi
}

observer_proc_current() {
    target=$1
    # Current helper PID/kernel proc view, not a directory merely named proc.
    native=$(timeout 2 head -c 4096 "/proc/$$/stat") || return 1
    viewed=$(timeout 2 head -c 4096 "$target/$$/stat") || return 1
    case "$native:$viewed" in "$$ ("*":""$$ ("*) ;; *) return 1 ;; esac
    native_start=$(printf '%s' "$native" | sed 's/^[0-9]* (.*) //' | awk '{print $20}') || return 1
    viewed_start=$(printf '%s' "$viewed" | sed 's/^[0-9]* (.*) //' | awk '{print $20}') || return 1
    printf '%s\n' "$native_start" | grep -Eq '^[0-9]+$' || return 1
    [ "$native_start" = "$viewed_start" ] || return 1
}

observer_sys_current() {
    target=$1
    # Compare the actual current device/class directories, not a pathname token.
    for relative in dev/block devices class/block; do
        native=$(observer_identity "/sys/$relative") || return 1
        viewed=$(observer_identity "$target/$relative") || return 1
        [ "$native" = "$viewed" ] || return 1
    done
    native=$(timeout 2 head -c 131073 /sys/devices/system/cpu/online) || return 1
    viewed=$(timeout 2 head -c 131073 "$target/devices/system/cpu/online") || return 1
    [ -n "$native" ] && [ "${#native}" -le 131072 ] && [ "$native" = "$viewed" ] || return 1
    printf '%s\n' "$native" | grep -Eq '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$' || return 1
}

observer_release_view() {
    target=$1 own=$2 source=$3 created=$4
    [ -n "$target" ] || return 0
    if observer_is_mounted "$target"; then
        [ "$(observer_identity "$target")" = "$source" ] || return 1
        timeout 3 umount "$target" || return 1
        if observer_is_mounted "$target"; then return 1; else status=$?; [ "$status" -eq 1 ] || return 1; fi
    else
        status=$?; [ "$status" -eq 1 ] || return 1
    fi
    [ "$(observer_identity "$target")" = "$own" ] || return 1
    observer_directory "$target" || return 1
    if [ "$created" = true ]; then rmdir "$target" || return 1; fi
}

observer_cleanup_views() {
    failed=0
    observer_release_view "${OBS_USR:-}" "${OBS_USR_OWN:-}" "${OBS_USR_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_BOOT_VIEW:-}" "${OBS_BOOT_VIEW_OWN:-}" "${OBS_BOOT_VIEW_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_SYS:-}" "${OBS_SYS_OWN:-}" "${OBS_SYS_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_PROC:-}" "${OBS_PROC_OWN:-}" "${OBS_PROC_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_SYSROOT:-}" "${OBS_SYSROOT_OWN:-}" "${OBS_SYSROOT_SOURCE:-}" true || failed=1
    observer_release_view "${OBS_INPUT:-}" "${OBS_INPUT_OWN:-}" "${OBS_INPUT_SOURCE:-}" true || failed=1
    [ "$failed" -eq 0 ]
}

observer_prepare_boot() {
    # Inspect actual installed partitions, never labels or a seed /boot directory.
    OBS_ROOT_PART=$1 OBS_BOOT_SELECTED_PART='' OBS_BOOT_ORIGINAL=/run/wootc-personalize/boot
    observer_directory "$OBS_BOOT_ORIGINAL" || return 1
    OBS_BOOT_ORIGINAL_OWN=$(observer_identity "$OBS_BOOT_ORIGINAL") || return 1
    if observer_is_mounted "$OBS_BOOT_ORIGINAL"; then return 1; else status=$?; [ "$status" -eq 1 ] || return 1; fi
    OBS_BOOT_COUNT=0
    for OBS_BOOT_CANDIDATE in /dev/vda[0-9]*; do
        OBS_BOOT_COUNT=$((OBS_BOOT_COUNT + 1)); [ "$OBS_BOOT_COUNT" -le 128 ] || return 1
        [ -b "$OBS_BOOT_CANDIDATE" ] || continue
        [ "$OBS_BOOT_CANDIDATE" != "$OBS_ROOT_PART" ] || continue
        OBS_BOOT_FS=$(timeout 2 blkid -o value -s TYPE "$OBS_BOOT_CANDIDATE") || return 1
        case "$OBS_BOOT_FS" in ext4|xfs) ;; *) continue ;; esac
        timeout 3 mount -o ro "$OBS_BOOT_CANDIDATE" "$OBS_BOOT_ORIGINAL" || return 1
        observer_is_mounted "$OBS_BOOT_ORIGINAL" || return 1
        OBS_BOOT_PROBE_SOURCE=$(observer_identity "$OBS_BOOT_ORIGINAL") || return 1
        OBS_BOOT_ORIGINAL_SOURCE=$OBS_BOOT_PROBE_SOURCE
        OBS_BOOT_ORIGINAL_ACTIVE=true
        OBS_BOOT_ROW=$(timeout 2 findmnt --json --output TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN --mountpoint "$OBS_BOOT_ORIGINAL") || return 1
        [ "${#OBS_BOOT_ROW}" -le 131072 ] || return 1
        printf '%s' "$OBS_BOOT_ROW" | jq -e --arg source "$OBS_BOOT_CANDIDATE" --arg target "$OBS_BOOT_ORIGINAL" '
          .filesystems|type=="array" and length==1 and .[0].source==$source and .[0].target==$target and
          (.[0].options|split(",")|index("ro")!=null and index("rw")==null)
        ' >/dev/null || return 1
        if [ -d "$OBS_BOOT_ORIGINAL/loader/entries" ]; then
            OBS_BOOT_ENTRIES=$(timeout 2 find "$OBS_BOOT_ORIGINAL/loader/entries" -maxdepth 1 -type f -name '*.conf') || return 1
            [ "${#OBS_BOOT_ENTRIES}" -le 131072 ] || return 1
            if [ -n "$OBS_BOOT_ENTRIES" ]; then
                [ -z "$OBS_BOOT_SELECTED_PART" ] || return 1
                OBS_BOOT_SELECTED_PART=$OBS_BOOT_CANDIDATE
                OBS_BOOT_SELECTED_SOURCE=$OBS_BOOT_PROBE_SOURCE
            fi
        fi
        observer_release_view "$OBS_BOOT_ORIGINAL" "$OBS_BOOT_ORIGINAL_OWN" "$OBS_BOOT_PROBE_SOURCE" false || return 1
        OBS_BOOT_ORIGINAL_ACTIVE=false
    done
    [ -n "$OBS_BOOT_SELECTED_PART" ] || return 1
    OBS_BOOT_ORIGINAL_SOURCE=$OBS_BOOT_SELECTED_SOURCE OBS_BOOT_ORIGINAL_ACTIVE=true
    timeout 3 mount -o ro "$OBS_BOOT_SELECTED_PART" "$OBS_BOOT_ORIGINAL" || return 1
    observer_view_readback "$OBS_BOOT_ORIGINAL" "$OBS_BOOT_SELECTED_SOURCE" || return 1
    OBS_BOOT_MAJOR=$(printf '%s' "$row" | jq -er '.filesystems[0]["maj:min"]') || return 1
}

observer_install_owned() {
    # Sole caller is create_account while its measured persistent /var bind lives.
    OBS_DEPLOYMENT=$1 OBS_ROOT_PART=$2
    observer_directory /usr/lib/wootc-observer || return 1
    (cd /usr/lib/wootc-observer && timeout 3 sha256sum -c closure.sha256) >/dev/null || return 1
    OBS_CATALOGUE_SHA=$(timeout 2 sha256sum /usr/lib/wootc-observer/catalogue.json) || return 1
    OBS_CATALOGUE_SHA=${OBS_CATALOGUE_SHA%% *}
    printf '%s\n' "$OBS_CATALOGUE_SHA" | grep -Eq '^[0-9a-f]{64}$' || return 1
    OBS_DISK_ID=$(timeout 2 blkid -o value -s PTUUID /dev/vda) || return 1
    printf '%s\n' "$OBS_DISK_ID" | grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' || return 1
    OBS_INSTALL_STATUS=0
    observer_prepare_boot "$OBS_ROOT_PART" || OBS_INSTALL_STATUS=1
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then
        observer_bind_view input /usr/lib/wootc-observer "$OBS_DEPLOYMENT/run/wootc-observer-input" || OBS_INSTALL_STATUS=1
        OBS_INPUT_MAJOR=$(printf '%s' "${row:-}" | jq -er '.filesystems[0]["maj:min"]') || OBS_INSTALL_STATUS=1
        OBS_INPUT_MOUNT_SOURCE=$(printf '%s' "${row:-}" | jq -er '.filesystems[0].source') || OBS_INSTALL_STATUS=1
    fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then
        observer_bind_view sysroot /run/wootc-personalize "$OBS_DEPLOYMENT/run/wootc-observer-sysroot" || OBS_INSTALL_STATUS=1
        OBS_ROOT_MAJOR=$(printf '%s' "${row:-}" | jq -er '.filesystems[0]["maj:min"]') || OBS_INSTALL_STATUS=1
    fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then
        observer_bind_view boot /run/wootc-personalize/boot "$OBS_DEPLOYMENT/run/wootc-observer-sysroot/boot" || OBS_INSTALL_STATUS=1
    fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then observer_bind_view proc /proc "$OBS_DEPLOYMENT/proc" || OBS_INSTALL_STATUS=1; fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then observer_bind_view sys /sys "$OBS_DEPLOYMENT/sys" || OBS_INSTALL_STATUS=1; fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then observer_bind_view usr "$OBS_DEPLOYMENT/usr" "$OBS_DEPLOYMENT/usr" || OBS_INSTALL_STATUS=1; fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then observer_target_interpreter || OBS_INSTALL_STATUS=1; fi
    if [ "$OBS_INSTALL_STATUS" -eq 0 ]; then
        # Fixed target interpreter and isolated stdlib loader; no Alpine Python.
        OBS_INSTALL_RECEIPT=$(timeout 25 env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C LC_ALL=C \
            chroot "$OBS_DEPLOYMENT" /usr/bin/python3 -I -S -B - \
            --catalogue-sha256 "$OBS_CATALOGUE_SHA" --input-inode "$OBS_INPUT_SOURCE" \
            --input-source "$OBS_INPUT_MOUNT_SOURCE" --input-major "$OBS_INPUT_MAJOR" \
            --root-major "$OBS_ROOT_MAJOR" --boot-major "$OBS_BOOT_MAJOR" \
            --disk "$OBS_DISK_ID" --image "$IMAGE" --run-id "$RUN_ID" --install-id "$INSTALL_ID" \
            < /usr/lib/wootc-observer/installer_entry.py) || OBS_INSTALL_STATUS=1
        [ "${#OBS_INSTALL_RECEIPT}" -le 131072 ] || OBS_INSTALL_STATUS=1
        printf '%s' "$OBS_INSTALL_RECEIPT" | jq -e --arg run "$RUN_ID" --arg install "$INSTALL_ID" --arg image "$IMAGE" --arg disk "$OBS_DISK_ID" '
          type=="object" and .schemaVersion==1 and .action=="install-observer" and
          .runId==$run and .installId==$install and .image==$image and .selectedDisk==$disk and
          .installed==true and .guestBootAccepted==false and .desktopQualified==false and .editorQualified==false
        ' >/dev/null || OBS_INSTALL_STATUS=1
    fi
    observer_cleanup_views || OBS_INSTALL_STATUS=1
    if [ "${OBS_BOOT_ORIGINAL_ACTIVE:-false}" = true ]; then
        observer_release_view "$OBS_BOOT_ORIGINAL" "$OBS_BOOT_ORIGINAL_OWN" "$OBS_BOOT_ORIGINAL_SOURCE" false || OBS_INSTALL_STATUS=1
        OBS_BOOT_ORIGINAL_ACTIVE=false
    fi
    [ "$OBS_INSTALL_STATUS" -eq 0 ] || return 1
    printf '%s\n' "$OBS_INSTALL_RECEIPT"
}

observer_target_interpreter() {
    OBS_PYTHON="$OBS_DEPLOYMENT/usr/bin/python3" OBS_PYTHON_DEPTH=0
    while [ -L "$OBS_PYTHON" ]; do
        observer_directory "${OBS_PYTHON%/*}" || return 1
        [ "$(timeout 2 stat -c %u "$OBS_PYTHON")" = 0 ] || return 1
        OBS_PYTHON_LINK=$(timeout 2 readlink "$OBS_PYTHON") || return 1
        case "$OBS_PYTHON_LINK" in
            /usr/*) OBS_PYTHON="$OBS_DEPLOYMENT$OBS_PYTHON_LINK" ;;
            /*) return 1 ;;
            *) OBS_PYTHON="${OBS_PYTHON%/*}/$OBS_PYTHON_LINK" ;;
        esac
        case "$OBS_PYTHON" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
        printf '%s\n' "$OBS_PYTHON" | grep -Eq '^/[A-Za-z0-9._/-]+$' || return 1
        OBS_PYTHON_DEPTH=$((OBS_PYTHON_DEPTH + 1)); [ "$OBS_PYTHON_DEPTH" -le 16 ] || return 1
    done
    case "$OBS_PYTHON" in "$OBS_DEPLOYMENT/usr/"*) ;; *) return 1 ;; esac
    observer_directory "${OBS_PYTHON%/*}" || return 1
    OBS_PYTHON_FACTS=$(timeout 2 stat -c '%u %f %h' "$OBS_PYTHON") || return 1
    OBS_PYTHON_UID=${OBS_PYTHON_FACTS%% *}; OBS_PYTHON_REST=${OBS_PYTHON_FACTS#* }
    OBS_PYTHON_MODE=${OBS_PYTHON_REST%% *}; OBS_PYTHON_LINKS=${OBS_PYTHON_REST#* }
    [ "$OBS_PYTHON_UID" = 0 ] && [ "$OBS_PYTHON_LINKS" = 1 ] || return 1
    printf '%s\n' "$OBS_PYTHON_MODE" | grep -Eq '^[0-9a-f]+$' || return 1
    OBS_PYTHON_BITS=$((0x$OBS_PYTHON_MODE))
    [ "$((OBS_PYTHON_BITS & 61440))" -eq 32768 ] && [ "$((OBS_PYTHON_BITS & 18))" -eq 0 ] && [ -x "$OBS_PYTHON" ] || return 1
}
