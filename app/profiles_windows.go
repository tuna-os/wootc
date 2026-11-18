//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// listWindowsProfiles enumerates real Windows profiles on this machine. See
// profiles.go for the rules and the reasoning.
func listWindowsProfiles(primary string) ([]ProfileAccount, error) {
	dir := primaryProfileDir()
	if dir == "" {
		return nil, fmt.Errorf("cannot identify your Windows profile from the process token; sign in with your own administrator account and check the plan again")
	}
	return listProfilesIn(filepath.Join(systemDriveRoot(), "Users"), primary, dir)
}

// The profile comes from the Windows token, never inherited USERPROFILE:
// the latter can name the elevating administrator or be supplied by a caller.
func primaryProfileDir() string {
	profile, err := windows.GetCurrentProcessToken().GetUserProfileDirectory()
	if err != nil || !filepath.IsAbs(profile) {
		return ""
	}
	return filepath.Base(profile)
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

func verifiedPrimaryUsername() (string, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("cannot verify the installer account: %w", err)
	}
	interactive := queryInteractiveUser()
	var interactiveSID string
	if interactive != "" {
		sid, _, _, err := windows.LookupSID("", interactive)
		if err == nil {
			interactiveSID = sid.String()
		}
	}
	if err := requireMatchingProfileIdentity(user.User.Sid.String(), interactiveSID); err != nil {
		return "", err
	}
	name, _, _, err := user.User.Sid.LookupAccount("")
	if err != nil {
		return "", fmt.Errorf("cannot resolve the verified Windows account: %w", err)
	}
	return suggestUsername(name), nil
}

func checkProfileCollectionIdentity() error {
	_, err := verifiedPrimaryUsername()
	return err
}
