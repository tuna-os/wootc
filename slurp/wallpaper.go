package slurp

// RoamingTranscodedWallpaper is the image Windows renders as the desktop
// background (JPEG-encoded, even for a slideshow), relative to the roaming
// AppData folder (%APPDATA%).
const RoamingTranscodedWallpaper = "Microsoft/Windows/Themes/TranscodedWallpaper"

// SystemWallpaperDir holds the stock Windows wallpapers, relative to the
// volume root.
const SystemWallpaperDir = "Windows/Web/Wallpaper"

// wallpaperSources are the known locations where Windows stores wallpapers,
// relative to a user profile directory (e.g. C:\Users\Jorge\).
var wallpaperSources = []string{
	// Current wallpaper (transcoded copy Windows keeps active)
	"AppData/Roaming/" + RoamingTranscodedWallpaper,
	// Windows Spotlight lock screen / desktop images
	"AppData/Local/Packages/Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy/LocalState/Assets",
	// User-set wallpapers cached by Windows
	"AppData/Roaming/Microsoft/Windows/Themes/CachedFiles",
}

// WallpaperSources returns the profile-relative paths (forward slashes)
// where Windows keeps a user's wallpapers: the current one, Spotlight's
// assets, and the cached user-set ones.
func WallpaperSources() []string {
	return append([]string(nil), wallpaperSources...)
}
