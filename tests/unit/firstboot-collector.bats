#!/usr/bin/env bats
@test "firstboot collector proves EFI and actual root identity and rejects mismatches" {
    run python3 "$BATS_TEST_DIRNAME/test_wootc_firstboot_evidence.py"
    [ "$status" -eq 0 ]
}

@test "firstboot never writes healthy if evidence collection fails" {
    local tmp="$BATS_TEST_TMPDIR"
    mkdir -p "$tmp/bin" "$tmp/host/wootc/install"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/mountpoint"
    printf '#!/bin/sh\necho called >> "$FIRSTBOOT_CALLS"\nexit 0\n' > "$tmp/bin/wootc-ntfs-state-write"
    chmod +x "$tmp/bin/"*
    # Prove the stubs can run: a noexec mount must never make this test green.
    run "$tmp/bin/mountpoint"
    [ "$status" -eq 0 ]
    printf 'raise ValueError("invalid BootCurrent")\n' > "$tmp/collector.py"
    run env WOOTC_STEPS_FILE="$BATS_TEST_DIRNAME/../../payload/steps.sh" \
        WOOTC_FIRSTBOOT_HOST="$tmp/host" WOOTC_FIRSTBOOT_COLLECTOR="$tmp/collector.py" \
        FIRSTBOOT_CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" \
        bash "$BATS_TEST_DIRNAME/../../payload/migration/wootc-firstboot-evidence"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid BootCurrent"* ]]
    [ ! -e "$tmp/calls" ]
    [ "$(cat "$tmp/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.complete" ]
}

@test "collector is staged as data and excluded from dracut's executable dependency pass" {
    local root="$BATS_TEST_DIRNAME/../.."
    local initdir="$BATS_TEST_TMPDIR/initramfs" verifier="$BATS_TEST_TMPDIR/verifier"
    mkdir -p "$verifier"
    for file in sbverify sbpehash ld-linux-x86-64.so.2 libcrypto.so.3 libc.so.6; do
        printf 'stand-in\n' > "$verifier/$file"
    done
    inst_simple() { install -D -m755 "$1" "$initdir/$2"; }
    # Run the real staging function. A reverted chmod leaves an executable
    # Python script, and the test must go red.
    eval "$(sed -n '/^stage_signed_chain_payloads()/,/^}/p' "$root/payload/deployer/module-setup.sh")"
    stage_signed_chain_payloads "$verifier" "$root/payload/migration/lib"
    local staged="$initdir/usr/lib/wootc/migration/lib/wootc_firstboot_evidence.py"
    cmp "$root/payload/migration/lib/wootc_firstboot_evidence.py" "$staged"
    [ "$(stat -c %a "$staged")" = 644 ]
    # This is dracut's real lazy-pass selection. inst_simple alone is not
    # enough: any executable payload is still scanned for its shebang.
    run find "$initdir" -type f \( -perm /0111 -or -name '*.so*' \) -not -name '*.ko*' -not -path '*/sbverify/*' -print
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q 'first-boot evidence collector missing from initramfs' "$root/payload/deployer/Containerfile"
}
