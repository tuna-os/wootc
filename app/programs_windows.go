//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// RegistryProgram is one installed program discovered via the Windows
// uninstall registry keys (HKLM/HKCU). The fields match what
// wootc-detect-apps expects for unioning.
type RegistryProgram struct {
	DisplayName     string `json:"displayName"`
	Publisher       string `json:"publisher,omitempty"`
	InstallLocation string `json:"installLocation,omitempty"`
	DisplayVersion  string `json:"displayVersion,omitempty"`
	UninstallString string `json:"uninstallString,omitempty"`
	Source          string `json:"source"` // HKLM | HKLM-32 | HKCU
}

// ProgramsManifest is the JSON written to C:\wootc\install\programs.json.
type ProgramsManifest struct {
	Apps []RegistryProgram `json:"apps"`
	// DefaultAssocs records the user's default browser and mail client
	// (ProgId values from HKCU\...\UrlAssociations).
	DefaultBrowser string `json:"defaultBrowser,omitempty"`
	DefaultMail    string `json:"defaultMail,omitempty"`
	// StartupPrograms lists the command-lines from the Run registry keys.
	StartupPrograms []string `json:"startupPrograms,omitempty"`
}

// collectPrograms enumerates installed software from the Windows registry
// and writes the manifest to C:\wootc\install\programs.json. The Linux-side
// wootc-detect-apps reads it and unions it with the AppData folder scan so
// the dashboard shows the complete installed-program inventory, not just
// apps with a filesystem footprint.
func collectPrograms() error {
	manifest := ProgramsManifest{}

	// ── Enumerate uninstall keys ───────────────────────────────────────────
	manifest.Apps = enumerateUninstallKeys()

	// ── Default associations ───────────────────────────────────────────────
	browser, mail := defaultAssociations()
	manifest.DefaultBrowser = browser
	manifest.DefaultMail = mail

	// ── Startup programs ───────────────────────────────────────────────────
	manifest.StartupPrograms = startupPrograms()

	// Deduplicate by install path: same binary installed once may appear
	// under both HKLM and HKCU. Keep the first entry.
	manifest.Apps = dedupeByLocation(manifest.Apps)

	installDir := filepath.Join(wootcDir(), "install")
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", installDir, err)
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal programs.json: %w", err)
	}
	return os.WriteFile(filepath.Join(installDir, "programs.json"), data, 0o644)
}

// uninstallHives are the three standard uninstall locations. The engine runs
// elevated as the interactive user, so HKCU is that person's hive.
var uninstallHives = []struct {
	root   registry.Key
	path   string
	source string
}{
	{registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, "HKLM"},
	{registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`, "HKLM-32"},
	{registry.CURRENT_USER, `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, "HKCU"},
}

// enumerateUninstallKeys reads the three standard uninstall locations through
// the registry API. It runs inside the native configuration read's budget
// (app detection), where one PowerShell start per key would not fit.
func enumerateUninstallKeys() []RegistryProgram {
	var apps []RegistryProgram
	for _, hive := range uninstallHives {
		parent, err := registry.OpenKey(hive.root, hive.path, registry.ENUMERATE_SUB_KEYS)
		if err != nil {
			continue
		}
		// On error ReadSubKeyNames still returns the names it read.
		names, _ := parent.ReadSubKeyNames(-1)
		parent.Close()
		for _, name := range names {
			// Skip system components and patches (identified by GUID-only names
			// with no display name, or "Hotfix", "KB*", "Service Pack", etc.).
			props := readUninstallEntry(hive.root, hive.path+`\`+name)
			displayName, ok := props["DisplayName"]
			if !ok || displayName == "" {
				continue
			}

			// Filter out Microsoft Visual C++ redistributables, Windows
			// Desktop Runtime, and other mostly-meaningless entries.
			if isRedist(displayName, props) {
				continue
			}

			apps = append(apps, RegistryProgram{
				DisplayName:     displayName,
				Publisher:       props["Publisher"],
				InstallLocation: props["InstallLocation"],
				DisplayVersion:  props["DisplayVersion"],
				UninstallString: props["UninstallString"],
				Source:          hive.source,
			})
		}
	}
	return apps
}

// readUninstallEntry reads the string values programs.json records from one
// uninstall key. REG_EXPAND_SZ values are expanded, as Get-ItemProperty did.
func readUninstallEntry(root registry.Key, path string) map[string]string {
	key, err := registry.OpenKey(root, path, registry.QUERY_VALUE)
	if err != nil {
		return nil
	}
	defer key.Close()
	props := map[string]string{}
	for _, name := range []string{"DisplayName", "Publisher", "InstallLocation", "DisplayVersion", "UninstallString"} {
		value, valueType, err := key.GetStringValue(name)
		if err != nil {
			continue
		}
		if valueType == registry.EXPAND_SZ {
			if expanded, err := registry.ExpandString(value); err == nil {
				value = expanded
			}
		}
		props[name] = strings.TrimSpace(value)
	}
	return props
}

// uninstallDisplayNames is the DisplayName of every program
// enumerateUninstallKeys reports, for app detection (app_flatpaks.go).
func uninstallDisplayNames() []string {
	programs := enumerateUninstallKeys()
	names := make([]string, 0, len(programs))
	for _, program := range programs {
		names = append(names, program.DisplayName)
	}
	return names
}

// defaultAssociations reads the user's default browser and mail client
// from HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations.
func defaultAssociations() (browser, mail string) {
	baseKey := `HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations`

	// Browser: http(s) ProgId
	for _, scheme := range []string{"http", "https"} {
		v, _ := readRegistryValue(baseKey + `\` + scheme + `\UserChoice`, "ProgId")
		if v != "" {
			browser = v
			break
		}
	}

	// Mail: mailto ProgId
	mail, _ = readRegistryValue(baseKey+`\mailto\UserChoice`, "ProgId")
	return browser, mail
}

// startupPrograms reads login-start programs from the Run registry keys.
func startupPrograms() []string {
	var progs []string

	keys := []string{
		`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`,
		`HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`,
	}

	for _, key := range keys {
		props := readRegistryProperties(key)
		for name, value := range props {
			if value == "" || noStartupName(name) {
				continue
			}
			progs = append(progs, value)
		}
	}
	return progs
}

// ── Registry helpers ─────────────────────────────────────────────────────

// enumerateSubkeyNames returns the subkey names under a PowerShell registry path.
func enumerateSubkeyNames(regPath string) []string {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$ErrorActionPreference = 'SilentlyContinue'
Get-ChildItem -Path %q -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName }`, regPath))
	if err != nil {
		return nil
	}
	names := strings.Split(strings.TrimSpace(out), "\n")
	if len(names) == 1 && names[0] == "" {
		return nil
	}
	result := make([]string, 0, len(names))
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n != "" {
			result = append(result, n)
		}
	}
	return result
}

