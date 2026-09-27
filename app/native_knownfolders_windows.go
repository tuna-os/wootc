//go:build windows

package main

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/sys/windows"
)

// collectKnownFolders consumes the retained authenticated source token. Its
// private sink belongs to an operation session; assessment RPC cannot supply it.
// No cloud-content count or cross-volume bridge eligibility is inferred here.
func (user *nativeOriginalUser) collectKnownFolders(sink func(*KnownFolders) error) error {
	if user == nil || sink == nil {
		return fmt.Errorf("native known-folder collector unavailable")
	}
	if err := user.revalidateToken(); err != nil {
		return err
	}
	profile, err := user.token.GetUserProfileDirectory()
	if err != nil || !strings.EqualFold(filepath.Clean(profile), user.profile) {
		return fmt.Errorf("original user profile changed")
	}
	identity := filepath.Base(user.profile)
	if identity == "." || identity == "" || identity == string(filepath.Separator) || !filepath.IsAbs(user.profile) {
		return fmt.Errorf("original user profile identity unavailable")
	}
	// The Linux bridge matches the Windows profile directory, not a localized
	// display name, elevated account name, or inherited USERNAME.
	result := &KnownFolders{User: identity, Folders: map[string]string{}}
	for name, id := range map[string]*windows.KNOWNFOLDERID{
		"Desktop": windows.FOLDERID_Desktop, "Documents": windows.FOLDERID_Documents,
		"Downloads": windows.FOLDERID_Downloads, "Music": windows.FOLDERID_Music,
		"Pictures": windows.FOLDERID_Pictures, "Videos": windows.FOLDERID_Videos,
	} {
		actual, err := user.token.KnownFolderPath(id, 0)
		if err != nil || !filepath.IsAbs(actual) || !strings.EqualFold(filepath.Clean(actual), user.folders[name]) {
			return fmt.Errorf("original user known folder changed")
		}
		result.Folders[name] = filepath.Clean(actual)
		if !strings.EqualFold(filepath.Clean(actual), filepath.Join(user.profile, name)) {
			result.Redirected = append(result.Redirected, name)
		}
	}
	sort.Strings(result.Redirected)
	if err := user.revalidateToken(); err != nil {
		return err
	}
	// Every failure is fatal for this native path. The legacy best-effort
	// registry collector remains separate and is never a fallback here.
	if err := sink(result); err != nil {
		return fmt.Errorf("native known-folder persistence refused")
	}
	return user.revalidateToken()
}
