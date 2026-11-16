#!/usr/bin/env bash
# wootc-initramfs-lib — initramfs inspection helpers for the deployer.
#
# deploy.sh sources this file. The functions here read binaries and initramfs
# images and print what they find. They use no deployer globals and change no
# state, so tests source this file and call them directly.
#
#   find_ldso, dso_closure    what a dynamic binary needs to run in the initramfs
#   list_initrd_members       what an initramfs image (all of its segments) holds


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

# ── initramfs introspection ────────────────────────────────────────────────
# An initramfs image is a CONCATENATION, not one archive: zero or more
# UNCOMPRESSED early-cpio segments (CPU microcode, ACPI overrides) followed by
# the compressed main archive. `cpio -it` stops at the first TRAILER!!!, so on
# a Fedora/bootc image it lists the microcode segment — a handful of paths
# under kernel/x86/microcode — and exits 0. That non-empty listing was then
# read as proof that the initrd shipped no bash/losetup/udevadm/mount, and it
# killed every dakota run at the Phase-2 gate (run 30700616717) on an initrd
# that ships all four. Missing ALL FOUR is not a thing a bootable initrd does;
# the listing was of the wrong segment. Walk the chain instead.

# _initrd_segment_end <image> <offset>
# Echo the offset just past the newc cpio archive that starts at <offset>
# (i.e. past its TRAILER!!! member). Fails if no archive starts there.
_initrd_segment_end() {
    local img="$1" off="$2" hdr namesize filesize name
    while :; do
        hdr=$(dd if="$img" bs=1 skip="$off" count=110 status=none 2>/dev/null || true)
        # 6-byte magic + 13 eight-digit hex fields = 110 ASCII bytes.
        [[ "$hdr" =~ ^070701[0-9a-fA-F]{104}$ ]] || return 1
        filesize=$((16#${hdr:54:8}))
        namesize=$((16#${hdr:94:8}))
        name=$(dd if="$img" bs=1 skip=$((off + 110)) count="$namesize" status=none 2>/dev/null | tr -d '\0')
        # Header+name and then the file data are each padded to 4 bytes.
        off=$(( (off + 110 + namesize + 3) / 4 * 4 ))
        off=$(( (off + filesize + 3) / 4 * 4 ))
        if [[ "$name" == "TRAILER!!!" ]]; then
            printf '%s' "$off"
            return 0
        fi
    done
}

# _initrd_skip_padding <image> <offset> <size>
# Early-cpio segments are zero-padded (to 4 or to 512 bytes) before the next
# segment begins. Echo the first non-padding offset, bounded so a corrupt
# image cannot spin here.
_initrd_skip_padding() {
    local img="$1" off="$2" size="$3" limit nonzero
    limit=$(( off + 4096 ))
    (( limit > size )) && limit=$size
    while (( off < limit )); do
        nonzero=$(dd if="$img" bs=1 skip="$off" count=4 status=none 2>/dev/null | tr -d '\0' | wc -c)
        if (( nonzero > 0 )); then
            break
        fi
        off=$(( off + 4 ))
    done
    printf '%s' "$off"
}

# list_initrd_members <image>
# Echo the member names of EVERY segment of an initramfs image. Empty output
# means "unlistable here" (unknown compression), never "the initrd is empty".
list_initrd_members() {
    local img="$1" size off=0 seg dec end
    size=$(wc -c < "$img" 2>/dev/null || echo 0)
    while (( off < size )); do
        if [[ $(dd if="$img" bs=1 skip="$off" count=6 status=none 2>/dev/null || true) == 070701 ]]; then
            # An uncompressed segment: list it, then step over it.
            seg=$(tail -c +$((off + 1)) "$img" 2>/dev/null | cpio -it --quiet 2>/dev/null || true)
            [[ -n "$seg" ]] && printf '%s\n' "$seg"
            end=$(_initrd_segment_end "$img" "$off") || break
            off=$(_initrd_skip_padding "$img" "$end" "$size")
            continue
        fi
        # Anything else is the compressed main archive, and it is last.
        for dec in "zstd -qdc" "gzip -dc" "xz -dc" "lz4 -dc" "bzip2 -dc" "lzop -dc"; do
            seg=$(tail -c +$((off + 1)) "$img" 2>/dev/null | $dec 2>/dev/null | cpio -it --quiet 2>/dev/null || true)
            if [[ -n "$seg" ]]; then
                printf '%s\n' "$seg"
                break
            fi
        done
        break
    done
    return 0
}
