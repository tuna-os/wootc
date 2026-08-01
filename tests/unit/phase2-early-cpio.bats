#!/usr/bin/env bats
# Phase-2 early-cpio staging: one overlay implementation for every branch,
# coherent ntfs-3g sourcing, and verification of the built initrd by
# INSPECTION rather than by "the concatenated file is non-empty".
#
# Context (#28): two branches looked for ntfs-3g under a /mnt/sysroot that
# never exists in the deployer initramfs, then fell through to the deployer's
# own binary WITHOUT its library closure — the cross-image soname failure of
# docs/agent-lessons.md §8 (libfuse3.so.4 vs .so.3: lands, then dies exactly
# like a missing binary). And (#45): a deploy whose installed root could not
# be mounted still advertised deploy-ready and rebooted.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
}

# Extract a top-level function from deploy.sh so it can be exercised for real.
# Returns the function text; empty output fails the caller loudly.
extract_fn() {
    awk "/^$1\(\) \{/,/^\}/" "$DEPLOY"
}

@test "no early-cpio branch references the phantom /mnt/sysroot" {
    # Comments may tell the story; code may not resurrect the path.
    run grep -nE '^[^#]*/mnt/sysroot' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "all three prepend-cpio branches share one overlay implementation" {
    # Hand-copied variants drifted (one staged libs, one did not, one staged
    # the deployer's libs at the TARGET's library paths). The helpers must be
    # defined once and called from every branch.
    [ "$(grep -c '^stage_wootc_overlay() {' "$DEPLOY")" -eq 1 ]
    [ "$(grep -c '^stage_ntfs3g_closure() {' "$DEPLOY")" -eq 1 ]
    [ "$(grep -c '^build_phase2_initrd() {' "$DEPLOY")" -eq 1 ]
    [ "$(grep -c '^[^#]*stage_wootc_overlay "\$OVL"' "$DEPLOY")" -ge 3 ]
    [ "$(grep -c '^[^#]*stage_ntfs3g_closure "\$OVL"' "$DEPLOY")" -ge 3 ]
    [ "$(grep -c 'build_phase2_initrd "\$OVL"' "$DEPLOY")" -ge 3 ]
    # No branch may keep a private copy of the packing pipeline.
    [ "$(grep -c 'cpio -o -H newc' "$DEPLOY")" -eq 1 ]
}

@test "the deployer-sourced fallback ships the loader and is exec-verified" {
    # agent-lessons §8: full closure = binary + every NEEDED lib + the
    # loader, invoked via the staged loader — and proven by RUNNING it (ldd
    # reports only the first missing library).
    grep -q -- '--library-path' "$DEPLOY"
    grep -q 'usr/lib/wootc/ntfs3g' "$DEPLOY"
    grep -q 'staged ntfs-3g closure does not execute' "$DEPLOY"
    # The wrapper pins the private closure; the target's libraries are never
    # mixed in — so nothing may install deployer libs at target lib paths.
    run grep -nE 'install -D [^ ]+ "\$OVL/\$lib"' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the built Phase-2 initrd is verified by listing, not by size" {
    grep -q 'cpio -it' "$DEPLOY"
    grep -q 'the target.s base initrd lacks' "$DEPLOY"
    # Overlay completeness is asserted BEFORE packing (dangling wants was a
    # proven silent no-op).
    grep -q 'early-cpio overlay is incomplete' "$DEPLOY"
    # An unlistable base initrd WARNs (unknown compression is not proof of a
    # defect), it does not kill a possibly-good deploy.
    grep -q 'could not list the base initrd' "$DEPLOY"
}

@test "a missing mountable installed root is fatal, with evidence (#45)" {
    # The old branch logged '[WARN] Could not mount installed root
    # (checking via loop file only)' and then set DEPLOY_OK=1 — advertising
    # deploy-ready for a system with no verified (or even findable) root.
    run grep -nE '^[^#]*checking via loop file only' "$DEPLOY"
    [ "$status" -ne 0 ]
    grep -q 'no mountable, recognized installed root' "$DEPLOY"
    # Evidence: partition table, per-partition blkid, bounded mount errors.
    fail_line=$(grep -n 'no mountable, recognized installed root' "$DEPLOY" | head -1 | cut -d: -f1)
    exit_line=$(awk -v start="$fail_line" 'NR > start && /^[[:space:]]*exit 1/ { print NR; exit }' "$DEPLOY")
    [ -n "$fail_line" ] && [ -n "$exit_line" ]
    [ "$exit_line" -le $((fail_line + 25)) ]
    sed -n "${fail_line},${exit_line}p" "$DEPLOY" | grep -q 'sfdisk -l'
    sed -n "${fail_line},${exit_line}p" "$DEPLOY" | grep -q 'blkid'
    # And the success reboot must come AFTER this gate in program order.
    ok_line=$(grep -n '^DEPLOY_OK=1' "$DEPLOY" | head -1 | cut -d: -f1)
    [ "$exit_line" -lt "$ok_line" ]
}

# ── Behavioral: the helpers, run for real ───────────────────────────────────

run_helpers() { # <bash-snippet> — with the extracted helpers + stubs loaded
    bash -c "
        set -e
        log() { echo \"LOG: \$*\"; }
        err() { echo \"ERR: \$*\" >&2; }
        $(extract_fn stage_ntfs3g_closure)
        $(extract_fn _initrd_segment_end)
        $(extract_fn _initrd_skip_padding)
        $(extract_fn list_initrd_members)
        $(extract_fn build_phase2_initrd)
        $1
    "
}

@test "behavioral: target ntfs-3g is staged with its libraries, symlinks intact" {
    tmp="$BATS_TEST_TMPDIR/target"
    mkdir -p "$tmp/root/usr/bin" "$tmp/root/usr/lib64" "$tmp/ovl"
    printf '#!/bin/sh\necho fake\n' > "$tmp/root/usr/bin/ntfs-3g"
    chmod +x "$tmp/root/usr/bin/ntfs-3g"
    # Symlink chain: .so.89 -> .so.89.0.0 — both must land in the overlay.
    echo lib > "$tmp/root/usr/lib64/libntfs-3g.so.89.0.0"
    ln -s libntfs-3g.so.89.0.0 "$tmp/root/usr/lib64/libntfs-3g.so.89"
    run run_helpers "DEPLOY_ROOT='$tmp/root'; stage_ntfs3g_closure '$tmp/ovl'"
    [ "$status" -eq 0 ]
    [ -x "$tmp/ovl/usr/bin/ntfs-3g" ]
    [ -f "$tmp/ovl/usr/lib64/libntfs-3g.so.89.0.0" ]
    [ -L "$tmp/ovl/usr/lib64/libntfs-3g.so.89" ]
    [ -L "$tmp/ovl/usr/sbin/mount.ntfs" ]
}

make_overlay() { # <dir> — a complete wootc overlay tree
    mkdir -p "$1/usr/lib/systemd/system/initrd-root-device.target.wants" \
             "$1/usr/lib/wootc" \
             "$1/usr/lib/dracut/hooks/pre-pivot" \
             "$1/usr/lib/dracut/hooks/shutdown"
    echo unit > "$1/usr/lib/systemd/system/wootc-attach.service"
    ln -sf ../wootc-attach.service \
        "$1/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"
    printf '#!/bin/bash\n' > "$1/usr/lib/wootc/wootc-attach-loop.sh"
    chmod +x "$1/usr/lib/wootc/wootc-attach-loop.sh"
    # The Phase-2 shutdown pair, without which build_phase2_initrd refuses to
    # pack — a Phase 2 that boots but hands Windows back a mounted rw NTFS.
    # See tests/unit/phase2-clean-ntfs-umount.bats.
    printf '#!/bin/bash\n' > "$1/usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh"
    printf '#!/bin/sh\n' > "$1/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
    chmod +x "$1/usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh" \
             "$1/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
}

make_base_initrd() { # <out> [tools...] — a gzip cpio shipping the named tools
    local out="$1"; shift
    local tree="$BATS_TEST_TMPDIR/base-tree"
    rm -rf "$tree"; mkdir -p "$tree/usr/bin" "$tree/usr/sbin"
    local t
    for t in "$@"; do echo x > "$tree/usr/bin/$t"; done
    ( cd "$tree" && find . | cpio -o -H newc --quiet ) | gzip > "$out"
}

@test "behavioral: a complete overlay + complete base initrd builds and verifies" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    ovl="$BATS_TEST_TMPDIR/ovl-ok"; make_overlay "$ovl"
    make_base_initrd "$BATS_TEST_TMPDIR/base.img" bash losetup udevadm mount
    run run_helpers "build_phase2_initrd '$ovl' '$BATS_TEST_TMPDIR/base.img' '$BATS_TEST_TMPDIR/out.img'"
    [ "$status" -eq 0 ]
    # Output must start with the overlay's uncompressed newc cpio magic.
    head -c 6 "$BATS_TEST_TMPDIR/out.img" | grep -q 070701
}

@test "behavioral: a base initrd without bash is REFUSED (mutation test)" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    ovl="$BATS_TEST_TMPDIR/ovl-nobash"; make_overlay "$ovl"
    make_base_initrd "$BATS_TEST_TMPDIR/base-nobash.img" losetup udevadm mount
    run run_helpers "build_phase2_initrd '$ovl' '$BATS_TEST_TMPDIR/base-nobash.img' '$BATS_TEST_TMPDIR/out2.img'"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'lacks: bash'
}

@test "behavioral: an overlay with a missing wants edge is refused before packing" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    ovl="$BATS_TEST_TMPDIR/ovl-dangling"; make_overlay "$ovl"
    rm "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"
    make_base_initrd "$BATS_TEST_TMPDIR/base3.img" bash losetup udevadm mount
    run run_helpers "build_phase2_initrd '$ovl' '$BATS_TEST_TMPDIR/base3.img' '$BATS_TEST_TMPDIR/out3.img'"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/out3.img" ]
}

