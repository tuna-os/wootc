#!/usr/bin/env bats
# e2e-failure-ledger.bats — a recorded failure must forbid "ALL TESTS PASSED".
#
# fail() used to only echo. A fail site that did not itself `exit 1` was
# therefore decorative, and the run continued to the success banner. That is
# how el10-gnome-win11pro-bitlocker (20260727T004500Z) reported
# "ALL TESTS PASSED" — and was recorded PASS by the matrix — while its own log
# contained:
#
#     [FAIL] Passthrough: errors detected in boot output:
#     [FAIL] User data NOT visible in Phase 2 $HOME (expected RUN_ID ...)
#
# The second is the North Star itself: the product's entire claim is that the
# user's data survives the migration. Both sites set PASSTHROUGH_OK=false and
# nothing in the script ever read that variable.
#
# The ledger must be a FILE. fail() is reached from inside command
# substitutions and pipelines, and a variable incremented there dies with the
# subshell — which is exactly the kind of "status taken from a proxy" defect
# this harness keeps producing.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    LEDGER="$BATS_TEST_TMPDIR/ledger"
    : > "$LEDGER"
    # Source fail() alone; running the script would start a VM.
    RED=""; NC=""
    WOOTC_FAILURE_LEDGER="$LEDGER"
    fail() {
        echo -e "${RED}[FAIL]${NC} $*" >&2
        printf '%s\n' "$*" >> "$WOOTC_FAILURE_LEDGER" 2>/dev/null || true
    }
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "fail() records to the ledger, not just stderr" {
    fail "something broke"
    [ -s "$LEDGER" ]
    grep -q "something broke" "$LEDGER"
}

@test "a fail inside a command substitution still reaches the ledger" {
    out=$(fail "raised in a subshell"; echo body)
    [ "$out" = "body" ]
    grep -q "raised in a subshell" "$LEDGER"
}

@test "a fail inside a pipeline still reaches the ledger" {
    echo x | { fail "raised in a pipeline"; cat >/dev/null; }
    grep -q "raised in a pipeline" "$LEDGER"
}

@test "the success banner is gated on the ledger being empty" {
    # The literal banner must not be reachable without passing the gate.
    gate_line=$(grep -n 'if \[ -s "\$WOOTC_FAILURE_LEDGER" \]' "$E2E" | tail -1 | cut -d: -f1)
    banner_line=$(grep -n 'ALL TESTS PASSED' "$E2E" | tail -1 | cut -d: -f1)
    [ -n "$gate_line" ]
    [ -n "$banner_line" ]
    [ "$gate_line" -lt "$banner_line" ]
}

@test "the gate exits non-zero and says TESTS FAILED when the ledger is non-empty" {
    grep -A 12 'if \[ -s "\$WOOTC_FAILURE_LEDGER" \]' "$E2E" | grep -q "TESTS FAILED"
    grep -A 14 'if \[ -s "\$WOOTC_FAILURE_LEDGER" \]' "$E2E" | grep -q "exit 1"
}

@test "the user-data check records a failure — it is the North Star assertion" {
    # It set PASSTHROUGH_OK=false, which nothing read. It must call fail() so
    # the ledger — which IS read — carries it.
    grep -q 'fail "User data NOT visible in Phase 2' "$E2E"
}

@test "a recovered ntfs3 mount error does not fail the run" {
    # The passthrough tries ntfs3 and falls back to fuse-ntfs-3g. On EL10, whose
    # kernel has no ntfs3, a HEALTHY boot logs a mount failure and then mounts.
    # Treating that as fatal would trade the old false green for a false red.
    grep -q 'warn "Passthrough: mount errors in boot output' "$E2E"
    # Only unrecoverable conditions may fail.
    grep -q 'fail "Passthrough: unrecoverable errors detected in boot output:"' "$E2E"
    run grep -c 'grep -qiE "Kernel panic - not syncing|kernel BUG at|ntfs3\.\*refus"' "$E2E"
    [ "$output" -ge 1 ]
}

