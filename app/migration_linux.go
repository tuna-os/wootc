//go:build linux

package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// Linux side of the migration dashboard: the app runs inside the
// installed system where wootc-passthrough.service has bridged the
// Windows volume at /host.

var bridgeFolders = []string{"Documents", "Pictures", "Downloads", "Music", "Videos", "Desktop"}

func detectMode() string {
	if isMounted("/host") {
		return "migration"
	}
	return "installer" // `wails dev` on a workstation
}

func emitMigrationProgress(ctx context.Context, p MigrationProgress) {
	runtime.EventsEmit(ctx, "migrate:progress", p)
}

func isMounted(path string) bool {
	return exec.Command("mountpoint", "-q", path).Run() == nil
}

func currentUser() (*user.User, error) {
	return user.Current()
}

func migrationCategories() ([]BridgeCategory, error) {
	u, err := currentUser()
	if err != nil {
		return nil, err
	}
	winProfile := filepath.Join("/host/Users", u.Username)
	stateDir := filepath.Join(u.HomeDir, ".config", "wootc")

	var cats []BridgeCategory
	for _, f := range bridgeFolders {
		c := BridgeCategory{
			ID: f, Label: f, Reversible: true,
			Description: fmt.Sprintf("Your Windows %s, already visible in your home folder.", f),
			SizeBytes:   -1,
		}
		src := filepath.Join(winProfile, f)
		switch {
		case fileExists(filepath.Join(stateDir, "converted-"+f)):
			c.State = "native"
			c.Description = fmt.Sprintf("%s now lives on Linux. The Windows copy is untouched.", f)
		case isMounted(filepath.Join(u.HomeDir, f)):
			c.State = "bridged"
			c.SizeBytes = dirSize(src)
		case dirExists(src):
			c.State = "available"
			c.SizeBytes = dirSize(src)
		default:
			c.State = "unavailable"
			c.Description = fmt.Sprintf("No %s folder was found in your Windows account.", f)
		}
		cats = append(cats, c)
	}

	// Steam: read what wootc-steam-bridge recorded.
	steam := BridgeCategory{
		ID: "steam", Label: "Steam games", Reversible: true, SizeBytes: -1,
		Description: "Your Windows Steam library, playable in place — no re-download.",
	}
	if data, err := os.ReadFile(filepath.Join(stateDir, "bridge-steam.json")); err == nil {
		steam.State = "bridged"
		var parsed struct {
			Libraries []struct {
				Path string `json:"path"`
			} `json:"libraries"`
		}
		if unmarshalJSON(data, &parsed) == nil && len(parsed.Libraries) > 0 {
			var total int64
			for _, l := range parsed.Libraries {
				total += dirSize(l.Path)
			}
			steam.SizeBytes = total
		}
	} else {
		steam.State = "unavailable"
		steam.Description = "No Windows Steam library was found."
	}
	cats = append(cats, steam)

	// Browser: importable on demand.
	browser := BridgeCategory{
		ID: "browser", Label: "Browser data", Reversible: true, SizeBytes: -1,
		Description: "Bookmarks and history from Chrome/Edge, and your complete Firefox profile. " +
			"Chrome and Edge passwords are locked by Windows and cannot move automatically.",
	}
	if fileExists(filepath.Join(stateDir, "bridge-browser.json")) {
		browser.State = "native"
		browser.Description = "Browser data has been imported."
	} else if dirExists(filepath.Join(winProfile, "AppData")) {
		browser.State = "available"
	} else {
		browser.State = "unavailable"
		browser.Description = "No Windows browser data was found."
	}
	cats = append(cats, browser)

	return cats, nil
}

func convertCategory(id string, progress func(MigrationProgress)) error {
	u, err := currentUser()
	if err != nil {
		return err
	}
	valid := false
	for _, f := range bridgeFolders {
		if f == id {
			valid = true
			break
		}
	}
	if !valid {
		return fmt.Errorf("category %q cannot be converted this way", id)
	}

	// pkexec prompts the desktop user for authorization; the helper emits
	// "PROGRESS <n>" lines we forward to the UI.
	cmd := exec.Command("pkexec", "/usr/local/bin/wootc-convert-dir", u.Username, id)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start conversion: %w", err)
	}
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		if pctStr, ok := strings.CutPrefix(line, "PROGRESS "); ok {
			if pct, err := strconv.ParseFloat(pctStr, 64); err == nil {
				progress(MigrationProgress{Category: id, Percent: pct})
			}
		}
	}
	if err := cmd.Wait(); err != nil {
		progress(MigrationProgress{Category: id, Error: err.Error()})
		return fmt.Errorf("conversion failed: %w", err)
	}
	progress(MigrationProgress{Category: id, Percent: 100, Done: true})
	return nil
}

func appMigrations() ([]AppMigration, error) {
	u, err := currentUser()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(u.HomeDir, ".config", "wootc", "bridge-apps.json"))
	if err != nil {
		return nil, nil // none detected yet
	}
	var parsed struct {
		Apps []AppMigration `json:"apps"`
	}
	if err := unmarshalJSON(data, &parsed); err != nil {
		return nil, err
	}
	return parsed.Apps, nil
}

func officeMigration() (OfficeMigration, error) {
	u, err := currentUser()
	if err != nil {
		return OfficeMigration{}, err
	}
	data, err := os.ReadFile(filepath.Join(u.HomeDir, ".config", "wootc", "bridge-office.json"))
	if err != nil {
		return OfficeMigration{Present: false}, nil
	}
	var o OfficeMigration
	if err := unmarshalJSON(data, &o); err != nil {
		return OfficeMigration{}, err
	}
	o.Present = true
	return o, nil
}

func importBrowserData() (string, error) {
	u, err := currentUser()
	if err != nil {
		return "", err
	}
	out, err := exec.Command("/usr/local/bin/wootc-import-browser", u.Username).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("browser import: %w", err)
	}
	return string(out), nil
}

// ── small fs helpers ─────────────────────────────────────────────────────────

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }
func dirExists(p string) bool  { st, err := os.Stat(p); return err == nil && st.IsDir() }

// dirSize returns the recursive size in bytes, or -1 when unknown. du on
// ntfs3 is I/O-bound; a hard 10s timeout keeps the dashboard responsive
// (the UI shows "calculating…" for -1).
func dirSize(path string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 10*1e9)
	defer cancel()
	out, err := exec.CommandContext(ctx, "du", "-sb", path).Output()
	if err != nil {
		return -1
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return -1
	}
	n, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return -1
	}
	return n
}
