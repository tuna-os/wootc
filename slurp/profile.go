package slurp

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// UsersDir is the directory, relative to a Windows volume root, that holds
// the user profiles.
const UsersDir = "Users"

// systemProfiles are the entries under Users that are not a person.
var systemProfiles = map[string]bool{
	"Public": true, "Default": true, "Default User": true, "All Users": true,
}

// IsSystemProfile reports whether name is a built-in Windows profile
// (Public, Default, Default User, All Users) or a hidden entry, neither of
// which belongs to a person.
func IsSystemProfile(name string) bool {
	return systemProfiles[name] || strings.HasPrefix(name, ".")
}

// Profiles lists the user profiles in usersDir (a volume's Users
// directory), in directory order. Only real directories count: files
// (desktop.ini) and symlinks or junctions are never a profile, so nothing
// outside usersDir can be selected through one. The error is the one
// os.ReadDir returned.
func Profiles(usersDir string) ([]string, error) {
	entries, err := os.ReadDir(usersDir)
	if err != nil {
		return nil, err
	}
	var profiles []string
	for _, entry := range entries {
		if entry.IsDir() && !IsSystemProfile(entry.Name()) {
			profiles = append(profiles, entry.Name())
		}
	}
	return profiles, nil
}

// ErrProfileAmbiguous is returned by ResolveProfile when no preferred name
// matches and the volume does not hold exactly one profile.
var ErrProfileAmbiguous = errors.New("no single Windows profile matches")

// ResolveProfile picks one profile in usersDir. Each preferred name is tried
// in turn against Profiles, case-insensitively (an explicit choice first,
// then, say, the Linux user name); empty names are skipped. Failing those, a
// volume with exactly one profile resolves to it. It returns the profile's
// path and its on-disk name, or ErrProfileAmbiguous, or the error listing
// usersDir failed with.
func ResolveProfile(usersDir string, preferred ...string) (path, profile string, err error) {
	profiles, err := Profiles(usersDir)
	if err != nil {
		return "", "", err
	}
	for _, want := range preferred {
		if want == "" {
			continue
		}
		for _, candidate := range profiles {
			if strings.EqualFold(candidate, want) {
				return filepath.Join(usersDir, candidate), candidate, nil
			}
		}
	}
	if len(profiles) == 1 {
		return filepath.Join(usersDir, profiles[0]), profiles[0], nil
	}
	return "", "", ErrProfileAmbiguous
}