@test "a drm_panic handler registration is not a kernel panic" {
    # "[drm] Registered 1 planes with drm panic" is the kernel's drm_panic
    # HANDLER registering during a perfectly healthy boot. The bare "panic"
    # pattern matched it, and once failures became binding that turned every
    # fedora/bonito cell red (fedora-gnome/kde/niri, run 30230608430).
    pat='Kernel panic - not syncing|kernel BUG at|ntfs3.*refus'
    run bash -c "echo '[   11.675448] virtio-pci 0000:00:01.0: [drm] Registered 1 planes with drm panic' | grep -qiE '$pat'"
    [ "$status" -ne 0 ]
    run bash -c "echo 'Kernel panic - not syncing: VFS: Unable to mount root fs' | grep -qiE '$pat'"
    [ "$status" -eq 0 ]
    run bash -c "echo 'kernel BUG at fs/ntfs3/inode.c:123' | grep -qiE '$pat'"
    [ "$status" -eq 0 ]
    # And the harness must use exactly that pattern.
    grep -q 'Kernel panic - not syncing|kernel BUG at|ntfs3.\*refus' "$E2E"
}

@test "OEM payload transfers retry and report instead of aborting silently" {
    # An unguarded qga_call in the payload loop returned non-zero straight into
    # `set -e`, killing the run with NO message — the entire win10 axis in run
    # 30230608430 (8 cells) died there, in "Refreshing OEM payload", seconds
    # after QGA came up. The restore path holds C:\OEM open, so a first-attempt
    # failure is expected, not exceptional.
    grep -q 'OEM payload write failed for' "$E2E"
    grep -q 'Could not transfer OEM payload file to the guest' "$E2E"
    # And the caller states a verdict rather than relying on set -e.
    grep -q 'qga_sync_oem || { fail "Cannot proceed' "$E2E"
}

@test "a non-matching grep in a checked assignment cannot abort the run" {
    # Under `set -o pipefail` a grep that matches NOTHING fails its pipeline, so
    # `X=$(... | grep ... )` aborts under set -e. Every instance of this sat in a
    # check whose whole purpose was to detect ABSENCE, so the one case each
    # existed to catch was the one case it could not report:
    #   - ATTACHED=   explains why Phase 2 emergency-shelled (it aborted instead)
    #   - PHASE2_PROOF= the hard gate's "NO proof of life" branch was unreachable
    #   - GUEST_CPU=   the "NO QEMU process — the guest is gone" branch likewise
    run bash -c 'set -euo pipefail; X=$(printf "nope\n" | grep -a "needle" | tail -1); echo reached'
    [ "$status" -ne 0 ]
    run bash -c 'set -euo pipefail; X=$(printf "nope\n" | grep -a "needle" | tail -1 || true); echo "reached:[$X]"'
    [ "$status" -eq 0 ]
    # No assignment in the harness may pipe through grep without a guard.
    run awk '/^[^#]*[A-Za-z_]+=\$\(/{buf=$0; while (buf !~ /\)$/ && (getline nxt)>0) buf=buf" "nxt; if (buf ~ /grep/ && buf !~ /\|\| true/) print}' "$E2E"
    [ -z "$output" ]
}

@test "a probe for something absent cannot print a [FAIL] that aborted nothing" {
    # -E propagates the ERR trap into command substitutions, so under pipefail
    # an optional probe whose first stage legitimately fails still prints
    #     [FAIL] run-e2e.sh aborted: awk '/inet /{...}' (exit 1)
    # while the run carries on. That happened on every hosted cell (no
    # tailscale0) — run 30707067821 — and the matrix takes the LAST [FAIL] as
    # the verdict, so on a silent failure this becomes the recorded reason.
    run bash -c 'set -Eeuo pipefail
        trap "printf \"[FAIL] aborted: %s\n\" \"\$BASH_COMMAND\" >&2" ERR
        for x in $(ip -4 addr show nosuchdev0 2>/dev/null | awk "{print \$2}"); do :; done
        echo done'
    [[ "$output" == *"[FAIL]"* ]]   # the shape being guarded against

    # The mirror probe is the instance that shipped it; both of its optional
    # `ip` calls must be guarded, in code and not merely in a comment.
    for probe in 'addr show tailscale0' 'route get 1\.1\.1\.1'; do
        run grep -cE "^[^#]*ip -4 $probe.*\|\| true" "$E2E"
        [ "$output" -ge 1 ]
    done
}

