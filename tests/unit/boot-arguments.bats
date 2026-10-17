#!/usr/bin/env bats
# Every Python reader of the root.disk boot arguments uses one rule: repeats of
# one value are one argument, different values are refused (#332 follow-up).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LIB="$REPO_ROOT/payload/migration/lib"
    # Shape of the Phase-2 grub.cfg line deploy.sh writes, as booted by
    # E2E 38996488933 (bluefin:lts): BLS options carrying both arguments,
    # then both appended again.
    PHASE2='BOOT_IMAGE=(hd0,gpt1)/EFI/wootc/phase2-vmlinuz root=UUID=0b3c rw ostree=/ostree/boot.1/default/abc/0 wootc.host_uuid=1234567890ABCDEF loop=/wootc/disks/root.disk loop=/wootc/disks/root.disk wootc.host_uuid=1234567890ABCDEF console=tty1 console=ttyS0,115200'
}

@test "deploy.sh still writes the repeated arguments the readers must accept" {
    grep -qF 'linux /EFI/wootc/phase2-vmlinuz ${ROOT_OPTIONS} loop=/wootc/disks/root.disk wootc.host_uuid=${HOST_UUID}' \
        "$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "the ESP controller's boot identity reads the real Phase-2 command line" {
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wootc_boot_identity as b; t = sys.argv[2].split(); print(b.boot_argument(t, "loop"), b.boot_argument(t, "wootc.host_uuid"))' "$LIB" "$PHASE2"
    [ "$status" -eq 0 ]
    [ "$output" = "/wootc/disks/root.disk 1234567890ABCDEF" ]
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import wootc_boot_identity as b; b.boot_argument(sys.argv[2].split(), "wootc.host_uuid")' "$LIB" "$PHASE2 wootc.host_uuid=FEDCBA0987654321"
    [ "$status" -ne 0 ]
    [[ "$output" == *"conflicting boot arguments: wootc.host_uuid"* ]]
}

@test "no Python payload keeps its own exactly-one boot argument check" {
    # observe_installed_boot and the first-boot collector both call
    # wootc_boot_identity.boot_argument; a private copy would drift back.
    [ "$(grep -c 'def boot_argument' "$LIB/wootc_boot_identity.py")" -eq 1 ]
    grep -q "boot_argument(tokens, 'loop')" "$LIB/wootc_boot_identity.py"
    grep -q '^cmdline_argument = boot_argument$' "$LIB/wootc_firstboot_evidence.py"
    run grep -rnE "duplicate (loop )?boot argument" "$REPO_ROOT/payload" --include='*.py'
    [ "$status" -ne 0 ]
    run grep -rlE "startswith\(name \+ '='\)" "$REPO_ROOT/payload" --include='*.py'
    [ "$output" = "$LIB/wootc_boot_identity.py" ]
}
