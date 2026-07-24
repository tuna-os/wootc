#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
    E2E="${E2E:-$REPO_ROOT/tests/e2e/run-e2e.sh}"
    PS1="${PS1:-$REPO_ROOT/tests/e2e/setup-wootc.ps1}"
}

@test "deployer accepts auto before image backend detection" {
    run awk '
        /case "\$BOOTLOADER" in/ { validation = NR; accepts_auto = ($0 ~ /grub2\|systemd\|auto/) }
        /if \[\[ "\$COMPOSEFS" == auto \|\| "\$BOOTLOADER" == auto \]\]/ { detection = NR }
        END { exit !(validation && accepts_auto && detection && validation < detection) }
    ' "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "E2E and Windows setup pass auto through by default" {
    run grep -F 'E2E_BOOTLOADER="${WOOTC_E2E_BOOTLOADER:-auto}"' "$E2E"
    [ "$status" -eq 0 ]

    run grep -F '[ValidateSet("grub2", "systemd", "auto")]' "$PS1"
    [ "$status" -eq 0 ]

    run grep -F '[string]$Bootloader = "auto"' "$PS1"
    [ "$status" -eq 0 ]
}

@test "backend detection falls back to safe defaults when the probe fails or is ambiguous" {
    # Contract since 95b0ab5/2d76cce: a hung or failed image probe must NOT
    # abort the deploy (that lost completed installs on flaky podman). It is
    # bounded by a timeout and falls back to ostree/grub2 + SEALED=1 with a
    # loud WARN; an unrecognized backend signal likewise defaults with a WARN.
    run grep -F 'if ! DETECT="$(timeout 30 podman run' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'podman run image inspection timed out/failed; falling back to default backend' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'BACKEND=unknown' "$DEPLOY"
    [ "$status" -eq 0 ]

    run grep -F 'unrecognized backend signal; defaulting to ostree/grub2' "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "current bootupd versioned EFI layout is recognized as ostree" {
    grep -Fq 'test -f /usr/lib/bootupd/updates/EFI.json' "$DEPLOY"
    grep -Fq 'find /usr/lib/efi/grub2 -type f -name grubx64.efi' "$DEPLOY"
    grep -Fq 'find /usr/lib/efi/shim -type f -name shimx64.efi' "$DEPLOY"
}

@test "ESP staging supports the current versioned shim and GRUB layout" {
    grep -Fq 'find "$DEPLOY_ROOT/usr/lib/efi/grub2"' "$DEPLOY"
    grep -Fq '*/EFI/$vendor_dir/shimx64.efi' "$DEPLOY"
    grep -Fq '*/EFI/$TARGET_VENDOR/mmx64.efi' "$DEPLOY"
    run grep -nE '^[^#]*dirname.*TARGET_GRUB' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "ESP staging logs every selected source and fails closed" {
    grep -Fq 'ESP source kernel=${KERNEL_SRC:-missing}' "$DEPLOY"
    grep -Fq 'ESP source initramfs=${INITRD_SRC:-missing}' "$DEPLOY"
    grep -Fq 'ESP source shim=${TARGET_SHIM:-missing}' "$DEPLOY"
    grep -Fq 'ESP source grub=${TARGET_GRUB:-missing}' "$DEPLOY"
    local fail_line exit_line
    fail_line=$(grep -n 'Phase-2 ESP sync failed' "$DEPLOY" | tail -1 | cut -d: -f1)
    exit_line=$(awk -v start="$fail_line" 'NR > start && /exit 1/ { print NR; exit }' "$DEPLOY")
    [ -n "$fail_line" ] && [ -n "$exit_line" ]
    [ "$exit_line" -le $((fail_line + 8)) ]
}

@test "initramfs regen KVER comes from the module tree that owns vmlinuz" {
    # bluefin:lts ships TWO /usr/lib/modules trees: 6.12.0-225 (stripped
    # leftover, no vmlinuz) and 6.12.0-233 (bootable). `ls | head -1` picked
    # 225, dracut built a 225-module initramfs, the 233 kernel booted it, and
    # not one storage driver could load — 60s of "Present devices: none" and
    # an emergency shell, with no error anywhere. The pick must require
    # vmlinuz and take the highest such version.
    grep -Fq '[[ -f "$d/vmlinuz" ]] && basename "$d"' "$DEPLOY"
    run grep -nE 'KVER=\$\(ls [^)]*head -1\)' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "deploy.sh uses no binaries absent from the initramfs closure" {
    # $(dirname ...) killed every deploy at t=33s under set -e — the
    # initramfs has no dirname (run 20260723T1331). Path math must use
    # parameter expansion; add to this list anything else the closure lacks.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    for missing in dirname; do
        run grep -nE "^[^#]*\\\$\\($missing " "$dep"
        [ "$status" -ne 0 ]
    done
}

@test "filesystem defaults: xfs unsealed, btrfs sealed; ext4 only by request" {
    # xfs is the product default; a sealed rootfs needs fs-verity, which
    # xfs lacks — btrfs has it natively (>= 5.15), so it is the sealed
    # fallback. ext4 (-O verity) stays reachable via wootc.filesystem=.
    # The initramfs must be able to mount both defaults: xfs.ko was
    # missing until GH repro 20260724T0031.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -q 'read_cmdline wootc.filesystem xfs' "$dep"
    grep -q 'FILESYSTEM=btrfs' "$dep"
    grep -B7 'FILESYSTEM=btrfs' "$dep" | grep -q 'ROOTFS_SEALED'
    run grep -nE '^[^#]*FILESYSTEM=ext4$' "$dep"
    [ "$status" -ne 0 ]
    grep -q -- '--add-drivers "xfs btrfs"' "$REPO_ROOT/payload/deployer/Containerfile"
    grep -q 'xfs.ko' "$REPO_ROOT/payload/deployer/Containerfile"
}

@test "dracut regen failures report dracut's own output" {
    # Bare stderr reaches only the serial console (harness never surfaces
    # it, CI truncates it): three regen failures reported nothing but
    # exit=1. The tail must go through err/log so it also lands in the
    # persistent deployer.log.
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -q 'dracut-regen.log' "$dep"
    grep -q 'err "  dracut: \$dline"' "$dep"
}
