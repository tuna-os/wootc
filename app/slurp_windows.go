//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// collectLook gathers the user's Windows look (wallpaper, dark mode,
// accent color, timezone) into C:\wootc\install\slurp\ for the target
// system's wootc-apply-look (SPEC §4.4, Windows-Style Mode). Best-effort:
// a machine with a slideshow wallpaper or odd registry state must never
// fail the install.
func collectLook() error {
	slurpDir := filepath.Join(wootcDir(), "install", "slurp")
	if err := os.MkdirAll(slurpDir, 0o755); err != nil {
		return err
	}

	look := map[string]any{}

	// Wallpaper: TranscodedWallpaper is the currently-rendered image even
	// when the source was a slideshow; fall back to the WallPaper value.
	wp, _ := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper`)
	wp = strings.TrimSpace(wp)
	transcoded := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Themes", "TranscodedWallpaper")
	src := ""
	if st, err := os.Stat(transcoded); err == nil && st.Size() > 0 {
		src = transcoded
	} else if wp != "" {
		if _, err := os.Stat(wp); err == nil {
			src = wp
		}
	}
	if src != "" {
		ext := strings.ToLower(filepath.Ext(src))
		if ext == "" || ext == ".transcodedwallpaper" || src == transcoded {
			ext = ".jpg" // TranscodedWallpaper is JPEG-encoded
		}
		if err := copyFile(src, filepath.Join(slurpDir, "wallpaper"+ext)); err == nil {
			look["wallpaper"] = "wallpaper" + ext
		}
	}

	// Dark mode: AppsUseLightTheme 0 = dark.
	if v, err := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme`); err == nil {
		switch strings.TrimSpace(v) {
		case "0":
			look["darkMode"] = "true"
		case "1":
			look["darkMode"] = "false"
		}
	}

	// Accent: DWM ColorizationColor is ARGB.
	if v, err := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -ErrorAction SilentlyContinue).ColorizationColor`); err == nil {
		if n, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64); err == nil {
			look["accentColor"] = fmt.Sprintf("#%02X%02X%02X", (n>>16)&0xFF, (n>>8)&0xFF, n&0xFF)
		}
	}

	// Timezone: record the Windows ID and map the common cases to IANA.
	if v, err := runPowerShellOutput(`(Get-TimeZone).Id`); err == nil {
		winID := strings.TrimSpace(v)
		look["windowsTimeZoneId"] = winID
		if iana, ok := windowsToIANA[winID]; ok {
			look["timezone"] = iana
		}
	}

	// Language + keyboard layout (SPEC §4.4/§4.6 tier-1 auto-apply). The
	// primary UI language is a BCP-47 tag; derive a coarse XKB layout from it.
	if v, err := runPowerShellOutput(`(Get-WinUserLanguageList)[0].LanguageTag`); err == nil {
		tag := strings.TrimSpace(v)
		if tag != "" {
			look["language"] = tag
			if xkb := xkbFromLanguageTag(tag); xkb != "" {
				look["keyboardLayout"] = xkb
			}
		}
	}

	// Taskbar pins + desktop shortcuts (SPEC §4.4 Windows-Style Mode): bring
	// the user's own quick-access set over so the Linux dock/desktop feels
	// familiar. We record the resolved app name + target exe; the target maps
	// to a Linux .desktop id on first login (wootc-apply-look), only for apps
	// that actually exist on the deployed system.
	if taskbar, desktop := collectPinnedApps(); len(taskbar) > 0 || len(desktop) > 0 {
		if len(taskbar) > 0 {
			look["taskbarApps"] = taskbar
		}
		if len(desktop) > 0 {
			look["desktopApps"] = desktop
		}
	}

	return marshalJSONToFile(filepath.Join(slurpDir, "slurp.json"), look)
}

// pinnedApp is one Windows shortcut resolved to its target executable.
type pinnedApp struct {
	Name string `json:"name"`
	Exe  string `json:"exe"`
}

// collectPinnedApps resolves the .lnk shortcuts the user pinned to the
// taskbar and placed on the desktop, in on-screen order, to (name, exe).
// Best-effort: any COM/registry failure yields empty lists, never an error.
func collectPinnedApps() (taskbar, desktop []pinnedApp) {
	// One PowerShell pass resolves every shortcut's TargetPath via WScript.Shell
	// and prints `bucket|name|exe` lines. Taskbar order follows the shell's
	// FavoritesResolve ordering registry value when present, else file order.
	const ps = `
