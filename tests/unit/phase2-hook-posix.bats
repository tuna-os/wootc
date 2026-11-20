#!/usr/bin/env bats
# The Phase-2 attach hook runs from the TARGET image's own initrd, and some
# images ship only dash there: grouper and flounder-sid have no bash in their
# initrd (tunaOS#4818). With a bash shebang, wootc-attach.service could not
# start, root.disk was never attached and Phase 2 fell to the emergency shell
# (runs 44701690108, 44701709912). These tests run the hook, the shutdown
# staging hook and the deployer's ntfs-3g wrapper under dash.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach-loop.sh"
    UNIT="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach.service"
    STAGE="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-stage-shutdown.sh"
    command -v dash >/dev/null || skip "dash unavailable"
    T="$BATS_TEST_TMPDIR"
    export CALLS="$T/calls"
    : > "$CALLS"
}

@test "the hook, its unit and the shutdown hook ask for sh, not bash" {
    head -1 "$HOOK" | grep -qx '#!/bin/sh'
    head -1 "$STAGE" | grep -qx '#!/bin/sh'
    run grep -E '^ExecStart=.*bash' "$UNIT"
    [ "$status" -ne 0 ]
    dash -n "$HOOK"
    dash -n "$STAGE"
}

# A sandboxed copy of the hook: its absolute paths moved under $T, its log
# channel on stderr (one `>` per line would truncate a regular file), and
# every tool that touches devices stubbed.
make_sandbox() { # <block-device> — any real one; [ -b ] follows the symlink
    local blk="$1"
    mkdir -p "$T/bin" "$T/by-uuid" "$T/run/initramfs/wootc-host/wootc/disks"
    : > "$T/run/initramfs/wootc-host/wootc/disks/root.disk"
    ln -s "$blk" "$T/by-uuid/abcd1234ef"
    ln -s "$blk" "$T/by-uuid/0a1b2c3d-4e5f"
    sed -e "s|/dev/console|/dev/stderr|g" \
        -e "s|/dev/kmsg|/dev/null|g" \
        -e "s|/dev/disk/by-uuid|$T/by-uuid|g" \
        -e "s|/run/|$T/run/|g" \
        "$HOOK" > "$T/hook.sh"
    stub mountpoint 'exit 1'
    stub mount 'printf "mount %s\n" "$*" >> "$CALLS"
case "$*" in *ntfs3*) [ "${FAIL_NTFS3:-}" = 1 ] && exit 1 ;; esac
exit 0'
    stub losetup 'echo /dev/loop7'
    stub blockdev 'exit 0'
    stub udevadm 'exit 0'
    stub blkid 'exit 0'
}

stub() { # <name> <body>
    printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"
    chmod +x "$T/bin/$1"
}

run_hook() { # <root= spec> — the whole hook, sourced by dash as systemd would run it
    env PATH="$T/bin:$PATH" ROOT_ARG="$1" dash -c '
        getarg() {
            case "$1" in
                loop=) echo /wootc/disks/root.disk ;;
                wootc.host_uuid=) echo ABCD1234EF ;;
                root=) echo "$ROOT_ARG" ;;
            esac
        }
        . "$1"
    ' dash "$T/hook.sh"
}

block_device() {
    local d
    for d in /dev/loop0 /dev/sda /dev/vda /dev/nvme0n1 /dev/sdb; do
        [ -b "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

@test "behavioral: under dash the hook mounts the host, attaches root.disk and confirms root" {
    blk=$(block_device) || skip "no block device to stand in for the host NTFS"
    make_sandbox "$blk"
    run run_hook UUID=0A1B2C3D-4E5F
    [ "$status" -eq 0 ]
    # ${HOST_UUID,,} and ${BASH_REMATCH[1],,} became lower(): both upper-case
    # inputs must resolve to the lower-case by-uuid names udev creates.
    echo "$output" | grep -q "host NTFS $T/by-uuid/abcd1234ef present"
    echo "$output" | grep -q 'host NTFS mounted via kernel-ntfs3'
    echo "$output" | grep -q 'requested root UUID 0a1b2c3d-4e5f confirmed present'
    [ -e "$T/run/wootc-loop-attached" ]
    grep -q "mount -t ntfs3 -o rw,force,umask=000 $T/by-uuid/abcd1234ef $T/run/initramfs/wootc-host" "$CALLS"
}

@test "behavioral: under dash root=PARTUUID= is parsed, a malformed root= is not" {
    blk=$(block_device) || skip "no block device to stand in for the host NTFS"
    make_sandbox "$blk"
    run run_hook PARTUUID=0A1B2C3D-4E5F
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'requested root UUID 0a1b2c3d-4e5f confirmed present'
    rm -f "$T/run/wootc-loop-attached"
    run run_hook 'UUID=0a1b;rm'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'WARNING: no root=UUID on kernel cmdline'
}

@test "behavioral: under dash a missing loop= karg is still a hard failure" {
    blk=$(block_device) || skip "no block device to stand in for the host NTFS"
    make_sandbox "$blk"
    run env PATH="$T/bin:$PATH" dash -c 'getarg() { :; }; . "$1"' dash "$T/hook.sh"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'EXIT: missing kernel args'
}

@test "behavioral: under dash the FUSE fallback runs ntfs-3g through its '@' name" {
    blk=$(block_device) || skip "no block device to stand in for the host NTFS"
    make_sandbox "$blk"
    stub ntfs-3g 'printf "%s %s\n" "${0##*/}" "$*" >> "$CALLS"'
    run env FAIL_NTFS3=1 PATH="$T/bin:$PATH" ROOT_ARG=UUID=0a1b2c3d-4e5f dash -c '
        getarg() {
            case "$1" in
                loop=) echo /wootc/disks/root.disk ;;
                wootc.host_uuid=) echo abcd1234ef ;;
                root=) echo "$ROOT_ARG" ;;
            esac
        }
        . "$1"
    ' dash "$T/hook.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'host NTFS mounted via fuse-ntfs-3g'
    grep -q "^@ntfs-3g -o rw,umask=000 $T/by-uuid/abcd1234ef $T/run/initramfs/wootc-host$" "$CALLS"
}

