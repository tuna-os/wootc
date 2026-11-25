//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"

	"github.com/tuna-os/wootc/slurp"
)

// Windows-profile resolution for the installed Linux session importer.
// wootc-passthrough.service bridges the Windows volume at /run/wootc/host.

// Windows volume at /run/wootc/host. The Windows knowledge (which profile
// folders bridge, which profile is the user's, where the look bundle
// lives) comes from wootc's own slurp module; fisherman has no Windows code.

const hostVolume = "/run/wootc/host"

var hostUsers = filepath.Join(hostVolume, slurp.UsersDir)

func currentUser() (*user.User, error) {
	return user.Current()
}

func resolvedWindowsProfile(u *user.User) (path, profile string, err error) {
	return resolvedWindowsProfileIn(u, hostUsers)
}

// Keep the production mount fixed while testing profile selection on real files.
// The choice saved in Migration settings wins, then the Linux user name; a
// volume with a single real profile resolves to it (slurp.ResolveProfile).
func resolvedWindowsProfileIn(u *user.User, root string) (path, profile string, err error) {
	mapPath := filepath.Join(u.HomeDir, ".config", "wootc", "profile-map.json")
	var mapping struct {
		WindowsProfile string `json:"windowsProfile"`
	}
	if data, readErr := os.ReadFile(mapPath); readErr != nil || unmarshalJSON(data, &mapping) != nil {
		mapping.WindowsProfile = ""
	}
	path, profile, err = slurp.ResolveProfile(root, mapping.WindowsProfile, u.Username)
	switch {
	case errors.Is(err, slurp.ErrProfileAmbiguous):
		return "", "", fmt.Errorf("could not map Linux user %q to one Windows profile; choose a profile in Migration settings", u.Username)
	case err != nil:
		return "", "", fmt.Errorf("Windows profiles are unavailable: %w", err)
	}
	return path, profile, nil
}
