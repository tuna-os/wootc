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
        *) return 1 ;;
    esac
    observer_directory "$source" && observer_directory "${target%/*}" || return 1
    if observer_is_mounted "$target"; then return 1; else status=$?; [ "$status" -eq 1 ] || return 1; fi
    if [ "$kind" = proc ] || [ "$kind" = sys ]; then
        observer_directory "$target" || return 1
        contents=$(timeout 2 ls -A "$target") || return 1
        [ -z "$contents" ] || return 1
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
    observer_release_view "${OBS_SYS:-}" "${OBS_SYS_OWN:-}" "${OBS_SYS_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_PROC:-}" "${OBS_PROC_OWN:-}" "${OBS_PROC_SOURCE:-}" false || failed=1
    observer_release_view "${OBS_SYSROOT:-}" "${OBS_SYSROOT_OWN:-}" "${OBS_SYSROOT_SOURCE:-}" true || failed=1
    observer_release_view "${OBS_INPUT:-}" "${OBS_INPUT_OWN:-}" "${OBS_INPUT_SOURCE:-}" true || failed=1
    [ "$failed" -eq 0 ]
}
