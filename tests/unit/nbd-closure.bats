#!/usr/bin/env bats
# nbd-closure.bats — qemu-nbd must be self-contained across image boundaries.
#
# ROOT CAUSE OF THE PHASE-2 EMERGENCY SHELL (2026-07-18), measured not guessed:
#
# Target bootc images generally ship no qemu-nbd (verified against
# ghcr.io/tuna-os/yellowfin:gnome), so the deployer stages its own. But the
# deployer is Fedora-based and the Phase-2 initramfs is assembled from the
# TARGET image's libraries. Running the deployer's qemu-nbd inside yellowfin:
#
#   error while loading shared libraries: libfuse3.so.4:
#   cannot open shared object file: No such file or directory
#
# because yellowfin ships libfuse3.so.3 — a soname MAJOR bump. The binary lands
# in the initramfs and dies at runtime, so the VHDX never attaches, the root
# UUID never appears, and Phase 2 drops to an emergency shell with no clue why.
#
# The fix ships the full closure (binary + every NEEDED library + Fedora's own
# ld.so) and invokes it through that loader with an explicit --library-path, so
# it never resolves against the target's libraries. Verified working: the
# closure reports qemu-nbd 10.2.2 (fc44) while running inside yellowfin.
#
# Two fixes that must NEVER be adopted, pinned below:
#   * symlinking .so.4 onto .so.3 — a soname major bump is an ABI break, and a
#     mismatched ABI in the driver writing the loop-backed ROOT FILESYSTEM
#     risks data corruption, not just a crash;
#   * matching the deployer base to the target image — wootc supports arbitrary
#     bootc images, so target library versions are not knowable in advance.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    MODSETUP="$REPO_ROOT/platform/dracut/99wootc-boot/module-setup.sh"
}

@test "both scripts are syntactically valid" {
    run bash -n "$DEPLOY"; [ "$status" -eq 0 ]
    run bash -n "$MODSETUP"; [ "$status" -eq 0 ]
}

@test "the deployer stages a closure directory, not a bare binary" {
    grep -q 'nbd-closure' "$DEPLOY"
    grep -q 'NBD_DIR' "$DEPLOY"
    grep -q 'install -m755 "\$NBD_SRC" "\$NBD_DIR/qemu-nbd"' "$DEPLOY"
}

@test "the loader name survives the subshell via a file, not a variable" {
    # The staging runs in a subshell, so a variable assignment there is lost.
    grep -q '.loader-name' "$DEPLOY"
}

@test "the closure includes every NEEDED library" {
    grep -q 'ldd "\$NBD_SRC"' "$DEPLOY"
}

@test "the closure includes its own dynamic loader" {
    # Without the loader, --library-path cannot be used and the target's ld.so
    # would resolve against the target's libraries again.
    grep -q 'ld-linux' "$DEPLOY"
    grep -q 'NBD_LOADER' "$DEPLOY"
}

@test "closure staging cannot kill the deploy" {
    # It DID: the block died silently mid-way under set -e — journal's last line
    # "resolving libraries", cleanup trap unmounting everything in the same
    # second, no error and no exit status. Auditing each command for set -e
    # exposure is fragile (a mid-script `[[ ]] && cmd` does NOT exit; only one as
    # a function's last line does — I got that diagnosis wrong once). So the
    # whole block runs in a subshell with set +e and reports an rc instead.
    local body
    body=$(sed -n '/NBD_STAGE_RC=0/,/NBD_STAGE_RC=\$?/p' "$DEPLOY")
    [ -n "$body" ]
    echo "$body" | grep -q 'set +e'
    grep -q ') || NBD_STAGE_RC=\$?' "$DEPLOY"
}

@test "each closure step is numbered so a failure names itself" {
    # One run must localise the fault; "resolving libraries" then silence cost
    # several runs on its own.
    grep -q 'closure step 1/3' "$DEPLOY"
    grep -q 'closure step 2/3' "$DEPLOY"
    grep -q 'closure step 3/3' "$DEPLOY"
}

@test "distinct exit codes distinguish the failure modes" {
    # 10=no qemu-nbd 11=mkdir 12=copy 13=cannot execute — each needs a
    # different fix, and guessing between them costs a VM run.
    grep -q 'exit 10' "$DEPLOY"
    grep -q 'exit 11' "$DEPLOY"
    grep -q 'exit 12' "$DEPLOY"
    grep -q 'exit 13' "$DEPLOY"
    grep -q '10=no qemu-nbd 11=mkdir 12=copy 13=cannot execute' "$DEPLOY"
}

@test "a staging failure is recorded, not fatal" {
    grep -q 'PHASE2_PROBLEMS+=("qemu-nbd closure staging rc=' "$DEPLOY"
}

@test "a missing qemu-nbd is reported with its own exit code" {
    # Was a hard `exit 1`; now rc=10 out of the staging subshell, recorded as a
    # Phase-2 problem. Staging a helper must not abort an otherwise-good install
    # — a missing closure means Phase 2 will not boot, which is worth reporting
    # rather than dying over.
    grep -q 'closure: no qemu-nbd in PATH' "$DEPLOY"
}

@test "the wrapper invokes the bundled loader with an explicit library path" {
    grep -q 'library-path /usr/lib/wootc-nbd' "$DEPLOY"
}

@test "module-setup installs the closure as plain files, not via inst_binary" {
    # inst_binary would resolve libraries against the target image and
    # re-introduce the exact mismatch the closure exists to avoid.
    grep -q 'inst_simple "$f" "/usr/lib/wootc-nbd/' "$MODSETUP"
    run grep -nE 'inst_binary.*qemu-nbd|^\s*inst "\$moddir/qemu-nbd"' "$MODSETUP"
    [ "$status" -ne 0 ]
}

@test "a missing closure fails the initramfs build loudly" {
    grep -q 'dfatal' "$MODSETUP"
    grep -q 'nbd-closure missing' "$MODSETUP"
}

@test "the initramfs guard checks the closure landed, not just the hook" {
    # The hook without a working qemu-nbd fails at the last step before the root
    # device appears — indistinguishable from the hook being absent.
    grep -q 'GUARD_NBD' "$DEPLOY"
    grep -q 'NOT the qemu-nbd closure' "$DEPLOY"
    grep -A3 'NOT the qemu-nbd closure' "$DEPLOY" | grep -q 'PHASE2_PROBLEMS+=('
}

@test "no soname symlink hack is present (ABI break, data-safety risk)" {
    run grep -nE 'ln -s.*libfuse3\.so\.3.*libfuse3\.so\.4|libfuse3\.so\.4.*libfuse3\.so\.3' "$DEPLOY"
    [ "$status" -ne 0 ]
}
