#!/usr/bin/env bats
# esp-chain-refresh.bats — the signed chain on the Windows ESP must not rot
# (#333).
#
# Phase-2 boots through shim → GRUB on the WINDOWS ESP, because signed GRUB
# cannot read NTFS. Those binaries are staged once by the installer and then
# never touched, while the deployment they boot keeps updating. Microsoft
# ships SBAT revocations through Windows Update: when a generation is
# revoked, firmware stops launching a shim below it, and a machine that
# booted Linux yesterday stops today with no change the user made.
#
# The behavioural coverage lives in tests/unit/test_esp_chain_refresh.py,
# which drives the real script against a fake ESP. These pin the contract
# that makes it safe.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SYNC="$REPO_ROOT/payload/migration/wootc-esp-sync"
    TRUST="$REPO_ROOT/payload/migration/wootc-shim-trust"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "the refresh is gated: no trust helper, no chain changes" {
    # An ungated copy is the dangerous version of this feature. Without the
    # grader the script must fall back to the pre-#333 behaviour.
    [ -x "$TRUST" ]
    grep -q 'command -v wootc-shim-trust' "$SYNC"
    grep -q 'leaving the signed chain alone' "$SYNC"
}

@test "only a vendor directory wootc owns is touched" {
    # The same marker the Windows installer's D1 guard uses to refuse
    # clobbering another Linux — applied again on every boot, because a
    # second OS can be installed after us.
    grep -q "grep -q '# wootc'" "$SYNC"
}

@test "shim is replaced LAST, after GRUB and MokManager" {
    # A power cut mid-refresh must leave a shim that can still verify the
    # GRUB beside it. New shim over old GRUB is the combination that does
    # not boot.
    grep -q 'for f in grubx64.efi mmx64.efi shimx64.efi' "$SYNC"
}

@test "the current chain is archived before anything replaces it" {
    grep -q 'EFI/wootc/archive' "$SYNC"
    grep -q 'refusing to replace what we cannot put back' "$SYNC"
    # ...and restored when the write or the post-write check fails.
    grep -q 'restoring from the archive' "$SYNC"
}

@test "the candidate is graded against the firmware AND the installed SBAT" {
    grep -q 'def firmware_db' "$TRUST"
    grep -q 'def sbat_generation' "$TRUST"
    grep -q 'A downgrade is what revocation blocks' "$TRUST"
    # Secure Boot on with an unreadable db keeps what already boots.
    grep -q 'trust store could not be read' "$TRUST"
}

@test "SBAT is read from the .sbat section, not the first matching string" {
    # shim embeds its revocation policy elsewhere in the binary; matching the
    # first 'shim,N' anywhere would read the wrong number.
    grep -q "name != \".sbat\"" "$TRUST"
    python3 -c "import ast;ast.parse(open('$TRUST').read())"
}

@test "the helper and the update trigger travel into the deployment" {
    grep -q 'wootc-shim-trust' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -q 'wootc-esp-sync.path' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -q 'mig_opt 755 wootc-shim-trust' "$DEPLOY"
    grep -q 'wootc-esp-sync.path' "$DEPLOY"
    # The trigger watches what bootc upgrade rewrites, so an updated chain
    # reaches the ESP on the boot that staged it rather than one boot later.
    grep -q 'PathChanged=/usr/lib/bootupd/updates/EFI.json' \
        "$REPO_ROOT/payload/migration/wootc-esp-sync.path"
}
