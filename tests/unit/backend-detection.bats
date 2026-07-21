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
