//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

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
	name, _, err := verifiedPrimaryAccount()
	if err != nil {
		return "", err
	}
	return suggestUsername(name), nil
}

// verifiedPrimaryAccount is the account name and domain of the person being
// migrated: the process token's user, accepted only when it is also the
// signed-in desktop user.
func verifiedPrimaryAccount() (name, domain string, err error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", "", fmt.Errorf("cannot verify the installer account: %w", err)
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
		return "", "", err
	}
	name, domain, _, err = user.User.Sid.LookupAccount("")
	if err != nil {
		return "", "", fmt.Errorf("cannot resolve the verified Windows account: %w", err)
	}
	return name, domain, nil
}

// primaryFullName is the migrating account's full name as Windows shows it,
// sanitised for GECOS (sanitizeFullName), or "" when Windows has none or the
// account cannot be verified: no name is better than someone else's.
func primaryFullName() string {
	name, domain, err := verifiedPrimaryAccount()
	if err != nil {
		return ""
	}
	// A local account's full name lives in the local SAM. The domain check
	// matters: NetUserGetInfo on this machine with a domain account's bare
	// name would read an unrelated local account of the same name.
	if host, err := windows.ComputerName(); err == nil && strings.EqualFold(domain, host) {
		if full := sanitizeFullName(localAccountFullName(name)); full != "" {
			return full
		}
	}
	// Domain and Entra accounts, and local ones with no SAM full name: the
	// display name Windows itself shows for the process user, which
	// verifiedPrimaryAccount just proved is the signed-in person.
	return sanitizeFullName(processUserDisplayName())
}

func localAccountFullName(account string) string {
	p, err := windows.UTF16PtrFromString(account)
	if err != nil {
		return ""
	}
	var buf *byte
	if err := windows.NetUserGetInfo(nil, p, 10, &buf); err != nil || buf == nil {
		return ""
	}
	defer windows.NetApiBufferFree(buf)
	return windows.UTF16PtrToString((*windows.UserInfo10)(unsafe.Pointer(buf)).FullName)
}

func processUserDisplayName() string {
	size := uint32(256)
	for range 2 {
		buf := make([]uint16, size)
		err := windows.GetUserNameEx(windows.NameDisplay, &buf[0], &size)
		if err == nil {
			return windows.UTF16ToString(buf[:size])
		}
		if err != windows.ERROR_MORE_DATA {
			return ""
		}
	}
	return ""
}

func checkProfileCollectionIdentity() error {
	_, err := verifiedPrimaryUsername()
	return err
}
