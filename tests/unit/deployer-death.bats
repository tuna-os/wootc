#!/usr/bin/env bats
# deployer-death.bats — a dead deployer must be detected, not waited out.
#
# WHAT HAPPENED (himachal + the hosted runner, same day):
#
# The deploy actually SUCCEEDED through fisherman —
#   08:03:09 phase: fisherman — this pulls the image and deploys it...
#   08:13:46 phase: verification          <- 10 minutes, image installed
#   08:13:47 Mounted installed system root at /dev/nbd1p3
#   08:13:47   ostree deployment: /ostree/deploy/default/deploy/2f09...
# and then STOPPED. 31 minutes later: "reboot: Restarting system".
#
# The guest came back as Windows. But the harness kept printing "Deploying..."
# for another 76 minutes and finally reported a timeout, because:
#
#   1. DEPLOYER_REBOOT_SEEN only matched the deployer's own "Rebooting" string,
#      not the KERNEL's "reboot: Restarting system"; and
#   2. nothing treated "Windows is answering QGA again" as evidence that the
#      deployer is no longer running.
#
# Manual inspection of the live VM found this in two minutes — `qga powershell
# $env:OS` returned Windows_NT while the harness still believed a Linux deployer
# was mid-install. Ninety-minute blind waits cost far more than they save.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="${E2E:-$REPO_ROOT/tests/e2e/run-e2e.sh}"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
}

@test "both scripts are syntactically valid" {
    run bash -n "$E2E";    [ "$status" -eq 0 ]
    run bash -n "$DEPLOY"; [ "$status" -eq 0 ]
}

@test "a kernel reboot is NOT treated as a successful deploy" {
    # I introduced this bug while fixing the previous one: folding
    # "reboot: Restarting system" into DEPLOYER_REBOOT_SEEN made a WATCHDOG
    # reboot look deliberate, so a dead deploy reported
    #   [PASS] wootc: deployer rebooted and Windows QGA returned
    # and Phase 2 was then scheduled against a system that had never been set
    # up — it re-ran the installer and died on sysroot.mount.
    #
    # The two signals must stay distinct: only the deployer's own "Rebooting"
    # implies success.
    grep -q 'KERNEL_REBOOT_SEEN=true' "$E2E"
    # the deliberate-reboot branch must NOT match the kernel string
    local delib
    delib=$(grep -n "grep -qE '(^|\[^\[:alpha:\]\])Rebooting" "$E2E" | head -1)
    [ -n "$delib" ]
    echo "$delib" | grep -q 'Restarting system' && return 1
    return 0
}

@test "a kernel reboot with no verification summary fails loudly" {
    grep -q 'kernel reboot with no verification summary' "$E2E"
    grep -q 'watchdog signature' "$E2E"
}

@test "the kernel-reboot failure explains that Phase-2 setup never ran" {
    # Without this the next reader repeats the mistake of debugging Phase 2
    # when the real problem is that Phase-2 setup never executed.
    grep -q 'Phase-2 setup (BLS entry' "$E2E"
}

@test "Windows answering QGA without completion is a failure, not a wait" {
    grep -q 'WINDOWS_BACK_STREAK' "$E2E"
    grep -q 'Deployer is gone' "$E2E"
}

@test "the streak resets when Windows is NOT answering" {
    # Otherwise a single probe blip mid-deploy accumulates toward a false abort.
    grep -q 'WINDOWS_BACK_STREAK=0' "$E2E"
}

@test "the failure prints the deployer's own log, not just a verdict" {
    # The persisted log is the whole story once the deployer is gone.
    grep -q 'Last lines of the deployer.s own log' "$E2E"
}

# ── the silent stretch that hid the hang ────────────────────────────────────

@test "the post-fisherman verification stretch is instrumented" {
    # The journal's last line was the /boot mount, and everything after it was
    # silent — so a 31-minute hang could not be localised to a step.
    local n
    n=$(grep -c 'log "  verify:' "$DEPLOY")
    [ "$n" -ge 4 ]
}

@test "no staged binary is executed during the deploy any more" {
    # There WAS one: the qemu-nbd closure self-test. Executing a staged binary
    # mid-deploy is indistinguishable from a wedged deployer when it blocks.
    # The raw/losetup switch removed the staging entirely, so the risk is gone
    # rather than bounded.
    run grep -nE '^[^#]*\$NBD_DIR' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the dracut regen is bounded — it cannot hang the deploy forever" {
    # `chroot ... dracut` writes nothing to the journal, so a block there looks
    # exactly like a dead deployer. It was unbounded, and the observed 31-minute
    # silence began in this stretch.
    local n
    n=$(grep -c 'timeout 900 chroot' "$DEPLOY")
    [ "$n" -ge 2 ]
}

@test "a regen timeout aborts rather than booting a stale initramfs" {
    # Continuing without a rebuilt initramfs guarantees Phase 2 cannot boot.
    grep -q 'dracut regen TIMED OUT' "$DEPLOY"
    grep -A3 'dracut regen TIMED OUT' "$DEPLOY" | grep -q 'exit 1'
}

@test "the regen announces itself before starting" {
    grep -q 'verify: regenerating Phase-2 initramfs' "$DEPLOY"
}

@test "both dracut regeneration paths explicitly include OSTree prepare-root" {
    # A mounted root UUID is insufficient for an OSTree deployment. In a
    # foreign chroot dracut omitted 50ostree unless explicitly requested, then
    # initrd-switch-root failed after /sysroot mounted successfully.
    local n
    n=$(grep -c -- '--add "ostree wootc-boot"' "$DEPLOY")
    [ "$n" -eq 2 ]
}

