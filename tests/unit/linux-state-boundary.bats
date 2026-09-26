#!/usr/bin/env bats
setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    T=$(mktemp -d)
    export CALLS="$T/calls"
    mkdir -p "$T/private/wootc-host/wootc" "$T/bin"
    sed -e "s|private=/run/initramfs|private=$T/private|" \
        -e "s|public=/run/wootc/host|public=$T/public|" \
        "$ROOT/payload/migration/wootc-host-view" > "$T/view"
    cat > "$T/bin/mount" <<'SH'
#!/bin/bash
printf 'mount %s\n' "$*" >> "$CALLS"
if [[ "$*" == *'remount,bind,ro'* && ${FAIL_RO:-} == 1 ]]; then exit 1; fi
# Simulate the host bind contents for the mask-selection path.
if [[ "$1" == --bind && "$2" == */wootc-host ]]; then mkdir -p "$3/${STATE_NAME:-wootc}"; fi
SH
    printf '#!/bin/bash\n[[ "${*: -1}" == */wootc-host ]]\n' > "$T/bin/mountpoint"
    printf '#!/bin/bash\nprintf "umount %%s\\n" "$*" >> "$CALLS"\n' > "$T/bin/umount"
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}
teardown() { chmod -R u+rwx "$T"; rm -rf "$T"; }
@test "public view is masked and read-only before publication" {
    run bash "$T/view" start
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$T/private")" = 700 ]
    [ "$(stat -c %a "$T/private/wootc-view-control/hidden")" = 0 ]
    mask=$(grep -n 'mount --bind .*hidden' "$CALLS" | cut -d: -f1)
    ro=$(grep -n remount,bind,ro "$CALLS" | cut -d: -f1)
    publish=$(grep -n 'mount --move' "$CALLS" | cut -d: -f1)
    [ "$mask" -lt "$ro" ]; [ "$ro" -lt "$publish" ]
}
@test "read-only failure never publishes the Windows view" {
    run env FAIL_RO=1 bash "$T/view" start
    [ "$status" -ne 0 ]
    ! grep -q 'mount --move' "$CALLS"
    grep -q 'umount -R' "$CALLS"
}
@test "privileged lifecycle and folder writers use the private mount" {
    grep -q 'Environment=WOOTC_HOST=/run/initramfs/wootc-host' "$ROOT/payload/migration/wootc-passthrough.service"
    grep -q 'HOST="/run/initramfs/wootc-host"' "$ROOT/payload/migration/wootc-firstboot-evidence"
    grep -q 'chmod 0700 /run/initramfs' "$ROOT/platform/dracut/99wootc-boot/wootc-attach-loop.sh"
}
@test "folder redirects cannot export installer state or the whole volume" {
    mkdir -p "$T/host/wootc/install" "$T/host/Users/fixture/Documents"
    ln -s "$T/host/wootc" "$T/host/Users/fixture/alias"
    ln -s "$T/bin" "$T/host/Users/fixture/outside"
    sed -n '/^safe_folder_source()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs" > "$T/source-function"
    run bash -c 'source "$1"; HOST="$2"; safe_folder_source "$2/Users/fixture/Documents"' bash "$T/source-function" "$T/host"
    [ "$status" -eq 0 ]
    for path in "$T/host" "$T/host/wootc/install" "$T/host/Users/fixture/alias" "$T/host/Users/fixture/outside"; do
        run bash -c 'source "$1"; HOST="$2"; safe_folder_source "$3"' bash "$T/source-function" "$T/host" "$path"
        [ "$status" -ne 0 ]
    done
}
@test "a user-created folder symlink is never used as a bind destination" {
    HOST="$T/host"
    mkdir -p "$HOST/Users/fixture/Documents" "$T/home" "$T/elsewhere"
    ln -s "$T/elsewhere" "$T/home/Documents"
    eval "$(sed -n '/^safe_folder_source()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs")"
    eval "$(sed -n '/^bind_profile()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs")"
    sel_on() { return 0; }
    resolved_folder() { return 0; }
    add_host_bookmark() { :; }
    log() { echo "$*"; }
    warn() { echo "$*" >&2; }
    FOLDERS=(Documents)
    bound=0
    run bind_profile "$HOST/Users/fixture/" "$(id -un)" "$T/home"
    [ "$status" -eq 0 ]
    [[ "$output" == *'refusing symlink folder destination'* ]]
    [ ! -s "$CALLS" ]
}

@test "a case-sensitive uppercase installer directory is also masked" {
    run env STATE_NAME=WOOTC bash "$T/view" start
    [ "$status" -eq 0 ]
    grep -q 'mount --bind .*hidden .*public/WOOTC' "$CALLS"
}
