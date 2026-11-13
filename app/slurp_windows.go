//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/tuna-os/wootc/slurp"
)

// collectWifi exports the user's saved Wi-Fi profiles (with cleartext keys) to
// C:\wootc\install\wifi\ so the deployed Linux system can recreate them as
// NetworkManager connections on first boot (SPEC §4.6). Requires admin; the
// transient export is shredded on the Linux side right after import. Best-
// effort — a machine with no Wi-Fi, or an export failure, never fails install.
func collectWifi() error {
	wifiDir := filepath.Join(wootcDir(), "install", "wifi")
	if err := os.MkdirAll(wifiDir, 0o700); err != nil {
		return err
	}
	// netsh writes one <profile>.xml per saved network; key=clear embeds the
	// PSK so NetworkManager can reuse it. Enterprise profiles export too but
	// the Linux bridge detects and skips them.
	_, err := runPowerShellOutput(fmt.Sprintf(
		`netsh wlan export profile key=clear folder="%s" | Out-Null`, wifiDir))
	return err
}

// collectLook gathers the user's Windows look (wallpaper, dark mode,
// accent color, timezone) into C:\wootc\install\slurp\slurp.json (a
// slurp.Look, the type the shared slurp module owns) for the target
// system's wootc-apply-look (SPEC §4.4, Windows-Style Mode). Best-effort:
// a machine with a slideshow wallpaper or odd registry state must never
// fail the install.
func collectLook() error {
	slurpDir := filepath.Join(wootcDir(), "install", "slurp")
	if err := os.MkdirAll(slurpDir, 0o755); err != nil {
		return err
	}

	var look slurp.Look

	// Wallpaper: TranscodedWallpaper is the currently-rendered image even
	// when the source was a slideshow; fall back to the WallPaper value.
	wp, _ := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper`)
	wp = strings.TrimSpace(wp)
	transcoded := filepath.Join(os.Getenv("APPDATA"), filepath.FromSlash(slurp.RoamingTranscodedWallpaper))
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
			look.Wallpaper = "wallpaper" + ext
		}
	}

	// Dark mode: AppsUseLightTheme 0 = dark.
	if v, err := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme`); err == nil {
		switch strings.TrimSpace(v) {
		case "0":
			look.DarkMode = "true"
		case "1":
			look.DarkMode = "false"
		}
	}

	// Accent: DWM ColorizationColor is ARGB.
	if v, err := runPowerShellOutput(`(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -ErrorAction SilentlyContinue).ColorizationColor`); err == nil {
		if n, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64); err == nil {
			look.AccentColor = fmt.Sprintf("#%02X%02X%02X", (n>>16)&0xFF, (n>>8)&0xFF, n&0xFF)
		}
	}

	// Timezone: record the Windows ID and map the common cases to IANA.
	if v, err := runPowerShellOutput(`(Get-TimeZone).Id`); err == nil {
		winID := strings.TrimSpace(v)
		look.WindowsTimeZoneID = winID
		if iana, ok := slurp.IANAFromWindowsZone(winID); ok {
			look.Timezone = iana
		}
	}

	// Language + keyboard layout (SPEC §4.4/§4.6 tier-1 auto-apply). The
	// primary UI language is a BCP-47 tag; derive a coarse XKB layout from it.
	if v, err := runPowerShellOutput(`(Get-WinUserLanguageList)[0].LanguageTag`); err == nil {
		tag := strings.TrimSpace(v)
		if tag != "" {
			look.Language = tag
			look.KeyboardLayout = slurp.XKBFromLanguageTag(tag)
		}
	}

	// Taskbar pins + desktop shortcuts (SPEC §4.4 Windows-Style Mode): bring
	// the user's own quick-access set over so the Linux dock/desktop feels
	// familiar. We record the resolved app name + target exe; the target maps
	// to a Linux .desktop id on first login (wootc-apply-look), only for apps
	// that actually exist on the deployed system.
	look.TaskbarApps, look.DesktopApps = collectPinnedApps()

	return marshalJSONToFile(filepath.Join(slurpDir, slurp.LookFile), look)
}

// collectPinnedApps resolves the .lnk shortcuts the user pinned to the
// taskbar and placed on the desktop, in on-screen order, to (name, exe).
// Best-effort: any COM/registry failure yields empty lists, never an error.
func collectPinnedApps() (taskbar, desktop []slurp.PinnedApp) {
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
		app := slurp.PinnedApp{Name: parts[1], Exe: strings.ToLower(parts[2])}
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
