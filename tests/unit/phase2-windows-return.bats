#!/usr/bin/env bats
# phase2-windows-return.bats — never power-cut the thing you are verifying.
#
# The Phase-2 → Windows step asks the guest to reboot and then has to decide
# whether the guest actually went. Its fallback for "it didn't" is a QEMU
# `system_reset`, which is a hard power cut with no sync — appropriate for a
# wedged Phase-2 scratch root, catastrophic for a Windows that is mid-boot.
#
# The old detector only watched for guest-ping to FAIL:
#
#     for _ in $(seq 1 9); do sleep 5; qga_probe || { seen=true; break; }; done
#     [ "$seen" = true ] || system_reset
#
# guest-ping is OS-agnostic — it answers for whichever agent is up. So the
# detector could not distinguish the two states it exists to separate:
#
#     Phase 2 never rebooted          -> an agent answers  -> reset is correct
#     Phase 2 rebooted, Windows back  -> an agent answers  -> reset is a DISASTER
#
# Run 30710282779 (fedora-gnome-win11pro-btrfs) is the second one. Every Linux
# assertion passed, the exitrd handed C: back cleanly ("wootc: shutdown:
# unmounted the Windows host NTFS at /oldsys/run/initramfs/wootc-host"), the
# serial shows "reboot: machine restart" two seconds after the request, and the
# firmware then loaded Boot0003 "Windows Boot Manager". The harness meanwhile
# burned 110 blind seconds inside a retrying `qga_call exec`, opened its eyes on
# the WINDOWS agent, called it a Phase 2 that had not rebooted, and system_reset
# it. The firmware looped Boot0003 twice more and the guest sat in recovery
# until the 10-minute Windows budget expired:
#
#     [FAIL] Windows QGA did not become available within 10 minutes
#
# A run that had already succeeded was destroyed by its own fallback and
# reported as a product failure. This is the house failure class — status taken
# from a proxy ("something answers") instead of the observable ("*Linux*
# answers") — so the guard is: reset ONLY on a positively identified Linux
# agent, and treat every other reading as hands-off.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="${E2E:-$REPO_ROOT/tests/e2e/run-e2e.sh}"
}

extract_fn() { sed -n "/^$1() {$/,/^}$/p" "$E2E"; }

# The Phase-2 → Windows return block, verbatim.
return_block() {
    sed -n '/step "Rebooting Phase 2 Linux and verifying return to Windows/,/pass "One-shot Phase 2 boot consumed/p' "$E2E"
}

