#!/usr/bin/env bats
# phase2-second-boot.bats — the BitLocker cell must see a SECOND Phase-2 boot.
#
# The bridge unlocks the encrypted C: on every boot. The recovery key used to
# be shredded by the bridge's own ExecStop, so a run that booted Phase 2 once
# passed while the user's second boot came up with an empty Documents (#279).
# These tests drive phase2_second_boot_check with every guest helper stubbed:
# no VM, no QGA, only the decisions.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    LIB="$REPO_ROOT/tests/e2e/lib/phase2-second-boot.sh"
    CALLS="$BATS_TEST_TMPDIR/calls"
    : > "$CALLS"
}

# absent <grep args...>: fail when the pattern IS found. A bare `! grep`
# does not fail a bats test mid-body (set -e ignores negated commands).
absent() {
    if grep "$@"; then echo "unexpected match: $*" >&2; return 1; fi
}

# drive <linux|windows|none> <userdata> [bcd-verified=yes] [still-linux-after-reboot=no]
drive() {
    run bash -c '
        set -uo pipefail
        source "$1"
        CALLS="$2"; SEEN="$3"; USERDATA="$4"; BCD="${5:-yes}"; STUCK="${6:-no}"
        RUN_ID=run-2nd-boot
        USERDATA_PATH="/home/wootc/Documents/From Windows/wootc-e2e-userdata.txt"
        rec() { printf "%s\n" "$*" >> "$CALLS"; }
        step() { :; }; pass() { :; }; info() { :; }; warn() { rec "warn $*"; }
        product_pass() { rec "product_pass $1"; }
        product_fail() { rec "product_fail $*"; }
        infra_fail() { rec "infra_fail $*"; }
        deadline_in() { echo 3; }
        T=0; past_deadline() { T=$((T + 1)); [ "$T" -gt "$1" ]; }
        sleep() { :; }
        qga_powershell() {
            case "$1" in
                *"/enum {fwbootmgr}"*) [ "$BCD" = yes ] && echo "bootsequence {guid-1}" ;;
                *shutdown.exe*) rec "windows-reboot" ;;
                *bootsequence*) rec "arm $1" ;;
                *Length*) echo 1024 ;;
            esac
            return 0
        }
        qga_wait_down() { rec "wait-down"; }
        qga_linux_probe() { [ "$SEEN" = linux ]; }
        qga_windows_probe() { [ "$SEEN" = windows ]; }
        qga_call() {
            case "$*" in
                *wootc-e2e-userdata.txt*) printf "%s" "$USERDATA" ;;
                *home-bind*) printf "home-bind: %s\n" "${BIND:-/dev/sda4[/Users/wootc/Documents]}" ;;
                *"systemctl reboot"*) rec "linux-reboot" ;;
            esac
            return 0
        }
        p2_reboot_observe() { [ "$STUCK" = yes ] && echo linux || echo windows; }
        reset_guest() { rec "reset"; }
        qga_wait_windows() { rec "wait-windows"; }
        phase2_second_boot_check "{guid-1}" "E:" reset_guest
        echo "rc=$?"
    ' adapter "$LIB" "$CALLS" "$@"
}

@test "the seeded file read on the second boot records user-data-second-boot" {
    drive linux "wootc-e2e-userdata run-2nd-boot"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    grep -qx 'product_pass user-data-second-boot' "$CALLS"
    absent -q '^product_fail' "$CALLS"
    # It actually re-armed and rebooted, then brought Windows back.
    grep -q '^arm .*bootsequence {guid-1}' "$CALLS"
    grep -qx 'windows-reboot' "$CALLS"
    grep -qx 'wait-windows' "$CALLS"
}

@test "a file without an unlock observation is not reported as a recovery-key proof" {
    drive linux "wootc-e2e-userdata run-2nd-boot"
    grep -qx 'product_pass user-data-second-boot' "$CALLS"
    grep -q '^warn .*BitLocker unlock was not observed' "$CALLS"
}

