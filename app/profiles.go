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
// Creating the accounts is the whole job. wootc-mount-user-dirs already walks
// every profile under /run/wootc/host/Users and bind-mounts each one into the
// Linux account of the same name, skipping profiles with no matching account.
// So the bridge needs no change: give the profiles accounts and their data
// follows.
//
// This file is deliberately NOT build-tagged. The logic is plain filesystem
// walking, and tagging it //go:build windows would mean the tests never ran in
// the normal test tier — for code whose failure mode is silently leaving a
// user's files behind.

// systemProfiles are the entries under C:\Users that are not people.
var systemProfiles = map[string]bool{
	"public": true, "default": true, "default user": true,
	"all users": true, "defaultaccount": true, "wdagutilityaccount": true,
	"administrator": true,
}

// listProfilesIn returns the sanitised Linux usernames for every real
// Windows profile under usersDir, excluding `primary` (already created as the
// admin account) and the built-in system profiles.
//
// Enumerating C:\Users rather than the registry ProfileList is deliberate: the
// bridge matches on the DIRECTORY name under Users\, so anything the registry
// reported that did not correspond to a directory would produce an account
// with no data to bind — an empty stranger on the login screen.
func listProfilesIn(usersDir, primary string) []string {
	entries, err := os.ReadDir(usersDir)
	if err != nil {
		return nil
	}

	seen := map[string]bool{}
	if primary != "" {
		seen[primary] = true
	}
	var out []string

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if systemProfiles[strings.ToLower(name)] {
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
		out = append(out, linux)
	}

	sort.Strings(out) // deterministic vault.json across runs
	return out
}
