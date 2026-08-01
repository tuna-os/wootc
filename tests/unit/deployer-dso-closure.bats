#!/usr/bin/env bats
# The deployer's shared-object closure resolver must work in the DEPLOYER
# INITRAMFS, not merely on a developer's full Fedora userland.
#
# Context (bluefin-dakota-win11pro, run 30707067821): every closure builder in
# deploy.sh resolved libraries with
#     ldd "$bin" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}'
# and `ldd` is a glibc-common SHELL SCRIPT that dracut never installed —
# module-setup.sh names every binary the initramfs gets, and ldd was not one
# of them. Under `set -o pipefail` the missing script failed the pipeline with
# 127, the ERR trap named the *awk* stage, and the loop saw nothing:
#     [wootc] ABORT: line 1281: awk '{for(i=1;i<=NF;i++) ...}' (exit 127)
#     [FAIL] qga: ldd on the deployer's qemu-ga surfaced no dynamic loader
# run-e2e.sh aborts the deploy on the first [FAIL] on the serial, so the cell
# died 11 minutes in on a line that was never fatal to the deployer itself.
#
# Both halves are covered here: the resolver may not depend on ldd (or on any
# text tool), and a best-effort stager may not shout [FAIL] when its own
# caller carries on with a [WARN].

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
    MODSETUP="$REPO_ROOT/payload/deployer/module-setup.sh"
}

extract_fn() {
    awk "/^$1\(\) \{/,/^\}/" "$DEPLOY"
}

# A PATH holding ONLY what the stagers legitimately need — deliberately
# without ldd and without awk, which is the deployer initramfs's actual
# userland for this code path.
minimal_path() {
    local d="$BATS_TEST_TMPDIR/minpath" t p
    mkdir -p "$d"
    for t in bash sh install rm chmod ln cat; do
        p="$(type -P "$t")" || return 1
        ln -sf "$p" "$d/$t"
    done
    printf '%s\n' "$d"
}

@test "find_ldso locates the dynamic loader this deployer runs on" {
    run bash -c "set -euo pipefail; $(extract_fn find_ldso); find_ldso"
    [ "$status" -eq 0 ]
    [ -x "$output" ]
}

@test "the closure resolves with neither ldd nor awk on PATH" {
    mp="$(minimal_path)"
    # Prove the premise: this PATH really is the initramfs's, not the host's.
    run env -i PATH="$mp" bash -c 'command -v ldd; command -v awk'
    [ -z "$output" ]

    run env -i PATH="$mp" bash -c "
        set -euo pipefail
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        dso_closure '$(type -P bash)'
    "
    [ "$status" -eq 0 ]
    # A real closure: libc plus the loader, every entry an existing file.
    echo "$output" | grep -q '/libc\.so'
    echo "$output" | grep -qE '/(ld-linux|ld64\.so|ld\.so)'
    while read -r lib; do [ -f "$lib" ]; done <<< "$output"
}

@test "the loader is preferred over ldd, so a broken ldd cannot break staging" {
    shim="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$shim"
    printf '#!/bin/sh\necho "ldd: command not found" >&2\nexit 127\n' > "$shim/ldd"
    chmod +x "$shim/ldd"
    run env PATH="$shim:$PATH" bash -c "
        set -euo pipefail
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        dso_closure '$(type -P bash)'
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '/libc\.so'
}

@test "a binary with no closure still reports none — no phantom loader" {
    # The callers read "no loader in the output" as "no self-contained closure
    # is possible" and delete the half-staged tree. Emitting the loader
    # unconditionally would make that verdict lie for a shell script.
    scr="$BATS_TEST_TMPDIR/script.sh"
    printf '#!/bin/sh\nexit 0\n' > "$scr"
    chmod +x "$scr"
    run bash -c "
        set -uo pipefail
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        dso_closure '$scr'
    "
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the fallback qemu-ga stages end-to-end with no ldd in the initramfs" {
    # The exact regression: same function, same absent ldd, must now finish.
    mp="$(minimal_path)"
    root="$BATS_TEST_TMPDIR/root"
    fake="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$root" "$fake"
    cp "$(type -P true)" "$fake/qemu-ga"
    chmod 0755 "$fake/qemu-ga"

    run env -i DEPLOY_ROOT="$root" PATH="$fake:$mp" bash -c "
        set -euo pipefail
        log() { echo \"\$*\"; }
        err() { echo \"\$*\" >&2; }
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        $(extract_fn stage_qemu_ga_into_target)
        stage_qemu_ga_into_target
    "
    [ "$status" -eq 0 ]
    [ -x "$root/var/usrlocal/bin/qemu-ga" ]
    [ -f "$root/etc/systemd/system/wootc-qemu-ga.service" ]
    # The closure is real: a loader landed next to the binary.
    run bash -c "ls '$root/var/usrlocal/lib/wootc-qga' | grep -cE '^(ld-linux|ld64\.so|ld\.so)'"
    [ "$output" -ge 1 ]
}

@test "no call site pipes ldd into awk any more" {
    run grep -nE '^[^#]*ldd .*\| *awk' "$DEPLOY"
    [ "$status" -ne 0 ]
    # And every closure builder goes through the one resolver.
    [ "$(grep -c '^dso_closure() {' "$DEPLOY")" -eq 1 ]
    [ "$(grep -c '^[^#]*dso_closure "' "$DEPLOY")" -ge 3 ]
}

@test "best-effort stagers warn, they do not [FAIL]" {
    # run-e2e.sh: `grep -qE "fatal|panic|kernel panic|\[FAIL\]"` on the
    # deployer serial ends the deploy immediately. Both of these functions
    # have callers that continue on failure with a [WARN], so a [FAIL] inside
    # them turns a survivable condition into a dead 90-minute cell.
    for fn in stage_qemu_ga_into_target stage_ntfs3g_closure; do
        # Comments may explain the rule; code may not break it.
        run bash -c "awk \"/^${fn}\\(\\) \\{/,/^\\}/\" '$DEPLOY' \
            | grep -vE '^[[:space:]]*#' | grep -n '\[FAIL\]'"
        [ "$status" -ne 0 ]
    done
    # The callers really are the forgiving kind this asserts.
    grep -q 'no fallback qemu-ga staged' "$DEPLOY"
    [ "$(grep -c 'no ntfs-3g stageable' "$DEPLOY")" -ge 3 ]
}

@test "the initramfs also carries ldd, as the second path" {
    grep -qE '^[[:space:]]*inst_multiple -o .*\bldd\b' "$MODSETUP"
}
