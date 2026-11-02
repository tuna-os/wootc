#!/bin/bash
# Sourceable host-ABI closure resolver. No deployment state or side effects.
# Input: executable path. Output: absolute DSO paths on stdout; nonzero if none.

# find_ldso
# Print the path of the dynamic loader this initramfs runs on.
#
# Unlike ldd, the loader is NOT optional here: every dynamically linked binary
# in the initramfs — bash, podman, qemu-ga — is unrunnable without it, so if
# this returns nothing the deployer is not executing at all.
find_ldso() {
    local c
    for c in /usr/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 \
             /usr/lib64/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1 \
             /usr/lib64/ld-linux-*.so.* /lib64/ld-linux-*.so.* \
             /usr/lib/ld-linux*.so.* /lib/ld-linux*.so.*; do
        if [[ -x "$c" ]]; then printf '%s\n' "$c"; return 0; fi
    done
    return 1
}

# dso_closure <binary>
# Print, one absolute path per line, every shared object <binary> needs plus
# the dynamic loader itself.
#
# This replaces `ldd "$bin" | awk '…print $i'`, which every closure builder
# here used to call and which is unrunnable in the deployer initramfs: `ldd`
# is a glibc-common SHELL SCRIPT and dracut installs only what
# module-setup.sh names, so it was never there. Under `set -o pipefail` the
# missing script failed the pipeline with 127 while the ERR trap named the
# *awk* stage, and the closure came back empty — the deployer then printed
#   [FAIL] qga: ldd on the deployer's qemu-ga surfaced no dynamic loader
# which run-e2e.sh reads as a fatal deployer error and kills the run
# (bluefin-dakota-win11pro, run 30707067821, 11 minutes in).
#
# `$ldso --list` is what ldd ultimately execs, so it yields identical output
# without the script. Parsing is pure bash for the same reason: a closure
# resolver must not be breakable by a missing text tool.
#
# Returns 1 and prints nothing when <binary> is not a dynamic executable (a
# shell script, a static binary): the callers read "no loader in the output"
# as "no self-contained closure is possible", and that verdict has to stay
# true, so the loader is never emitted for a binary that does not use it.
dso_closure() {
    local bin="$1" ldso="" raw="" line word saw_ldso=0 found=0
    ldso="$(find_ldso 2>/dev/null || true)"
    if [[ -n "$ldso" ]]; then
        raw="$("$ldso" --list "$bin" 2>/dev/null || true)"
    fi
    if [[ -z "$raw" ]] && command -v ldd >/dev/null 2>&1; then
        raw="$(ldd "$bin" 2>/dev/null || true)"
    fi
    [[ -n "$raw" ]] || return 1
    while IFS=$' \t' read -r -a line; do
        (( ${#line[@]} )) || continue
        for word in "${line[@]}"; do
            case "$word" in
                /*) [[ -f "$word" ]] || continue
                    printf '%s\n' "$word"
                    found=1
                    case "$word" in
                        */ld-linux*|*/ld64.so*|*/ld.so*) saw_ldso=1 ;;
                    esac ;;
            esac
        done
    done <<< "$raw"
    (( found )) || return 1
    # glibc's --list names the loader itself; some libcs do not. Emit it only
    # when the binary really did resolve against one.
    if (( ! saw_ldso )) && [[ -n "$ldso" ]]; then printf '%s\n' "$ldso"; fi
    return 0
}