wait_for_exec() { # <pid> <not-this-argv0> — the cmdline after exec, NUL-split
    local i argv0
    for i in $(seq 1 50); do
        argv0=$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | head -1)
        [ -n "$argv0" ] && [ "$argv0" != "$2" ] && { echo "$argv0"; return 0; }
        sleep 0.1
    done
    return 1
}

@test "behavioral: exec_storage_daemon gives a real binary the '@' argv[0] systemd spares" {
    # systemd's initrd switch-root reads /proc/PID/cmdline and spares only
    # processes whose argv[0] starts with '@'. A real binary, not a script:
    # shebang handling would replace argv[0] and prove nothing.
    sed -n '/^exec_storage_daemon() {/,/^}/p' "$HOOK" > "$T/fn.sh"
    [ -s "$T/fn.sh" ]
    WOOTC_ARGV0_DIR="$T/argv0" dash -c '. "$1"; exec_storage_daemon sleep 30' dash "$T/fn.sh" &
    pid=$!
    argv0=$(wait_for_exec "$pid" dash) || { kill "$pid"; false; }
    kill "$pid" 2>/dev/null || true
    [ "$argv0" = "@sleep" ]
}

@test "behavioral: the deployer's ntfs-3g wrapper runs under dash with the '@' argv[0]" {
    # The real loader, the real binary (sleep standing in for ntfs-3g), the
    # real wrapper text — only its absolute /usr/lib/wootc/ntfs3g prefix is
    # moved into the overlay so it runs outside an initrd.
    command -v ldd >/dev/null || skip "ldd unavailable"
    sleep_bin=$(command -v sleep)
    ldso=$(ldd "$sleep_bin" | awk '$1 ~ /ld-linux|ld64\.so/ {print $1; exit}')
    [ -n "$ldso" ] && [ -f "$ldso" ] || skip "no dynamic loader found for sleep"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    INITRAMFS_LIB="$REPO_ROOT/payload/deployer/initramfs-lib.sh"
    mkdir -p "$T/root" "$T/ovl" "$T/nbin"
    cp "$sleep_bin" "$T/nbin/ntfs-3g"
    run bash -c "
        set -e
        log() { echo \"LOG: \$*\"; }
        err() { echo \"ERR: \$*\" >&2; }
        source '$INITRAMFS_LIB'
        $(sed -n '/^stage_ntfs3g_closure() {/,/^}/p' "$DEPLOY")
        DEPLOY_ROOT='$T/root'
        PATH='$T/nbin':\$PATH
        dso_closure() { printf '%s\n' '$ldso'; }
        stage_ntfs3g_closure '$T/ovl'
    "
    [ "$status" -eq 0 ]
    wrapper="$T/ovl/usr/bin/ntfs-3g"
    head -1 "$wrapper" | grep -qx '#!/bin/sh'
    sed "s|/usr/lib/wootc/ntfs3g|$T/ovl/usr/lib/wootc/ntfs3g|g" "$wrapper" > "$T/wrapper.sh"
    dash "$T/wrapper.sh" 30 &
    pid=$!
    argv0=$(wait_for_exec "$pid" dash) || { kill "$pid"; false; }
    kill "$pid" 2>/dev/null || true
    [ "$argv0" = "@ntfs-3g" ]
}

@test "behavioral: dash sources the shutdown staging hook without error" {
    # dracut's source_hook runs pre-pivot hooks with `.` from its own sh.
    # Nothing mounted: the hook must return quietly, never exit the shell.
    printf 'proc /proc proc rw 0 0\n' > "$T/mounts"
    run env WOOTC_STAGE_ROOT="$T/none" WOOTC_STAGE_DST="$T/dst" \
        WOOTC_STAGE_MOUNTS="$T/mounts" WOOTC_STAGE_MEMINFO=/proc/meminfo \
        dash -c '. "$1"; echo after-hook' dash "$STAGE"
    [ "$status" -eq 0 ]
    [ "$output" = after-hook ]
}