$ErrorActionPreference='SilentlyContinue'
$sh = New-Object -ComObject WScript.Shell
function emit($bucket,$dir){
  if(!(Test-Path $dir)){return}
  Get-ChildItem -Path $dir -Filter *.lnk -File | Sort-Object Name | ForEach-Object {
    $t = $sh.CreateShortcut($_.FullName).TargetPath
    $exe = if($t){Split-Path $t -Leaf}else{''}
    $name = $_.BaseName
    "$bucket|$name|$exe"
  }
}
emit taskbar "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
emit desktop "$env:USERPROFILE\Desktop"
emit desktop "$env:PUBLIC\Desktop"
`
	out, err := runPowerShellOutput(ps)
	if err != nil {
		return nil, nil
	}
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "|", 3)
		if len(parts) != 3 || parts[1] == "" {
			continue
		}
		app := pinnedApp{Name: parts[1], Exe: strings.ToLower(parts[2])}
		key := parts[0] + "|" + strings.ToLower(app.Name)
		if seen[key] {
			continue
		}
		seen[key] = true
		switch parts[0] {
		case "taskbar":
			taskbar = append(taskbar, app)
		case "desktop":
			desktop = append(desktop, app)
		}
	}
	return taskbar, desktop
}

// xkbFromLanguageTag maps a Windows BCP-47 UI language tag (e.g. "en-US",
// "pt-BR", "en-GB") to an XKB layout code. Region-specific keyboards win
// over the bare language default; unmapped tags return "" (skipped, so the
// distro default stays). A full KLID→XKB table is future work.
func xkbFromLanguageTag(tag string) string {
	t := strings.ToLower(tag)
	// Region overrides first.
	switch t {
	case "en-gb":
		return "gb"
	case "pt-br":
		return "br"
	case "en-us", "en-ca":
		return "us"
	case "fr-ca":
		return "ca"
	case "de-ch", "fr-ch":
		return "ch"
	case "es-es":
		return "es"
	case "es-mx", "es-us", "es-ar", "es-co", "es-cl":
		return "latam"
	}
	lang := t
	if i := strings.IndexByte(t, '-'); i > 0 {
		lang = t[:i]
	}
	byLang := map[string]string{
		"en": "us", "de": "de", "fr": "fr", "es": "es", "it": "it",
		"pt": "pt", "ru": "ru", "uk": "ua", "pl": "pl", "nl": "nl",
		"sv": "se", "no": "no", "nb": "no", "da": "dk", "fi": "fi",
		"cs": "cz", "sk": "sk", "hu": "hu", "ro": "ro", "el": "gr",
		"tr": "tr", "he": "il", "ar": "ara", "fa": "ir", "th": "th",
		"ja": "jp", "ko": "kr", "zh": "cn", "hi": "in", "vi": "vn",
		"id": "us", "sr": "rs", "hr": "hr", "bg": "bg", "lt": "lt",
		"lv": "lv", "et": "ee", "sl": "si", "is": "is",
	}
	return byLang[lang]
}

// windowsToIANA covers the common cases; unmapped zones are skipped on the
// target (recorded as windowsTimeZoneId for a future full CLDR table).
var windowsToIANA = map[string]string{
	"Pacific Standard Time":         "America/Los_Angeles",
	"Mountain Standard Time":        "America/Denver",
	"Central Standard Time":         "America/Chicago",
	"Eastern Standard Time":         "America/New_York",
	"Atlantic Standard Time":        "America/Halifax",
	"GMT Standard Time":             "Europe/London",
	"W. Europe Standard Time":       "Europe/Berlin",
	"Romance Standard Time":         "Europe/Paris",
	"Central Europe Standard Time":  "Europe/Warsaw",
	"E. Europe Standard Time":       "Europe/Bucharest",
	"Russian Standard Time":         "Europe/Moscow",
	"Turkey Standard Time":          "Europe/Istanbul",
	"Israel Standard Time":          "Asia/Jerusalem",
	"Arabian Standard Time":         "Asia/Dubai",
	"India Standard Time":           "Asia/Kolkata",
	"Bangladesh Standard Time":      "Asia/Dhaka",
	"SE Asia Standard Time":         "Asia/Bangkok",
	"China Standard Time":           "Asia/Shanghai",
	"Singapore Standard Time":       "Asia/Singapore",
	"Tokyo Standard Time":           "Asia/Tokyo",
	"Korea Standard Time":           "Asia/Seoul",
	"AUS Eastern Standard Time":     "Australia/Sydney",
	"New Zealand Standard Time":     "Pacific/Auckland",
	"Hawaiian Standard Time":        "Pacific/Honolulu",
	"Alaskan Standard Time":         "America/Anchorage",
	"US Mountain Standard Time":     "America/Phoenix",
	"Canada Central Standard Time":  "America/Regina",
	"SA Pacific Standard Time":      "America/Bogota",
	"E. South America Standard Time": "America/Sao_Paulo",
	"Argentina Standard Time":       "America/Argentina/Buenos_Aires",
	"South Africa Standard Time":    "Africa/Johannesburg",
	"Egypt Standard Time":           "Africa/Cairo",
	"W. Central Africa Standard Time": "Africa/Lagos",
	"UTC": "Etc/UTC",
}
