#!/usr/bin/env bats
@test "firstboot collector proves EFI and actual root identity and rejects mismatches" {
    run python3 "$BATS_TEST_DIRNAME/test_firstboot_collector.py"
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
    run env WOOTC_FIRSTBOOT_HOST="$tmp/host" WOOTC_FIRSTBOOT_COLLECTOR="$tmp/collector.py" \
        FIRSTBOOT_CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" \
        bash "$BATS_TEST_DIRNAME/../../payload/migration/wootc-firstboot-evidence"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid BootCurrent"* ]]
    [ ! -e "$tmp/calls" ]
    [ "$(cat "$tmp/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.complete" ]
}
