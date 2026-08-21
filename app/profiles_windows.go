//go:build windows

package main

import (
	"os"
	"path/filepath"
)

// listWindowsProfiles enumerates real Windows profiles on this machine. See
// profiles.go for the rules and the reasoning.
func listWindowsProfiles(primary string) []profileMapping {
	return listProfilesIn(filepath.Join(systemDriveRoot(), "Users"), primary, primaryProfileDir())
}

// primaryProfileDir is the basename of the running user's own Windows profile
// directory ("James Reilly" for C:\Users\James Reilly). USERPROFILE is set for
// every interactive session; empty just means no directory-based exclusion.
func primaryProfileDir() string {
	if p := os.Getenv("USERPROFILE"); p != "" {
		return filepath.Base(p)
	}
	return ""
}

// systemDriveRoot is where Windows profiles live. Note this is NOT wootcDir()'s
// drive: wootc's own storage can be moved to a data volume when C: is
// BitLocker-protected (SPEC 3.5), but the profiles stay on the system drive.
func systemDriveRoot() string {
	if d := os.Getenv("SystemDrive"); d != "" {
		return d + `\`
	}
	return `C:\`
}
