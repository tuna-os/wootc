#!/usr/bin/env bats
# Staged credentials must not outlive their use (#279, #281).

DEPLOY="payload/deployer/deploy.sh"

@test "the deployer shreds the NTFS copies of the browser session envelopes (#281)" {
    # The installed system already drops slurp/session; the NTFS copies on a
    # volume it mounts must go too. exports.json (status only) stays.
    grep -q "find /mnt/ntfs/wootc/install/slurp/session -maxdepth 1 -type f -name '\*.enc'" "$DEPLOY"
    grep -q -- '-exec shred -u {} +' "$DEPLOY"
}

@test "an unprotected BitLocker key is never left on disk (#279)" {
    # An ACL failure used to only warn and keep the plaintext key.
    run grep -n 'warning: ACL restriction failed for bitlocker-key.txt' app/bitlocker_windows.go
    [ "$status" -ne 0 ]
    grep -q '_ = scrubFile(keyPath)' app/bitlocker_windows.go
}

@test "uninstall scrubs staged credentials before removing the install dir (#279, #281)" {
    grep -q 'scrubInstallSecrets(filepath.Join(wDir, "install"))' app/installer_windows.go
}
