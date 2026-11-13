package slurp

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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

// wallpaperExtensions filters files to only image types.
var wallpaperExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".bmp": true,
	".webp": true, ".tiff": true, ".tif": true,
}

// WallpaperResult holds the outcome of a wallpaper extraction attempt.
type WallpaperResult struct {
	// Found is true if at least one wallpaper was extracted.
	Found bool
	// ScratchDir is the path where wallpapers are stored (under ScratchBase).
	ScratchDir string
	// Count is the number of wallpaper files extracted.
	Count int
	// TotalBytes is the total size of extracted wallpapers.
	TotalBytes int64
}

// ExtractWallpapers mounts an NTFS partition read-only, finds Windows user
// wallpapers, and copies them to RAM-backed scratch storage.
// This must be called BEFORE partitioning destroys the source data.
// Returns a result describing what was found; errors are non-fatal.
func (s *Slurper) ExtractWallpapers(ntfsPartition string) (*WallpaperResult, error) {
	result := &WallpaperResult{}

	if err := os.MkdirAll(s.ScratchBase, 0o755); err != nil {
		return result, fmt.Errorf("creating scratch dir: %w", err)
	}
	if err := os.MkdirAll(s.MountPoint, 0o755); err != nil {
		return result, fmt.Errorf("creating mount point: %w", err)
	}

	s.substep("Mounting Windows partition (read-only)")
	if err, err2 := s.mountNTFS(ntfsPartition, s.MountPoint); err != nil && err2 != nil {
		_ = os.Remove(s.MountPoint)
		return result, fmt.Errorf("mounting NTFS (%s): ntfs3: %v, ntfs-3g: %v", ntfsPartition, err, err2)
	}
	defer func() {
		_ = s.Runner.Run("umount", s.MountPoint)
		_ = os.Remove(s.MountPoint)
	}()

	usersDir := filepath.Join(s.MountPoint, UsersDir)
	profiles, err := Profiles(usersDir)
	if err != nil {
		return result, fmt.Errorf("reading Users directory: %w", err)
	}

	wallpaperDir := filepath.Join(s.ScratchBase, "wallpapers")
	if err := os.MkdirAll(wallpaperDir, 0o755); err != nil {
		return result, fmt.Errorf("creating wallpaper scratch: %w", err)
	}

	for _, name := range profiles {
		result.Count += extractFromProfile(filepath.Join(usersDir, name), filepath.Join(wallpaperDir, name))
	}

	// Also check the system-wide wallpaper directory
	sysWallpaperDir := filepath.Join(s.MountPoint, filepath.FromSlash(SystemWallpaperDir))
	if info, err := os.Stat(sysWallpaperDir); err == nil && info.IsDir() {
		sysTarget := filepath.Join(wallpaperDir, "_windows_defaults")
		result.Count += extractFromDir(sysWallpaperDir, sysTarget, 10) // cap at 10 system wallpapers
	}

	if result.Count > 0 {
		result.Found = true
		result.ScratchDir = wallpaperDir
		result.TotalBytes = dirSize(wallpaperDir)
		s.substep(fmt.Sprintf("Extracted %d wallpaper(s) (%s)", result.Count, humanBytes(result.TotalBytes)))
	}

	return result, nil
}

// extractFromProfile extracts wallpapers from a single Windows user profile.
func extractFromProfile(profileDir, targetDir string) int {
	count := 0

	for _, relPath := range wallpaperSources {
		srcPath := filepath.Join(profileDir, filepath.FromSlash(relPath))
		info, err := os.Stat(srcPath)
		if err != nil {
			continue
		}

		if info.IsDir() {
			// Directory of wallpapers (e.g. Spotlight assets, CachedFiles)
			count += extractFromDir(srcPath, targetDir, 20)
		} else if info.Size() > 10*1024 { // skip tiny files (<10KB, likely not wallpapers)
			// Single file (e.g. TranscodedWallpaper)
			if err := copyFile(srcPath, targetDir, info.Name()); err == nil {
				count++
			}
		}
	}

	// Also check Pictures folder for common wallpaper-named files
	picturesDir := filepath.Join(profileDir, "Pictures")
	if info, err := os.Stat(picturesDir); err == nil && info.IsDir() {
		count += extractWallpapersFromPictures(picturesDir, targetDir)
	}

	return count
}

