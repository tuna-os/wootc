#!/usr/bin/env bats
# Staged credentials must not outlive their use (#279, #281).

@test "uninstall scrubs staged credentials before removing the install dir (#279, #281)" {
    grep -q 'scrubInstallSecrets(filepath.Join(wDir, "install"))' app/installer_windows.go
}
