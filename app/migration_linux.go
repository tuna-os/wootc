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
// Windows volume at /run/wootc/host.

var bridgeFolders = []string{"Documents", "Pictures", "Downloads", "Music", "Videos", "Desktop"}

var tokenConsentApps = map[string]bool{
	"chrome": true, "edge": true, "spotify": true,
}

func detectMode() string {
	if isMounted("/run/wootc/host") {
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
	winProfile, _, err := resolvedWindowsProfile(u)
	if err != nil {
		return nil, err
	}
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

	// Pre-flight: refuse to convert a category that has already been
	// migrated to native storage, or one whose source is not present.
	// This catches the name-mismatch #73 case where the constructed
	// path doesn't exist but the bind mount does (wootc-convert-dir
	// handles that fallback internally; this is the fast fail).
	stateDir := filepath.Join(u.HomeDir, ".config", "wootc")
	if fileExists(filepath.Join(stateDir, "converted-"+id)) {
		return fmt.Errorf("%s has already been converted to native storage", id)
	}
	src := filepath.Join("/run/wootc/host/Users", u.Username, id)
	dst := filepath.Join(u.HomeDir, id)
	if !dirExists(src) && !isMounted(dst) {
		return fmt.Errorf("%s source not found — nothing to convert", id)
	}

	// pkexec prompts the desktop user for authorization; the helper emits
	// "PROGRESS <n>" lines we forward to the UI.
	cmd := exec.Command("pkexec", "/var/usrlocal/bin/wootc-convert-dir", u.Username, id)
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
	consents := readSessionConsents(filepath.Join(u.HomeDir, ".config", "wootc", "session-consent.json"))
	exports := readSessionExports()
	for i := range parsed.Apps {
		appKey := parsed.Apps[i].App
		if exp, ok := exports[appKey]; ok {
			switch exp.State {
			case "staged":
				parsed.Apps[i].Session = "staged"
				parsed.Apps[i].Copied = true
				parsed.Apps[i].Note = "Session key staged — you'll sign in once on Linux until target import is verified."
			case "imported":
				parsed.Apps[i].Session = "portable"
				parsed.Apps[i].Copied = true
				parsed.Apps[i].Note = "Session imported — opens signed in."
			}
		}
		parsed.Apps[i].ConsentAvailable = tokenConsentApps[appKey] && (parsed.Apps[i].Session == "signin" || parsed.Apps[i].Session == "staged")
		parsed.Apps[i].Consent = parsed.Apps[i].ConsentAvailable && (consents[appKey] || exports[appKey].State == "staged")
	}
	return parsed.Apps, nil
}

func setSessionConsent(app string, consent bool) error {
	u, err := currentUser()
	if err != nil {
		return err
	}
	apps, err := appMigrations()
	if err != nil {
		return err
	}
	allowed := false
	for _, item := range apps {
		if item.App == app && item.ConsentAvailable {
			allowed = true
			break
		}
	}
	if !allowed {
		return fmt.Errorf("session consent is not available for %q", app)
	}
	path := filepath.Join(u.HomeDir, ".config", "wootc", "session-consent.json")
	consents := readSessionConsents(path)
	if consent {
		consents[app] = true
	} else {
		delete(consents, app)
	}
	return marshalJSONToFile(path, consents)
}

func readSessionConsents(path string) map[string]bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]bool{}
	}
	var consents map[string]bool
	if unmarshalJSON(data, &consents) != nil || consents == nil {
		return map[string]bool{}
	}
	return consents
}

func readSessionExports() map[string]SessionExport {
	candidates := []string{
		"/run/wootc/host/wootc/install/slurp/session/exports.json",
		filepath.Join(wootcDir(), "install", "slurp", "session", "exports.json"),
	}
	for _, p := range candidates {
		exports := readSessionExportsFrom(p)
		if len(exports) > 0 {
			return exports
		}
	}
	return map[string]SessionExport{}
}

func readSessionExportsFrom(path string) map[string]SessionExport {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]SessionExport{}
	}
	var exports []SessionExport
	if unmarshalJSON(data, &exports) != nil || len(exports) == 0 {
		return map[string]SessionExport{}
	}
	res := make(map[string]SessionExport, len(exports))
	for _, exp := range exports {
		res[exp.App] = exp
	}
	return res
}

