source "$BEFORE_SOURCE"
fixture_capture_windows_boot() { printf '%s' '{"schemaVersion":1,"os":"Windows_NT","bootId":"134350000000000001"}' > "$1"; }
fixture_qmp_optical_command() { echo reattached-medium-observed >&2; return 1; }
fixture_verify_windows_boot_after_detach && echo pre-activation-boot-gate-accepted-without-current-media-observation
