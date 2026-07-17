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

	return marshalJSONToFile(filepath.Join(slurpDir, "slurp.json"), look)
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
