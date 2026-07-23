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
    # The User Data Bridge binds /run/wootc/host/Users/<name> into the home of the
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

@test "passthrough is wanted by multi-user, after /var is mounted" {
    # It writes under /home -> var/home; ordered Before=local-fs.target it
    # ran pre-var.mount, mkdir hit the read-only composefs root, and the
    # service failed while host-bind was healthy (run 20260723T0349).
    local svc="$REPO_ROOT/payload/migration/wootc-passthrough.service"
    grep -q '^After=wootc-host-bind.service local-fs.target' "$svc"
    grep -q '^WantedBy=multi-user.target' "$svc"
    run grep -n '^DefaultDependencies=no' "$svc"
    [ "$status" -ne 0 ]
    grep -q 'multi-user.target.wants/wootc-passthrough.service' "$REPO_ROOT/payload/deployer/deploy.sh"
    run grep -nE '^[^#]*local-fs.target.wants/wootc-passthrough' "$REPO_ROOT/payload/deployer/deploy.sh"
    [ "$status" -ne 0 ]
}

@test "Phase-3 reboot never rides the QGA channel" {
    # qga_call retries on timeout; a retry the dying Phase 2 fails to consume
    # stays queued in virtio-serial and is executed by the NEXT agent to open
    # it — the freshly booted native system, which then reboots straight back
    # to Windows (BootNext already consumed; run 20260723T0423). The Phase-3
    # transition must reset via the QEMU monitor, which queues nothing.
    grep -A14 'Rebooting Phase 2 into the one-shot Phase 3' "$E2E" | grep -q 'system_reset'
    run bash -c "grep -A14 'Rebooting Phase 2 into the one-shot Phase 3' '$E2E' | grep -E '^[^#]*qga_call exec'"
    [ "$status" -ne 0 ]
}

@test "mount-user-dirs reports a bind verdict and flags a missing home" {
    # Run 20260723T0423: the unit "succeeded" with zero binds and an empty
    # journal — undiagnosable from the outside. It must always log a summary,
    # and a matching user whose home is absent is a named deployment bug.
    local mud="$REPO_ROOT/payload/migration/wootc-mount-user-dirs"
    grep -q 'summary: \$bound folder binds across \$matched matching user' "$mud"
    grep -q 'no home directory' "$mud"
}

@test "fisherman pins user homes into the stateroot var" {
    # useradd --create-home follows the deployment's /home -> var/home
    # symlink into the deployment's OWN var, masked at runtime by the
    # stateroot var mount (run 20260723T0423). fisherman must relocate the
    # home and write a tmpfiles.d snippet for first-boot relabeling.
    local ug="$REPO_ROOT/fisherman/fisherman/internal/post/user.go"
    grep -q 'staterootHome' "$ug"
    grep -q 'fisherman-home-' "$ug"
    grep -q '/etc/skel' "$ug"
}
