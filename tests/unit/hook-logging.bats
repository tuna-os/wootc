#!/usr/bin/env bats
# hook-logging.bats — the Phase-2 attach hook must be OBSERVABLE.
#
# Why this suite exists: a Phase-2 boot failed to emergency shell having emitted
# not one wootc line to serial, and we could not tell from the log whether the
# hook was absent, present-but-exited-early, or running fine with its output
# filtered. Each guess cost a full VM run. Two independent causes:
#
#   * dracut's info() writes <30> (KERN_INFO) and only echoes to stderr when
#     DRACUT_QUIET != yes — which check_quiet() defaults to "yes";
#   * dracut's warn() writes <28> (KERN_WARNING, level 4), but `quiet` sets
#     console_loglevel=4 and printk prints only levels STRICTLY BELOW it, so
#     warn is dropped too.
#
# So printk priority cannot be relied on at all — especially as the Phase-2
# cmdline differs by boot path (the GRUB path adds ignore_loglevel, the BLS
# path does not). Writing to /dev/console bypasses printk filtering entirely.
#
# These are static assertions on the script text. That is deliberate: the hook
# only runs inside an initramfs, so the property worth pinning is the one a
# refactor would silently break — that diagnostics go somewhere visible and no
# exit path is silent.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach-loop.sh"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "the hook is syntactically valid" {
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
}

@test "say() writes to /dev/console (the only threshold-independent path)" {
    grep -q '> */dev/console' "$HOOK"
}

@test "say() also emits an explicit low priority to kmsg for the journal" {
    # <27> is KERN_ERR (level 3) — below any plausible console_loglevel.
    grep -q '<27>' "$HOOK"
}

@test "the hook announces entry before any early return" {
    # Without an entry marker, "hook absent" and "hook exited immediately" are
    # indistinguishable from the serial log.
    local entry_line first_return
    entry_line=$(grep -n 'say "attach-loop hook entered' "$HOOK" | head -1 | cut -d: -f1)
    [ -n "$entry_line" ]
    # first `return 0` that is not inside a comment
    first_return=$(grep -n '^\s*\[.*\]\s*&&\s*return 0\|^\s*return 0' "$HOOK" | head -1 | cut -d: -f1)
    [ -n "$first_return" ]
    [ "$entry_line" -lt "$first_return" ]
}

@test "diagnostics never use dracut info()/warn(), which printk filters away" {
    # The success path used info() and was invisible by default; the failure
    # path used warn() and was invisible under `quiet`.
    run grep -nE '^\s*(info|warn) ' "$HOOK"
    [ "$status" -ne 0 ]
}

@test "every failure exit states a reason" {
    # Each EXIT: line is a distinct diagnosis: missing kargs, NTFS unmountable,
    # vhdx missing, qemu-nbd failed. Fewer than four means an exit went silent.
    local n
    n=$(grep -c 'say "EXIT:' "$HOOK")
    [ "$n" -ge 4 ]
}

@test "the hook reports what appeared after attach, not just that it attached" {
    # Attaching is not the goal — the root UUID appearing to udev is. A boot can
    # attach successfully and still land in the emergency shell.
    grep -q 'post-attach by-uuid' "$HOOK"
    grep -q 'post-attach partitions' "$HOOK"
}

# ── deployer side ───────────────────────────────────────────────────────────
# The initramfs guard (deploy.sh) is what distinguishes "hook absent" from the
# hook's own exit reasons — but its output never reached the E2E log because
# log() wrote to kmsg with no <N> prefix, inheriting the default level.

@test "deployer log()/err() emit an explicit kmsg priority" {
    grep -q "printf '<27>\[wootc\] %s" "$DEPLOY"
    grep -q "printf '<27>\[wootc\] ERROR: %s" "$DEPLOY"
}

@test "deployer log()/err() do NOT also write to /dev/console" {
    # Regression guard, learned the hard way. deploy.sh emits hundreds of lines
    # during bootc install. With stdout + kmsg-forwarded-to-console + a direct
    # console write, each line went out THREE times over a 115200-baud serial;
    # the link saturated and a blocking console write stalled the deployer at
    # `phase: verification` on all three runners.
    #
    # The <27> priority already reaches the console under `quiet` (level 3 <
    # console_loglevel 4), so the extra write bought nothing. One kmsg write.
    run grep -nE "printf .*> */dev/console" "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the low-volume Phase-2 hook DOES still write to /dev/console" {
    # Different volume, different call: a handful of lines at boot, diagnosing a
    # path we have never seen work. Belt and braces is right here and wrong in
    # the installer.
    grep -q '> */dev/console' "$HOOK"
}

@test "the initramfs hook guard still aborts the deploy when the hook is missing" {
    # This guard is the only thing that turns a silent 5-minute Phase-2 wedge
    # into a loud Phase-1 failure. Pin that it exits rather than warning.
    grep -q 'MISSING wootc-attach-loop.sh' "$DEPLOY"
    grep -A1 'MISSING wootc-attach-loop.sh' "$DEPLOY" | grep -q 'exit 1'
}
