package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// app-flatpaks.json is the one table that maps a Windows program to its
// Flathub counterpart (SPEC §4.3). The engine embeds it to offer those apps
// on the install form; the deployer and payload/migration/wootc-detect-apps
// read the same file. `match` entries are lowercase substrings of an
// Uninstall-key DisplayName; the first app whose substring matches wins.
//
//go:embed data/app-flatpaks.json
var appFlatpaksJSON []byte

// appsHandoffRemote is the Flatpak remote the deployer installs from.
const (
	appsHandoffRemote    = "flathub"
	appsHandoffRemoteURL = "https://dl.flathub.org/repo/flathub.flatpakrepo"
	// maxFlatpakSelection bounds a plan's app list. The map holds far fewer
	// apps; the bound only stops an oversized plan before any lookup.
	maxFlatpakSelection = 64
)

type appFlatpakMap struct {
	SchemaVersion int             `json:"schemaVersion"`
	Apps          []appFlatpakApp `json:"apps"`
}

type appFlatpakApp struct {
	Key     string   `json:"key"`
	Name    string   `json:"name"`
	Flatpak string   `json:"flatpak"`
	Match   []string `json:"match"`
	// Session and Note are the dashboard's portability text; the Windows
	// engine does not use them.
	Session string `json:"session,omitempty"`
	Note    string `json:"note,omitempty"`
}

// DetectedApp is one Windows program the engine found in the Uninstall
// registry keys that has a Flatpak in app-flatpaks.json. Name is the Linux
// app that gets installed; DisplayName is the Windows program it replaces.
type DetectedApp struct {
	Flatpak     string `json:"flatpak"`
	Name        string `json:"name"`
	DisplayName string `json:"displayName"`
}

// AppsHandoff is <storage root>\wootc\install\apps.json: the Flatpaks the
// person kept checked, for the deployer to install into the target.
type AppsHandoff struct {
	SchemaVersion int      `json:"schemaVersion"`
	Remote        string   `json:"remote"`
	RemoteURL     string   `json:"remoteUrl"`
	Flatpaks      []string `json:"flatpaks"`
}

var flatpakIDPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$`)

// parseAppFlatpaks refuses a table the detection could misread: unknown or
// duplicate keys, a Flatpak ID that is not one, or a match string that can
// never match a lowercased DisplayName.
func parseAppFlatpaks(data []byte) (appFlatpakMap, error) {
	var table appFlatpakMap
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&table); err != nil {
		return appFlatpakMap{}, fmt.Errorf("app-flatpaks.json: %w", err)
	}
	if table.SchemaVersion != 1 || len(table.Apps) == 0 {
		return appFlatpakMap{}, fmt.Errorf("app-flatpaks.json: unsupported schema or empty table")
	}
	keys := map[string]bool{}
	for _, app := range table.Apps {
		if app.Key == "" || keys[app.Key] || app.Name == "" || !flatpakIDPattern.MatchString(app.Flatpak) || len(app.Match) == 0 {
			return appFlatpakMap{}, fmt.Errorf("app-flatpaks.json: invalid entry %q", app.Key)
		}
		keys[app.Key] = true
		for _, match := range app.Match {
			if strings.TrimSpace(match) == "" || match != strings.ToLower(match) {
				return appFlatpakMap{}, fmt.Errorf("app-flatpaks.json: invalid match %q for %q", match, app.Key)
			}
		}
	}
	return table, nil
}

// embeddedAppFlatpaks is the parsed embedded table. A broken table is a
// build defect; detection then reports no apps and plans name none.
var embeddedAppFlatpaks = sync.OnceValues(func() (appFlatpakMap, error) { return parseAppFlatpaks(appFlatpaksJSON) })

// detectAppsFromDisplayNames maps Uninstall-key DisplayNames to Flatpaks,
// once per Flatpak, in the order the names were read.
func detectAppsFromDisplayNames(table appFlatpakMap, displayNames []string) []DetectedApp {
	detected := []DetectedApp{}
	seen := map[string]bool{}
	for _, displayName := range displayNames {
		displayName = strings.TrimSpace(displayName)
		lower := strings.ToLower(displayName)
		if lower == "" {
			continue
		}
		for _, app := range table.Apps {
			if !matchesAny(lower, app.Match) {
				continue
			}
			if !seen[app.Flatpak] {
				seen[app.Flatpak] = true
				detected = append(detected, DetectedApp{Flatpak: app.Flatpak, Name: app.Name, DisplayName: displayName})
			}
			break
		}
	}
	return detected
}

func matchesAny(lower string, matches []string) bool {
	for _, match := range matches {
		if strings.Contains(lower, match) {
			return true
		}
	}
	return false
}

// detectInstalledApps reads this computer's Uninstall keys and maps them.
func detectInstalledApps() []DetectedApp {
	table, err := embeddedAppFlatpaks()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] app detection skipped: %v\n", err)
		return []DetectedApp{}
	}
	return detectAppsFromDisplayNames(table, uninstallDisplayNames())
}

// GetDetectedApps is detectInstalledApps for the Wails launchpad's Apps box.
func (a *App) GetDetectedApps() []DetectedApp {
	return detectInstalledApps()
}

// validateFlatpakSelectionShape refuses a list no detection could produce:
// too long, a value that is not a Flatpak ID, or an ID named twice.
func validateFlatpakSelectionShape(selected []string) error {
	if len(selected) > maxFlatpakSelection {
		return fmt.Errorf("the app list names %d apps; at most %d are allowed", len(selected), maxFlatpakSelection)
	}
	seen := map[string]bool{}
	for _, id := range selected {
		if !flatpakIDPattern.MatchString(id) {
			return fmt.Errorf("the app list names something that is not a Flatpak ID")
		}
		if seen[id] {
			return fmt.Errorf("the app list names %s more than once", id)
		}
		seen[id] = true
	}
	return nil
}

// validateFlatpakSelection accepts only Flatpaks the engine detected on this
// computer, each once. An empty selection is valid: the person unchecked
// every app, or none was detected.
func validateFlatpakSelection(selected []string, detected []DetectedApp) error {
	if err := validateFlatpakSelectionShape(selected); err != nil {
		return err
	}
	offered := map[string]bool{}
	for _, app := range detected {
		offered[app.Flatpak] = true
	}
	for _, id := range selected {
		if !offered[id] {
			return fmt.Errorf("the app %s was not detected on this computer, so it cannot be installed", id)
		}
	}
	return nil
}

// writeAppsHandoff writes <root>\install\apps.json. It is written on every
// install, with an empty list when the person kept no app, so the deployer
// can tell "none chosen" from "an installer that predates this file".
func writeAppsHandoff(root string, flatpaks []string) error {
	handoff := AppsHandoff{SchemaVersion: 1, Remote: appsHandoffRemote, RemoteURL: appsHandoffRemoteURL, Flatpaks: append([]string{}, flatpaks...)}
	dir := filepath.Join(root, "install")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	return marshalJSONToFile(filepath.Join(dir, "apps.json"), handoff)
}