@test "log helpers do not mangle Windows paths" {
    # `echo -e` interprets escapes in the MESSAGE, so C:\OEM\run-wootc-e2e.ps1
    # printed as C:\OEMun-wootc-e2e.ps1 (\r became a carriage return) in the one
    # place it mattered — the line naming the file that could not be
    # transferred. \t, \n and \b corrupt just as silently.
    run bash -c 'RED="\033[0;31m"; NC="\033[0m"; printf "%b[FAIL]%b %s\n" "$RED" "$NC" "C:\OEM\run-wootc-e2e.ps1"'
    [[ "$output" == *'C:\OEM\run-wootc-e2e.ps1'* ]]
    # No helper may use `echo -e` with the message in the format position.
    run grep -nE '^(fail|warn|info|pass|step)\(\) \{[^}]*echo -e' "$E2E"
    [ -z "$output" ]
}

@test "a locked OEM payload file is force-replaced, not just unheld" {
    # Killing holders is not enough on the restore path: the file carries the
    # PRIME image's attributes/ACLs and the write still fails "Access is
    # denied". el10-gnome-win10pro burned all three attempts on
    # run-wootc-e2e.ps1 with holder-killing alone.
    grep -q 'attrib -r -s -h' "$E2E"
    grep -q 'takeown /f' "$E2E"
    # ...and the force-replace must be inside the payload retry, not only in the
    # config refresh that already had it.
    retry_line=$(grep -n 'OEM payload write failed for' "$E2E" | head -1 | cut -d: -f1)
    forced=$(awk -v s="$retry_line" 'NR>s && NR<s+15 && /takeown \/f/{print NR; exit}' "$E2E")
    [ -n "$forced" ]
}

@test "the serial arms the deployer-death detector, not just the heartbeat" {
    # Heartbeats fire only after the serial goes quiet, so a fisherman that
    # started and died between samples was never "seen" — the detector stayed
    # disarmed and the run waited out its full 90-minute budget. dakota did this
    # twice: serial showed "[fisherman] version: dev" at t=690s and its last
    # output at t=1124s while every heartbeat said fisherman=absent.
    grep -q "FISHERMAN_SEEN=true" "$E2E"
    # It must be armed from the serial scan as well as the heartbeat.
    run grep -c 'FISHERMAN_SEEN=true' "$E2E"
    [ "$output" -ge 2 ]
    grep -q "grep -qa '\\\\\[fisherman\\\\\]'" "$E2E"
}

@test "an unreachable Phase-2 agent is inconclusive, not proof of data loss" {
    # The North Star assertion and its diagnostic BOTH travel through QGA into
    # Phase-2 Linux. fedora-gnome-win11pro recorded "User data NOT visible" with
    # a completely EMPTY diagnostic block — every layer line blank, the
    # signature of an exec that never ran rather than a bridge that bound
    # nothing. Silence from the agent must not be read as absence of the file.
    grep -q 'WOOTC_AGENT_OK' "$E2E"
    grep -q 'the Phase-2 guest agent never answered, so the bridge was NOT measured' "$E2E"
    grep -q 'INCONCLUSIVE check, not proof of data loss' "$E2E"
    # The probe must precede the verdict.
    probe=$(grep -n 'USERDATA_PROBE=' "$E2E" | head -1 | cut -d: -f1)
    verdict=$(grep -n 'fail "User data NOT visible in Phase 2' "$E2E" | head -1 | cut -d: -f1)
    [ "$probe" -lt "$verdict" ]
}
