//go:build windows

package main

import "golang.org/x/sys/windows/registry"

// systemPrefersDark reports whether Windows is set to a DARK app theme.
//
// This exists only to pick the window's initial BackgroundColour. Wails paints
// that colour before WebView2 has rendered anything, so with it hardcoded dark
// a light-mode machine got a dark flash on every launch even after the page
// itself learned to follow the theme (#173). The page keeps using CSS
// prefers-color-scheme; this just stops the first frame from disagreeing.
//
// "AppsUseLightTheme" is the app-level setting (Settings > Personalisation >
// Colours > "Choose your default app mode"), which is the one WebView2 maps to
// prefers-color-scheme. Deliberately NOT SystemUsesLightTheme, which controls
// the taskbar/Start chrome and can differ.
//
// Any failure falls back to dark, matching the historical appearance and the
// :root defaults in style.css.
func systemPrefersDark() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`,
		registry.QUERY_VALUE)
	if err != nil {
		return true
	}
	defer k.Close()

	// 0 = dark app mode, 1 = light app mode. Absent on older builds.
	v, _, err := k.GetIntegerValue("AppsUseLightTheme")
	if err != nil {
		return true
	}
	return v == 0
}