prepend_microcode() { # <initrd> — make it a real-world image: uncompressed
    # early-cpio (microcode) + 512-byte pad + the compressed main archive,
    # which is what every Fedora/bootc initramfs actually is.
    local img="$1"
    local tree="$BATS_TEST_TMPDIR/early-tree"
    rm -rf "$tree"; mkdir -p "$tree/kernel/x86/microcode"
    : > "$tree/early_cpio"
    head -c 2048 /dev/urandom > "$tree/kernel/x86/microcode/GenuineIntel.bin"
    ( cd "$tree" && find . | cpio -o -H newc --quiet ) > "$img.early"
    # dracut pads the early segment out to a 512-byte boundary.
    local pad=$(( (512 - ($(wc -c < "$img.early") % 512)) % 512 ))
    (( pad > 0 )) && head -c "$pad" /dev/zero >> "$img.early"
    cat "$img.early" "$img" > "$img.concat"
    mv "$img.concat" "$img"
    rm -f "$img.early"
}

@test "behavioral: a microcode early-cpio does not hide the real initrd (#76)" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    # `cpio -it` stops at the first TRAILER!!!, so listing the raw image
    # yields the microcode segment and nothing else — five paths, no /usr.
    # Reading that as "the initrd lacks bash/losetup/udevadm/mount" failed
    # every dakota deploy (run 30700616717) on an initrd holding all four.
    ovl="$BATS_TEST_TMPDIR/ovl-uc"; make_overlay "$ovl"
    base="$BATS_TEST_TMPDIR/base-uc.img"
    make_base_initrd "$base" bash losetup udevadm mount
    prepend_microcode "$base"
    # Guard the premise: the naive single-archive listing really is blind here.
    run bash -c "cpio -it --quiet < '$base'"
    [ "$status" -eq 0 ]
    ! echo "$output" | grep -q bash
    echo "$output" | grep -q microcode

    run run_helpers "build_phase2_initrd '$ovl' '$base' '$BATS_TEST_TMPDIR/out-uc.img'"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'base initrd verified'
}