@test "a file served from the unlocked BitLocker mapper says so, with no warning" {
    BIND='/dev/mapper/wootc-bitlk-812[/Users/wootc/Documents]' drive linux "wootc-e2e-userdata run-2nd-boot"
    grep -qx 'product_pass user-data-second-boot' "$CALLS"
    absent -q '^warn' "$CALLS"
}

@test "an empty Documents on the second boot is a product failure, never a pass" {
    drive linux ""
    grep -q '^product_fail Second Phase 2 boot: Windows Documents file NOT readable' "$CALLS"
    absent -q '^product_pass' "$CALLS"
    # Windows is still brought back so the rest of the run can report.
    grep -qx 'wait-windows' "$CALLS"
}

@test "a stale file from another run does not pass" {
    drive linux "wootc-e2e-userdata some-older-run"
    absent -q '^product_pass' "$CALLS"
    grep -q '^product_fail' "$CALLS"
}

@test "Windows answering instead of Linux is a product failure (the second boot never happened)" {
    drive windows "wootc-e2e-userdata run-2nd-boot"
    grep -q '^product_fail Second Phase 2 boot did not happen' "$CALLS"
    absent -q '^product_pass' "$CALLS"
}

@test "no agent at all is inconclusive, not a product verdict" {
    drive none ""
    [[ "$output" == *"rc=1"* ]]
    grep -q '^infra_fail' "$CALLS"
    absent -q '^product_' "$CALLS"
}

@test "an unverified bootsequence refuses to reboot" {
    drive linux "wootc-e2e-userdata run-2nd-boot" no
    [[ "$output" == *"rc=1"* ]]
    grep -q '^infra_fail Second Phase 2 boot: BCD bootsequence' "$CALLS"
    absent -qx 'windows-reboot' "$CALLS"
}

@test "the reset fires only on a positively identified Linux agent" {
    drive linux "wootc-e2e-userdata run-2nd-boot" yes no
    absent -qx 'reset' "$CALLS"
    : > "$CALLS"
    drive linux "wootc-e2e-userdata run-2nd-boot" yes yes
    grep -qx 'reset' "$CALLS"
}

@test "run-e2e requires user-data-second-boot on the BitLocker full cycle only" {
    local block
    block=$(sed -n '/^# The BitLocker cell boots Phase 2 twice/,/^fi$/p' "$E2E")
    [ -n "$block" ]
    check() {  # check <scenario> <bitlocker> <required-before>
        RESULT_SCENARIO="$1" WOOTC_E2E_BITLOCKER="$2" RESULT_REQUIRED="$3" \
            bash -c "$block"$'\n''printf "%s" "$RESULT_REQUIRED"'
    }
    [ "$(check full-cycle on '')" = user-data-second-boot ]
    [ "$(check full-cycle on gui-install)" = gui-install,user-data-second-boot ]
    [ "$(check full-cycle off '')" = '' ]
    [ "$(check native-cycle on '')" = '' ]
    [ "$(check recovery on '')" = '' ]
}

@test "run-e2e runs the second boot after the healthy assertion and before uninstall" {
    local healthy second uninstall
    healthy=$(grep -n 'product_pass healthy ' "$E2E" | tail -1 | cut -d: -f1)
    second=$(grep -n 'phase2_second_boot_check "\$PHASE2_GUID"' "$E2E" | cut -d: -f1)
    uninstall=$(grep -n '^    uninstall_check$' "$E2E" | tail -1 | cut -d: -f1)
    [ -n "$healthy" ] && [ -n "$second" ] && [ -n "$uninstall" ]
    [ "$second" -gt "$healthy" ]
    [ "$second" -lt "$uninstall" ]
    sed -n "$((second - 10)),${second}p" "$E2E" | grep -q 'WOOTC_E2E_BITLOCKER:-off}" = on'
}

@test "results.py accepts user-data-second-boot as a contract assertion" {
    grep -q "'user-data-second-boot'" "$REPO_ROOT/tests/e2e/lib/results.py"
}
