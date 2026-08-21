package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ── Secondary Windows profiles (#16) ─────────────────────────────────────────
//
// A Windows PC can have several user profiles, but the installer collects
// exactly one identity and one password. The product decision is:
//
//   * ALL user data is migrated — nobody loses files because they were not the
//     one who happened to run the installer;
//   * only the signed-in user becomes the primary admin account;
//   * other users get an account so their data has somewhere to land, but we
//     do NOT invent passwords for them. Their accounts are created locked, and
//     the admin (or the user themselves) sets a password on first use.
//
// The account names are SANITIZED ("Alice Smith" → alice-smith), but the
// first-boot bridge (wootc-mount-user-dirs) walks the raw profile directories
// under /run/wootc/host/Users. Those two names only agree for profiles that
// were already legal lowercase Linux names, so the vault also carries a
// profile_map of directory name → account name — including the PRIMARY user's
// own profile, whose chosen username need not resemble their directory at all.
// The deployer persists that map into the installed system at
// /etc/wootc/profile-map.tsv, and the bridge consults it before falling back
// to an exact directory-name match.
//
// This file is deliberately NOT build-tagged. The logic is plain filesystem
// walking, and tagging it //go:build windows would mean the tests never ran in
// the normal test tier — for code whose failure mode is silently leaving a
// user's files behind.

// systemProfiles are the entries under C:\Users that are not people.
// defaultuser0 is the OOBE setup account: Windows is supposed to delete it
// after first boot but very often leaves the directory (with an NTUSER.DAT)
// behind on OEM machines — exactly the empty stranger on the login screen
// this list exists to prevent.
var systemProfiles = map[string]bool{
	"public": true, "default": true, "default user": true,
	"all users": true, "defaultaccount": true, "wdagutilityaccount": true,
	"administrator": true, "defaultuser0": true,
}

// profileMapping ties a Windows profile directory (the basename under
// C:\Users) to the Linux account name created for it.
type profileMapping struct {
	WindowsDir string
	LinuxUser  string
}

// listProfilesIn returns a mapping for every real Windows profile under
// usersDir, excluding the built-in system profiles and the primary user's own
// profile: `primary` is the chosen Linux username (already created as the
// admin account by fisherman) and `primaryDir` is the basename of their
// Windows profile directory. Both exclusions matter — the chosen username can
// be anything ("james"), while the directory keeps its Windows name
// ("James Reilly"), and a locked doppelganger account for the person who ran
// the installer would also break the bridge's single-user fallback (#73).
//
// Enumerating C:\Users rather than the registry ProfileList is deliberate: the
// bridge matches on the DIRECTORY name under Users\, so anything the registry
// reported that did not correspond to a directory would produce an account
// with no data to bind — an empty stranger on the login screen.
func listProfilesIn(usersDir, primary, primaryDir string) []profileMapping {
	entries, err := os.ReadDir(usersDir)
	if err != nil {
		return nil
	}

	seen := map[string]bool{}
	if primary != "" {
		seen[primary] = true
	}
	var out []profileMapping

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if systemProfiles[strings.ToLower(name)] {
			continue
		}
		if primaryDir != "" && strings.EqualFold(name, primaryDir) {
			continue
		}
		// A profile directory with no NTUSER.DAT was never a logged-in user
		// (leftovers, template dirs). Creating an account for one would put a
		// stranger on the login screen.
		if _, err := os.Stat(filepath.Join(usersDir, name, "NTUSER.DAT")); err != nil {
			continue
		}
		linux := sanitizeUsername(name)
		if linux == "" || seen[linux] {
			continue
		}
		seen[linux] = true
		out = append(out, profileMapping{WindowsDir: name, LinuxUser: linux})
	}

	// Deterministic vault.json across runs.
	sort.Slice(out, func(i, j int) bool { return out[i].LinuxUser < out[j].LinuxUser })
	return out
}
