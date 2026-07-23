#!/usr/bin/env bats
# userdata-persistence.bats — the E2E must prove the NORTH STAR: a file seeded
# in the Windows profile survives to Phase-2 $HOME (bridge) and then to the
# native disk (Phase 3). These guards pin the three properties that make the
# checks honest rather than proxies (docs/agent-lessons.md §1):
#   1. the seed happens BEFORE the deployer reboot,
#   2. every verification greps the seeded file's CONTENT for $RUN_ID —
#      a stale file from a previous run can never produce a false pass,
#   3. the checks are live QGA reads, not serial-marker greps.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    PS1="$REPO_ROOT/tests/e2e/setup-wootc.ps1"
}

@test "the arm script vaults a Linux user matching the Windows profile name" {
    # The User Data Bridge binds /host/Users/<name> into the home of the
    # MATCHING Linux account; without the vault no user exists and the whole
    # chain is untestable.
    grep -q '"username": "wootc"' "$PS1"
    grep -q 'wootc.vault=/wootc/install/vault.json' "$PS1"
    grep -q 'password_hash' "$PS1"
}

@test "user data is seeded before the deployer barrier is released" {
    local seed_line barrier_line
    seed_line=$(grep -nm1 'seed_user_data || true' "$E2E" | cut -d: -f1)
    barrier_line=$(grep -nm1 'mark_snapshot_complete$' "$E2E" | cut -d: -f1)
    [ -n "$seed_line" ] && [ -n "$barrier_line" ]
    [ "$seed_line" -lt "$barrier_line" ]
    # Seeded content carries the RUN_ID.
    grep -q "wootc-e2e-userdata \$RUN_ID" "$E2E"
}

@test "Phase-2 bridge check is a live QGA content read against RUN_ID" {
    grep -q 'cat /home/wootc/Documents/wootc-e2e-userdata.txt' "$E2E"
    grep -Fq 'printf '"'"'%s'"'"' "$USERDATA_HOME" | grep -q "$RUN_ID"' "$E2E"
    # Failure diagnostics must localize the broken layer, not just say "no".
    grep -q 'host-bind:' "$E2E"
    grep -q 'home-bind:' "$E2E"
}

@test "Phase-3 native persistence check reads the file from the native disk" {
    grep -q 'Verifying seeded user data persisted onto the native disk' "$E2E"
    grep -Fq 'printf '"'"'%s'"'"' "$P3_USERDATA" | grep -q "$RUN_ID"' "$E2E"
    # And a failed persistence check is FATAL, not advisory.
    grep -A4 'did NOT persist onto the native disk' "$E2E" | grep -q 'exit 1'
}

@test "vault user requests only the wheel group" {
    # useradd --root consults only the target's /etc/group; on EL10-family
    # images video/audio live in /usr/lib/group (systemd userdb) and useradd
    # exits 6, aborting the whole fisherman install. logind session ACLs make
    # the legacy device groups unnecessary.
    grep -Fq '\"groups\": [\"wheel\"]' "$REPO_ROOT/payload/deployer/deploy.sh"
    run grep -n '"wheel", "video", "audio"' "$REPO_ROOT/payload/deployer/deploy.sh"
    [ "$status" -ne 0 ]
}