func reinstallApps() error {
	u, err := currentUser()
	if err != nil {
		return err
	}
	apps, err := appMigrations()
	if err != nil {
		return err
	}
	ids := make([]string, 0, len(apps))
	seen := map[string]bool{}
	for _, app := range apps {
		if app.Flatpak == "" || seen[app.Flatpak] || !validFlatpakID(app.Flatpak) {
			continue
		}
		seen[app.Flatpak] = true
		ids = append(ids, app.Flatpak)
	}
	if len(ids) == 0 {
		return fmt.Errorf("no reinstallable Flatpak apps were detected")
	}
	args := append([]string{"install", "--user", "-y", "flathub"}, ids...)
	cmd := exec.Command("flatpak", args...)
	cmd.Dir = u.HomeDir
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("flatpak install: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func validFlatpakID(id string) bool {
	if id == "" {
		return false
	}
	if strings.Contains(id, "..") || id[0] == '.' || id[len(id)-1] == '.' {
		return false
	}
	for _, r := range id {
		if (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '.' && r != '-' && r != '_' {
			return false
		}
	}
	return strings.Contains(id, ".")
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
	_, winProfile, err := resolvedWindowsProfile(u)
	if err != nil {
		return "", err
	}
	out, err := exec.Command("/var/usrlocal/bin/wootc-import-browser", winProfile, u.Username).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("browser import: %w", err)
	}
	return string(out), nil
}

func migrationProfile() (MigrationProfile, error) {
	u, err := currentUser()
	if err != nil {
		return MigrationProfile{}, err
	}
	_, profile, resolveErr := resolvedWindowsProfile(u)
	if resolveErr != nil {
		return MigrationProfile{LinuxUser: u.Username, Note: resolveErr.Error()}, nil
	}
	matched := strings.EqualFold(profile, u.Username)
	note := "Windows profile is mapped automatically."
	if !matched {
		note = "Linux and Windows names differ; this profile is being used for the bridges."
	}
	return MigrationProfile{LinuxUser: u.Username, WindowsProfile: profile, Matched: matched, Note: note}, nil
}

func setMigrationProfile(profile string) error {
	u, err := currentUser()
	if err != nil {
		return err
	}
	root := "/run/wootc/host/Users"
	entries, err := os.ReadDir(root)
	if err != nil {
		return fmt.Errorf("list Windows profiles: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() && strings.EqualFold(entry.Name(), profile) {
			path := filepath.Join(u.HomeDir, ".config", "wootc", "profile-map.json")
			if err := marshalJSONToFile(path, map[string]string{"windowsProfile": entry.Name()}); err != nil {
				return err
			}
			// Re-run the read-only app/Office collectors immediately so the
			// dashboard reflects the newly selected profile without waiting for
			// the next bridge-service restart.
			if _, lookErr := exec.LookPath("wootc-detect-apps"); lookErr == nil {
				if output, runErr := exec.Command("wootc-detect-apps", entry.Name(), u.Username).CombinedOutput(); runErr != nil {
					return fmt.Errorf("refresh app bridge: %w: %s", runErr, strings.TrimSpace(string(output)))
				}
			}
			if _, lookErr := exec.LookPath("wootc-office-bridge"); lookErr == nil {
				if output, runErr := exec.Command("wootc-office-bridge", entry.Name(), u.Username).CombinedOutput(); runErr != nil {
					return fmt.Errorf("refresh Office bridge: %w: %s", runErr, strings.TrimSpace(string(output)))
				}
			}
			return nil
		}
	}
	return fmt.Errorf("Windows profile %q was not found", profile)
}

func resolvedWindowsProfile(u *user.User) (path, profile string, err error) {
	return resolvedWindowsProfileIn(u, "/run/wootc/host/Users")
}

// Keep the production mount fixed while testing profile selection on real files.
func resolvedWindowsProfileIn(u *user.User, root string) (path, profile string, err error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", "", fmt.Errorf("Windows profiles are unavailable: %w", err)
	}
	var profiles []string
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != "Public" && entry.Name() != "Default" && entry.Name() != "Default User" && entry.Name() != "All Users" {
			profiles = append(profiles, entry.Name())
		}
	}
	mapPath := filepath.Join(u.HomeDir, ".config", "wootc", "profile-map.json")
	var mapping struct {
		WindowsProfile string `json:"windowsProfile"`
	}
	if data, readErr := os.ReadFile(mapPath); readErr == nil && unmarshalJSON(data, &mapping) == nil {
		for _, candidate := range profiles {
			if strings.EqualFold(candidate, mapping.WindowsProfile) {
				return filepath.Join(root, candidate), candidate, nil
			}
		}
	}
	for _, candidate := range profiles {
		if strings.EqualFold(candidate, u.Username) {
			return filepath.Join(root, candidate), candidate, nil
		}
	}
	if len(profiles) == 1 {
		return filepath.Join(root, profiles[0]), profiles[0], nil
	}
	return "", "", fmt.Errorf("could not map Linux user %q to one Windows profile; choose a profile in Migration settings", u.Username)
}

func lookMigration() (LookMigration, error) {
	u, err := currentUser()
	if err != nil {
		return LookMigration{}, err
	}
	path, _, resolveErr := resolvedWindowsProfile(u)
	if resolveErr != nil {
		return LookMigration{Note: resolveErr.Error()}, nil
	}
	slurp := filepath.Join(path, "..", "..", "wootc", "install", "slurp", "slurp.json")
	data, err := os.ReadFile(slurp)
	if err != nil {
		return LookMigration{Note: "Windows look was not selected during install."}, nil
	}
	var raw map[string]any
	if err := unmarshalJSON(data, &raw); err != nil {
		return LookMigration{}, err
	}
	items := make([]string, 0, len(raw))
	for key := range raw {
		items = append(items, key)
	}
	return LookMigration{Available: true, Applied: fileExists(filepath.Join(u.HomeDir, ".config", "wootc", "look-applied")), Items: items, Note: "Windows look settings are applied once per Linux user and can be skipped from the migration chooser."}, nil
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
