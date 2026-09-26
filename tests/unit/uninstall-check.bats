#!/usr/bin/env bats
# uninstall-check.bats — leaving must be provably easy (#NS-7).
#
# Reversibility is half the North Star ("reversible, no data loss"). The
# uninstall path shipped fully built — BCD sweep, owned-ESP cleanup, install
# dir removal, power-state restore, Add/Remove entry — with NOTHING ever
# executing it on a real machine, while #264 proved the exact failure class
# it guards against (a zombie wootc firmware entry ahead of Windows) happens
# in practice. The E2E's uninstall stage runs the DOCUMENTED command
# (wootc.exe uninstall — the same string the Add/Remove entry points at) and
# holds it to each claim separately.

E2E=tests/e2e/run-e2e.sh

@test "the uninstall stage exists, opt-in, after Windows verifiably returned" {
    grep -q 'uninstall_check()' "$E2E"
    grep -q -- '--uninstall-check' "$E2E"
    # Opt-in: default off, so showcase timelapses keep their untouched-Windows
    # ending and no run pays the extra Windows reboot unasked.
    grep -q 'WOOTC_E2E_UNINSTALL:-0' "$E2E"
    # Called in the non-phase3 branch AFTER the Windows-returned assertion —
    # uninstalling before Windows is proven back would test nothing.
    local ret_line call_line
    ret_line=$(grep -n 'One-shot Phase 2 boot consumed; Windows returned successfully' "$E2E" | head -1 | cut -d: -f1)
    call_line=$(grep -n '^    uninstall_check$' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$ret_line" ] && [ -n "$call_line" ]
    [ "$call_line" -gt "$ret_line" ]
}

@test "every cleanup claim is asserted separately, and data preservation is one of them" {
    # The documented command, not a bespoke test path.
    grep -q 'wootc.exe uninstall' "$E2E"
    # Claim: no wootc boot entry survives (the #264 zombie class).
    grep -q "a 'wootc' firmware boot entry survived" "$E2E"
    # Claim: the ESP carries nothing of ours — including the ownership-gated
    # EFI\fedora (never someone else's Linux).
    grep -q 'EFI\\\\wootc survived on the ESP' "$E2E"
    grep -q 'wootc-owned EFI\\\\fedora survived' "$E2E"
    # Claim: install state gone but root.disk PRESERVED — the default must
    # never delete the user's Linux data.
    grep -q 'INSTALL=False' "$E2E"
    grep -q 'ROOTDISK=True' "$E2E"
    grep -q 'root.disk vanished' "$E2E"
    # Claim: the Add/Remove Programs entry is unregistered.
    grep -q 'ARP=False' "$E2E"
    # Claim: the recovery scheduled tasks are unregistered.
    grep -q 'recovery scheduled tasks unregistered' "$E2E"
    # Claim: the machine then boots Windows cleanly on its own.
    grep -q 'rebooting to prove Windows boots cleanly' "$E2E"
    # Violations are fail() — collected by the ledger, not exit-on-first.
    grep -q 'fail "Uninstall:' "$E2E"
}

@test "the workflow can request the uninstall stage" {
    grep -q 'uninstall_check: { type: boolean, default: false }' .github/workflows/e2e-hosted.yml
    grep -q -- '--uninstall-check' .github/workflows/e2e-hosted.yml
}
