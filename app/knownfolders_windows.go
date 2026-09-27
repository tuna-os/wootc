//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Known-folder resolution (#64).
//
// The User Data Bridge used to assume every profile folder sits at
// <profile>\Documents. Windows 11's OOBE actively pushes "OneDrive Backup",
// which REDIRECTS Desktop, Documents and Pictures to
// %USERPROFILE%\OneDrive\<folder>. On such a machine the literal path is empty
// or a stub, so the bridge would faithfully mount an empty directory and the
// user would boot Linux to find their documents gone — while every file sat
// safely on the disk a few directories away.
//
// The authoritative locations live in the registry, which only Windows can
// read. So Phase 1 resolves them here, while Windows is running, and writes a
// manifest the Linux-side bridge consumes. Resolving in the place that owns the
// truth, rather than re-deriving it later, is the same rule that #73 taught us
// about usernames.
//
// Cloud-only ("Files On-Demand") placeholders are counted but NOT hydrated:
// what to do about them is a product decision tracked in #65. Counting them is
// still worth doing on its own, because silently presenting a dehydrated file
// as migrated data is worse than reporting nothing — it invites the user to
// wipe Windows believing their files came across.

// knownFolderRegistryNames maps our folder names to the value names used under
// HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders.
var knownFolderRegistryNames = map[string]string{
	"Desktop":   "Desktop",
	"Documents": "Personal",
	"Downloads": "{374DE290-123F-4565-9164-39C4925E467B}",
	"Music":     "My Music",
	"Pictures":  "My Pictures",
	"Videos":    "My Video",
}

// resolveKnownFolders reads the current user's shell-folder registry values.
func resolveKnownFolders() (*KnownFolders, error) {
	kf := &KnownFolders{
		Folders:   map[string]string{},
		CloudOnly: map[string]int{},
	}
	user, err := runPowerShellOutput(`Write-Output $env:USERNAME`)
	if err != nil {
		return nil, fmt.Errorf("reading the current Windows user: %w", err)
	}
	kf.User = strings.TrimSpace(user)
	profile, err := runPowerShellOutput(`Write-Output $env:USERPROFILE`)
	if err != nil {
		return nil, fmt.Errorf("reading the user profile path: %w", err)
	}
	profileDir := strings.TrimSpace(profile)

	for folder, valueName := range knownFolderRegistryNames {
		// Read the RAW value and expand it ourselves: these are commonly
		// REG_EXPAND_SZ holding %USERPROFILE%\..., and an unexpanded string
		// would produce a path that exists nowhere.
		out, err := runPowerShellOutput(fmt.Sprintf(
			`$v = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name %q -ErrorAction SilentlyContinue).%q
if ($v) { Write-Output ([Environment]::ExpandEnvironmentVariables($v)) }`, valueName, valueName))
		resolved := strings.TrimSpace(out)
		if err != nil || resolved == "" {
			// No registry value: fall back to the literal default, which is
			// exactly the old behaviour. A missing value is normal.
			resolved = filepath.Join(profileDir, folder)
		}
		kf.Folders[folder] = resolved
		if !strings.EqualFold(resolved, filepath.Join(profileDir, folder)) {
			kf.Redirected = append(kf.Redirected, folder)
		}
		if n := countCloudOnly(resolved); n > 0 {
			kf.CloudOnly[folder] = n
		}
	}
	return kf, nil
}

// countCloudOnly counts dehydrated OneDrive placeholders under a directory.
// FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (0x00400000) marks a file whose content
// lives only in the cloud.
func countCloudOnly(dir string) int {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$d = %q
if (-not (Test-Path -LiteralPath $d)) { Write-Output 0; exit 0 }
$n = 0
Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Attributes.value__ -band 0x00400000) { $n++ }
}
Write-Output $n`, dir))
	if err != nil {
		return 0
	}
	var n int
	if _, err := fmt.Sscanf(strings.TrimSpace(out), "%d", &n); err != nil {
		return 0
	}
	return n
}

// writeKnownFolders persists the manifest where the Phase-2 bridge will find
// it: <wootcDir>\known-folders.json, which the deployed system sees under the
// mounted Windows volume.
func writeKnownFolders() error {
	kf, err := resolveKnownFolders()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(kf, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(wootcDir(), 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(wootcDir(), "known-folders.json"), data, 0o644)
}

// recordKnownFolders is the install-step entry point. Failure is never fatal:
// a machine with no redirection loses nothing, and the Phase-2 bridge falls
// back to the literal profile layout exactly as it did before #64.
func recordKnownFolders() {
	if err := writeKnownFolders(); err != nil {
		fmt.Fprintf(os.Stderr, "wootc: known-folder resolution failed (%v) — "+
			"the User Data Bridge will use the default profile layout\n", err)
	}
}