# Run p2_reboot_observe with the three probes stubbed. $1..$3 are shell
# snippets for qga_probe / qga_windows_probe / qga_linux_probe.
observe_with() {
    run bash -c "
        set -uo pipefail
        WOOTC_E2E_P2_REBOOT_POLL_S=0
        qga_probe() { $1; }
        qga_windows_probe() { $2; }
        qga_linux_probe() { $3; }
        $(extract_fn p2_reboot_observe)
        p2_reboot_observe 4
    "
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "guest-ping is OS-agnostic, so it cannot stand alone as a down-detector" {
    # This is the premise of the whole file: qga_probe asks `ping`, which any
    # agent answers. If it ever grows an OS discriminator of its own, the
    # reasoning below needs revisiting.
    extract_fn qga_probe | grep -q 'qga_call ping'
    ! extract_fn qga_probe | grep -qE 'uname|Windows_NT'
}

@test "a positive Linux discriminator exists alongside the Windows one" {
    # qga_windows_probe has always existed; its mirror is what was missing.
    extract_fn qga_windows_probe | grep -q 'Windows_NT'
    extract_fn qga_linux_probe | grep -q 'uname -s'
    extract_fn qga_linux_probe | grep -q 'Linux'
}

@test "no agent answering is read as 'down'" {
    observe_with 'return 1' 'return 1' 'return 1'
    [ "$status" -eq 0 ]
    [ "$output" = "down" ]
}

@test "a Windows agent answering is read as 'windows', not as a live Phase 2" {
    # Run 30710282779 exactly: Linux is gone, Windows pings and runs PowerShell.
    observe_with 'return 0' 'return 0' 'return 1'
    [ "$status" -eq 0 ]
    [ "$output" = "windows" ]
}

@test "a Linux agent still answering is read as 'linux'" {
    # The bonito case (30700616717 / 30704513401): request accepted, nothing
    # happened, Phase 2 sat at its login prompt. This is the ONE case a reset
    # is the right answer to.
    observe_with 'return 0' 'return 1' 'return 0'
    [ "$status" -eq 0 ]
    [ "$output" = "linux" ]
}

@test "an agent that identifies as neither is read as 'unknown', never as Linux" {
    # A Windows agent whose PowerShell is not up yet pings but cannot answer
    # $env:OS. Guessing "Linux" here is what costs a run, so it must not.
    observe_with 'return 0' 'return 1' 'return 1'
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "the observation stops the moment Windows is seen, without draining the budget" {
    # Every extra poll after Windows is home is time the old code spent walking
    # toward a reset.
    run bash -c "
        set -uo pipefail
        WOOTC_E2E_P2_REBOOT_POLL_S=0
        C=$BATS_TEST_TMPDIR/calls
        : > \"\$C\"
        qga_probe() { echo p >> \"\$C\"; return 0; }
        qga_windows_probe() { return 0; }
        qga_linux_probe() { return 1; }
        $(extract_fn p2_reboot_observe)
        p2_reboot_observe 9 >/dev/null
        wc -l < \"\$C\"
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "system_reset in the Phase-2 return is reachable only from the 'linux' verdict" {
    # The load-bearing assertion. Find the case label governing every
    # system_reset in this block; anything but `linux)` is a run-killer.
    # Match the monitor write itself, not the word in prose — the whole point is
    # which branch actually pulls the plug.
    local labels
    labels=$(return_block | awk '
        /^[[:space:]]*[a-z*]+\)[[:space:]]*$/ { gsub(/[[:space:]()]/, "", $0); label=$0 }
        /monitor\.sock/ { print (label == "" ? "UNGUARDED" : label) }
    ')
    [ -n "$labels" ]
    while read -r l; do [ "$l" = "linux" ]; done <<< "$labels"
}

@test "the verdict is computed before the reset, from p2_reboot_observe" {
    return_block | grep -q 'case "$(p2_reboot_observe)" in'
    local verdict_line reset_line
    verdict_line=$(return_block | grep -n 'p2_reboot_observe' | head -1 | cut -d: -f1)
    reset_line=$(return_block | grep -n 'monitor\.sock' | head -1 | cut -d: -f1)
    [ -n "$verdict_line" ] && [ -n "$reset_line" ]
    [ "$verdict_line" -lt "$reset_line" ]
}

@test "the reboot request is bounded so it cannot eat the observation window" {
    # qga_call retries three times at a 60s timeout by default and collapses to
    # a single try at <=5s. Unbounded, the request burned ~110s of the very
    # window the observation needs — which is how the observation ended up
    # looking at Windows in the first place.
    local t
    t=$(return_block | grep -E "WOOTC_QGA_CALL_TIMEOUT=[0-9]+ qga_call exec .*systemctl reboot" \
        | grep -oE 'WOOTC_QGA_CALL_TIMEOUT=[0-9]+' | grep -oE '[0-9]+$')
    [ -n "$t" ]
    [ "$t" -le 5 ]
}

@test "the Windows return is still asserted with the OS discriminator afterwards" {
    # Skipping the reset must not become "assume it worked".
    return_block | grep -q 'qga_wait_windows 600'
}

@test "the old ping-only shape really would have reset run 30710282779" {
    # Non-vacuity: with the same stubs the new code calls 'windows', the shape
    # this file replaced concludes "still up" and fires the reset. Without this,
    # every assertion above could be passing for free.
    run bash -c '
        set -uo pipefail
        qga_probe() { return 0; }   # Windows answering guest-ping
        seen=false
        for _ in $(seq 1 9); do
            if ! qga_probe; then seen=true; break; fi
        done
        [ "$seen" != true ] && echo would-reset || echo would-not-reset
    '
    [ "$status" -eq 0 ]
    [ "$output" = "would-reset" ]
}