@test "the generated initramfs guard requires wired OSTree prepare-root" {
    grep -Fq "usr/lib/ostree/ostree-prepare-root$" "$DEPLOY"
    grep -Fq "initrd-root-fs.target.wants/ostree-prepare-root.service( ->|$)" "$DEPLOY"
    grep -q 'Phase-2 initramfs lacks wired ostree-prepare-root' "$DEPLOY"
}

@test "the OSTree wiring guard accepts lsinitrd symlink output" {
    local listing='lrwxrwxrwx 1 root root 30 Jan 1 1970 usr/lib/systemd/system/initrd-root-fs.target.wants/ostree-prepare-root.service -> ../ostree-prepare-root.service'
    echo "$listing" | grep -qE 'initrd-root-fs.target.wants/ostree-prepare-root.service( ->|$)'
}

@test "the deployed chroot has a valid sticky var tmp before dracut" {
    local prep_line regen_line
    prep_line=$(grep -n 'mkdir -p "\$DEPLOY_ROOT/var/tmp"' "$DEPLOY" | head -1 | cut -d: -f1)
    regen_line=$(grep -n 'timeout 900 chroot "\$DEPLOY_ROOT" dracut' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$prep_line" ] && [ -n "$regen_line" ]
    [ "$prep_line" -lt "$regen_line" ]
    grep -q 'chmod 1777 "\$DEPLOY_ROOT/var/tmp"' "$DEPLOY"
}

@test "ostree usr-local backing directory exists before bridge installation" {
    local mkdir_line install_line
    mkdir_line=$(grep -n 'install -d -m755 "\$DEPLOY_ROOT/var/usrlocal/bin"' "$DEPLOY" | cut -d: -f1)
    install_line=$(grep -n 'wootc-mount-user-dirs' "$DEPLOY" | tail -1 | cut -d: -f1)
    [ -n "$mkdir_line" ] && [ -n "$install_line" ]
    [ "$mkdir_line" -lt "$install_line" ]
}

@test "post-install writes use the OSTree stateroot var visible at runtime" {
    local bind_line install_line unmount_line
    bind_line=$(grep -n 'mount --bind "\$OSTREE_VAR_ROOT" "\$DEPLOY_ROOT/var"' "$DEPLOY" | cut -d: -f1)
    install_line=$(grep -n 'wootc-go-native  "\$DEPLOY_ROOT/usr/local/bin/wootc-go-native"' "$DEPLOY" | cut -d: -f1)
    unmount_line=$(grep -n 'umount "\$DEPLOY_ROOT/var"' "$DEPLOY" | tail -1 | cut -d: -f1)
    [ -n "$bind_line" ] && [ -n "$install_line" ] && [ -n "$unmount_line" ]
    [ "$bind_line" -lt "$install_line" ]
    [ "$install_line" -lt "$unmount_line" ]
    grep -q 'DEPLOY_VAR_BOUND=true' "$DEPLOY"
}

@test "stateroot paths need no dirname binary in the minimal initramfs" {
    run grep -nE '^[^#]*dirname' "$DEPLOY"
    [ "$status" -ne 0 ]
    grep -Fq 'DEPLOY_PARENT="${DEPLOY_ROOT%/*}"' "$DEPLOY"
    grep -Fq 'OSTREE_STATEROOT="${DEPLOY_PARENT%/*}"' "$DEPLOY"
}

@test "post-install payload is relabeled and Phase-3 label is verified" {
    local install_line restore_line verify_line
    install_line=$(grep -n 'wootc-go-native  "\$DEPLOY_ROOT/usr/local/bin/wootc-go-native"' "$DEPLOY" | cut -d: -f1)
    restore_line=$(grep -n 'chroot "\$DEPLOY_ROOT" restorecon -RF' "$DEPLOY" | cut -d: -f1)
    verify_line=$(grep -n 'Phase-3 executable SELinux context' "$DEPLOY" | cut -d: -f1)
    [ -n "$install_line" ] && [ -n "$restore_line" ] && [ -n "$verify_line" ]
    [ "$install_line" -lt "$restore_line" ]
    [ "$restore_line" -lt "$verify_line" ]
    grep -q 'wootc-go-native remains unlabeled' "$DEPLOY"
}

@test "nonfatal Phase-2 checks are still collected into one verdict" {
    # Independent verification checks are accumulated, while prerequisites
    # such as a successfully rebuilt initramfs fail closed above.
    grep -q 'PHASE2_PROBLEMS=()' "$DEPLOY"
    local n
    n=$(grep -c 'PHASE2_PROBLEMS+=(' "$DEPLOY")
    [ "$n" -ge 1 ]
}

@test "the collected problems are reported as one summary" {
    grep -q 'Phase-2 setup completed with \${#PHASE2_PROBLEMS\[@\]} problem' "$DEPLOY"
    grep -q 'Phase 2 will NOT boot correctly' "$DEPLOY"
}

@test "a clean Phase-2 setup says so explicitly" {
    # Absence of errors is not evidence; the positive statement is.
    grep -q 'Phase-2 setup completed with no problems' "$DEPLOY"
}

@test "instrumentation brackets the dracut module copy and the closure" {
    grep -q 'verify: copying 99wootc-boot dracut module' "$DEPLOY"
    grep -q 'verify: dracut module copied' "$DEPLOY"
    # closure staging is now reported per numbered step
    grep -q 'no binary staging needed for raw' "$DEPLOY"
}
