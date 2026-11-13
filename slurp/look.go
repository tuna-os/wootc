package slurp

import "path/filepath"

// BundleDir is where wootc's Windows side leaves the slurp bundle, relative
// to the Windows volume root (C:\wootc\install\slurp), with forward
// slashes. The installed system reads it back through the bridged volume.
const BundleDir = "wootc/install/slurp"

// LookFile is the name of the look bundle (a Look as JSON) in BundleDir.
const LookFile = "slurp.json"

// LookPath returns where the look bundle lives on the Windows volume
// mounted at volumeRoot.
func LookPath(volumeRoot string) string {
	return filepath.Join(volumeRoot, filepath.FromSlash(BundleDir), LookFile)
}

// Look is the user's Windows look and locale, written to LookFile on the
// Windows side and applied once per Linux user on the installed system
// (wootc-apply-look, wootc-identity). Every field is optional: a value
// Windows did not report is left out.
//
// The fields are declared in key order, so the encoding is the same as the
// map the collector used to marshal.
type Look struct {
	// AccentColor is the DWM colorization colour as #RRGGBB.
	AccentColor string `json:"accentColor,omitempty"`
	// DarkMode is "true" or "false" (a string: the shell appliers read it
	// as one).
	DarkMode string `json:"darkMode,omitempty"`
	// DesktopApps are the shortcuts on the user's and the public desktop.
	DesktopApps []PinnedApp `json:"desktopApps,omitempty"`
	// KeyboardLayout is the XKB layout derived from Language.
	KeyboardLayout string `json:"keyboardLayout,omitempty"`
	// Language is the primary UI language as a BCP-47 tag.
	Language string `json:"language,omitempty"`
	// TaskbarApps are the taskbar pins in on-screen order.
	TaskbarApps []PinnedApp `json:"taskbarApps,omitempty"`
	// Timezone is the IANA zone for WindowsTimeZoneID, when it is mapped.
	Timezone string `json:"timezone,omitempty"`
	// Wallpaper is the wallpaper's file name inside BundleDir.
	Wallpaper string `json:"wallpaper,omitempty"`
	// WindowsTimeZoneID is the Windows time zone ID as Windows reported it.
	WindowsTimeZoneID string `json:"windowsTimeZoneId,omitempty"`
}

// PinnedApp is one Windows shortcut resolved to its target executable.
type PinnedApp struct {
	Name string `json:"name"`
	Exe  string `json:"exe"`
}