// readRegistryProperties returns all value names → data under a reg path.
func readRegistryProperties(regPath string) map[string]string {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$ErrorActionPreference = 'SilentlyContinue'
$p = Get-ItemProperty -Path %q -ErrorAction SilentlyContinue
if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' } | ForEach-Object { '{0}|||{1}' -f $_.Name, $_.Value } }`, regPath))
	if err != nil {
		return nil
	}
	result := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if idx := strings.Index(line, "|||"); idx >= 0 {
			result[line[:idx]] = line[idx+3:]
		}
	}
	return result
}

// readRegistryValue reads a single named value from a registry key path.
func readRegistryValue(regPath, valueName string) (string, error) {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$v = (Get-ItemProperty -Path %q -Name %q -ErrorAction SilentlyContinue).%q
if ($v) { Write-Output $v }`, regPath, valueName, valueName))
	return strings.TrimSpace(out), err
}

// ── Filters ──────────────────────────────────────────────────────────────

// isRedist filters out framework and redistributable entries that are not
// user-facing applications. These are installation artifacts, not something
// the user thinks of as "an app I have".
func isRedist(displayName string, props map[string]string) bool {
	dn := strings.ToLower(displayName)
	pub := strings.ToLower(props["Publisher"])

	// Microsoft redistributables.
	if strings.Contains(dn, "microsoft visual c++") &&
		strings.Contains(dn, "redistributable") {
		return true
	}
	// .NET runtimes/SDKs.
	if strings.Contains(dn, "microsoft .net") &&
		(strings.Contains(dn, "runtime") || strings.Contains(dn, "sdk") ||
			strings.Contains(dn, "desktop runtime") || strings.Contains(dn, "hosting bundle") ||
			strings.Contains(dn, "targeting pack")) {
		return true
	}
	// Windows Desktop Runtime (standalone).
	if strings.Contains(dn, "windows desktop runtime") {
		return true
	}
	// ASP.NET Core Runtime.
	if strings.Contains(dn, "asp.net core") && (strings.Contains(dn, "runtime") || strings.Contains(dn, "shared framework")) {
		return true
	}
	// Update/patches. "Update for Microsoft ..." or "Security Update for ..."
	if strings.Contains(dn, "update for microsoft") ||
		strings.Contains(dn, "security update") ||
		strings.Contains(dn, "hotfix for") ||
		strings.Contains(dn, "service pack") {
		return true
	}
	// Drivers (NVIDIA, Intel, AMD display/audio drivers etc.).
	if (strings.Contains(pub, "nvidia") || strings.Contains(dn, "nvidia")) &&
		(strings.Contains(dn, "driver") || strings.Contains(dn, "graphics") || strings.Contains(dn, "display")) {
		return true
	}
	if strings.Contains(pub, "intel") && strings.Contains(dn, "driver") {
		return true
	}
	if strings.Contains(pub, "realtek") || strings.Contains(dn, "realtek") {
		return true
	}
	return false
}

// noStartupName filters out noise from the Run keys: entries named
// "SecurityHealth" and similar Windows system tray helpers.
func noStartupName(name string) bool {
	n := strings.ToLower(name)
	return strings.Contains(n, "securityhealth") ||
		strings.Contains(n, "windows defender") ||
		strings.Contains(n, "onedrive")
}

// dedupeByLocation removes entries that share the same InstallLocation,
// keeping the first entry found (HKLM first, then WOW6432, then HKCU).
func dedupeByLocation(apps []RegistryProgram) []RegistryProgram {
	if len(apps) == 0 {
		return apps
	}
	seen := map[string]bool{}
	result := apps[:0]
	for _, a := range apps {
		key := strings.ToLower(strings.TrimSpace(a.InstallLocation))
		// Entries with no install location are never deduplicated —
		// they have no canonical path to compare.
		if key != "" && seen[key] {
			continue
		}
		if key != "" {
			seen[key] = true
		}
		result = append(result, a)
	}
	return result
}
