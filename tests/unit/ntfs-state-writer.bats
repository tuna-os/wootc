#!/usr/bin/env bats
@test "NTFS state writer rejects forged descriptors and truncated records" {
    cd "$BATS_TEST_DIRNAME/../../payload/ntfs-state-write"
    GO111MODULE=off go test .
}

@test "firstboot never announces healthy when descriptor preservation fails" {
    local source="$BATS_TEST_DIRNAME/../../payload/migration/wootc-firstboot-evidence"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/host/wootc"
    printf '{"state":"deployed"}\n' > "$BATS_TEST_TMPDIR/host/wootc/state.json"
    sed "s|HOST=\"/run/wootc/host\"|HOST=\"$BATS_TEST_TMPDIR/host\"|" "$source" > "$BATS_TEST_TMPDIR/firstboot"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/mountpoint"
    printf '#!/bin/sh\necho "descriptor refusal" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/wootc-ntfs-state-write"
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$BATS_TEST_TMPDIR/firstboot"
    [ "$status" -ne 0 ]
    [[ "$output" == *"descriptor refusal"* ]]
    [[ "$output" != *"health reported"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$BATS_TEST_TMPDIR/host/wootc/install/installed-linux-boot.json" ]
}
