package main

import (
	"os"
	"path/filepath"
)

// hasInstallAttempt distinguishes a provisioned offline bundle from a machine
// whose installation began. Downloads, branding, the executable and an empty
// logs/state directory exist before the user clicks Install; they must not
// route a first launch to the existing-install Control Panel.
//
// These are outputs of installation, including the power snapshot written
// before the first Windows setting changes. Presence is enough: a truncated
// marker still represents an interrupted attempt that must remain removable.
func hasInstallAttempt(root string) bool {
	for _, relative := range []string{
		"state.json", "known-folders.json",
		"disks/root.disk", "disks/root.vhdx",
		"install/prior-power.txt", "install/vault.json", "install/grub.install.cfg",
		"install/bcd-before.bak", "install/bcd-guid.txt", "install/armed.json",
		"install/deployer-started.json", "install/recovery-verdict.json",
		"logs/deployer.log", "logs/deployer-last-journal.log",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(relative))); err == nil || !os.IsNotExist(err) {
			return true
		}
	}
	return false
}