// extractFromDir copies image files from a source directory to a target,
// limited to maxFiles. Only copies files that look like wallpapers (by size
// and extension). Returns count of files copied.
func extractFromDir(srcDir, targetDir string, maxFiles int) int {
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return 0
	}

	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return 0
	}

	count := 0
	for _, entry := range entries {
		if count >= maxFiles {
			break
		}
		if entry.IsDir() {
			continue
		}

		info, err := entry.Info()
		if err != nil || info.Size() < 50*1024 { // wallpapers are usually >50KB
			continue
		}
		// Cap at 20MB per file to avoid pulling huge BMPs
		if info.Size() > 20*1024*1024 {
			continue
		}

		name := entry.Name()
		ext := strings.ToLower(filepath.Ext(name))

		// Spotlight assets have no extension — check if plausible wallpaper size
		if ext == "" && info.Size() > 100*1024 && info.Size() < 20*1024*1024 {
			// Spotlight images are JPEGs without extension; rename with .jpg
			if err := copyFile(filepath.Join(srcDir, name), targetDir, name+".jpg"); err == nil {
				count++
			}
			continue
		}

		if !wallpaperExtensions[ext] {
			continue
		}

		if err := copyFile(filepath.Join(srcDir, name), targetDir, name); err == nil {
			count++
		}
	}
	return count
}

// extractWallpapersFromPictures looks for wallpaper-related images in the
// user's Pictures folder. Only grabs files in a "Wallpapers" or "Backgrounds"
// subfolder.
func extractWallpapersFromPictures(picturesDir, targetDir string) int {
	count := 0

	wallpaperSubdirs := []string{"Wallpapers", "Backgrounds", "wallpapers", "backgrounds"}
	for _, sub := range wallpaperSubdirs {
		subDir := filepath.Join(picturesDir, sub)
		if info, err := os.Stat(subDir); err == nil && info.IsDir() {
			count += extractFromDir(subDir, targetDir, 10)
		}
	}

	return count
}

// copyFile copies a single file from src to targetDir/name.
func copyFile(src, targetDir, name string) error {
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return err
	}

	dst := filepath.Join(targetDir, name)
	// Avoid overwriting (different profiles may have same-named files)
	if _, err := os.Stat(dst); err == nil {
		dst = filepath.Join(targetDir, "dup_"+name)
	}

	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o644)
}

// InjectWallpapers copies extracted wallpapers from scratch into the installed
// system, under <var>/home/.windows-wallpapers: a shared, root-owned,
// world-readable directory next to the users' homes.
//
// varDir is the /var the BOOTED system sees (the stateroot var on ostree,
// state/os/default/var on composefs). It is not <target>/var, which is the
// physical sysroot and is never mounted at /var.
//
// The directory belongs to root: no account exists yet whose uid could be
// assumed, and every user must be able to read it.
func (s *Slurper) InjectWallpapers(varDir string, slurpResult *WallpaperResult) error {
	if slurpResult == nil || !slurpResult.Found {
		return nil
	}

	bgDir := filepath.Join(varDir, "home", ".windows-wallpapers")
	if err := os.MkdirAll(bgDir, 0o755); err != nil {
		return fmt.Errorf("creating wallpaper target dir: %w", err)
	}

	if err := s.Runner.Run("cp", "-a", slurpResult.ScratchDir+"/.", bgDir+"/"); err != nil {
		return fmt.Errorf("copying wallpapers to target: %w", err)
	}
	// The scratch copy was made by root; make sure of it, and of the modes.
	if err := s.Runner.Run("chown", "-R", "0:0", bgDir); err != nil {
		s.warnf("  warning: could not chown wallpapers: %v\n", err)
	}
	if err := s.Runner.Run("chmod", "-R", "u=rwX,go=rX", bgDir); err != nil {
		s.warnf("  warning: could not chmod wallpapers: %v\n", err)
	}

	// Fix SELinux labels
	_ = s.Runner.Run("restorecon", "-R", bgDir)

	s.info(fmt.Sprintf("Migrated %d Windows wallpaper(s) to %s", slurpResult.Count, bgDir))
	return nil
}

// CleanupScratch removes the RAM-backed scratch directory.
func (s *Slurper) CleanupScratch() {
	_ = os.RemoveAll(s.ScratchBase)
}

// dirSize returns total bytes of all files under a directory.
func dirSize(path string) int64 {
	var total int64
	_ = filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil //nolint:nilerr // best-effort: absent/unreadable source → skip, continue
		}
		total += info.Size()
		return nil
	})
	return total
}

func humanBytes(b int64) string {
	const (
		KB = 1024
		MB = 1024 * KB
		GB = 1024 * MB
	)
	switch {
	case b >= GB:
		return fmt.Sprintf("%.1f GB", float64(b)/float64(GB))
	case b >= MB:
		return fmt.Sprintf("%.1f MB", float64(b)/float64(MB))
	case b >= KB:
		return fmt.Sprintf("%.1f KB", float64(b)/float64(KB))
	default:
		return fmt.Sprintf("%d B", b)
	}
}
