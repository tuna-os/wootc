#!/usr/bin/env bats
@test "NTFS state writer rejects forged descriptors and truncated records" {
    cd "$BATS_TEST_DIRNAME/../../payload/ntfs-state-write"
    GO111MODULE=off go test .
}

@test "firstboot never announces healthy when descriptor preservation fails" {
    local source="$BATS_TEST_DIRNAME/../../payload/migration/wootc-firstboot-evidence"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/host/wootc"
    printf '{"state":"deployed"}\n' > "$BATS_TEST_TMPDIR/host/wootc/state.json"
    cp "$source" "$BATS_TEST_TMPDIR/firstboot"
    printf 'print("{}")\n' > "$BATS_TEST_TMPDIR/collector.py"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/mountpoint"
    printf '#!/bin/sh\necho "descriptor refusal" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/wootc-ntfs-state-write"
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    run "$BATS_TEST_TMPDIR/bin/mountpoint"
    [ "$status" -eq 0 ]
    run env WOOTC_STEPS_FILE="$BATS_TEST_DIRNAME/../../payload/steps.sh" WOOTC_FIRSTBOOT_HOST="$BATS_TEST_TMPDIR/host" \
        WOOTC_FIRSTBOOT_COLLECTOR="$BATS_TEST_TMPDIR/collector.py" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$BATS_TEST_TMPDIR/firstboot"
    [ "$status" -ne 0 ]
    [[ "$output" == *"descriptor refusal"* ]]
    [[ "$output" != *"health reported"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$BATS_TEST_TMPDIR/host/wootc/install/installed-linux-boot.json" ]
}