@test "behavioral: a real absence is still fatal behind an early-cpio" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    # The segment walk must not turn the gate into a rubber stamp.
    ovl="$BATS_TEST_TMPDIR/ovl-uc2"; make_overlay "$ovl"
    base="$BATS_TEST_TMPDIR/base-uc2.img"
    make_base_initrd "$base" losetup udevadm mount
    prepend_microcode "$base"
    run run_helpers "build_phase2_initrd '$ovl' '$base' '$BATS_TEST_TMPDIR/out-uc2.img'"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'lacks: bash'
}

@test "behavioral: a microcode-only image is unverifiable, not a failure" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    # No bin/ tree anywhere in the listing means the probe saw no rootfs —
    # WARN, never a fatal verdict about tools it never looked at.
    ovl="$BATS_TEST_TMPDIR/ovl-uc3"; make_overlay "$ovl"
    base="$BATS_TEST_TMPDIR/base-uc3.img"
    : > "$base"
    prepend_microcode "$base"
    run run_helpers "build_phase2_initrd '$ovl' '$base' '$BATS_TEST_TMPDIR/out-uc3.img'"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'unverified'
}

@test "behavioral: an unlistable base initrd warns but does not fail the deploy" {
    command -v cpio >/dev/null || skip "cpio unavailable"
    ovl="$BATS_TEST_TMPDIR/ovl-unk"; make_overlay "$ovl"
    head -c 4096 /dev/urandom > "$BATS_TEST_TMPDIR/base-unknown.img"
    run run_helpers "build_phase2_initrd '$ovl' '$BATS_TEST_TMPDIR/base-unknown.img' '$BATS_TEST_TMPDIR/out4.img'"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'could not list the base initrd'
}
