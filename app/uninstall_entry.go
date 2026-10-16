package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

// stagedEngineName is the copy of the running engine that configureBCD keeps
// under <wootcDir>\install for the recovery tasks. It lives with the install,
// not with whichever package started it, so it outlives that package.
const stagedEngineName = "wootc.exe"

// uninstallEntryTarget picks the program the Windows Apps entry runs. The
// staged copy wins whenever it exists: the program that started the install
// may be a download the user deletes, or a native preview engine under
// Program Files that the preview's own uninstaller removes (and that the
// preview installer refuses to install over, so every upgrade removes it
// first). Either way the Apps entry would then point at a missing file and
// the Linux install could no longer be removed from Apps.
func uninstallEntryTarget(staged, self string, exists func(string) bool) string {
	if staged != "" && exists(staged) {
		return staged
	}
	return self
}

// uninstallEntryValues are the registry values of the Apps entry.
func uninstallEntryValues(b Branding, target, installLocation string) map[string]string {
	return map[string]string{
		"DisplayName": uninstallDisplayName(b), "Publisher": b.Publisher,
		"DisplayVersion": b.Version, "DisplayIcon": target,
		"URLInfoAbout": b.WebsiteURL, "HelpLink": b.SupportURL,
		"InstallLocation": installLocation,
		"UninstallString": fmt.Sprintf(`"%s" uninstall`, target),
	}
}

// pathWithin reports whether path is dir or lies under it, comparing the way
// Windows does (case-insensitively, either separator).
func pathWithin(path, dir string) bool {
	norm := func(p string) string {
		return strings.ToLower(filepath.Clean(strings.ReplaceAll(p, `\`, "/")))
	}
	p, d := norm(path), norm(dir)
	if d == "" || d == "." {
		return false
	}
	return p == d || strings.HasPrefix(p, strings.TrimSuffix(d, "/")+"/")
}

// uninstallRemovesImage reports whether uninstall is about to delete the
// directory its own program runs from, which is the case when it runs from
// the staged copy the Apps entry names. Windows cannot delete a running
// image, so the program has to move itself out of the way first or the
// install directory survives and the uninstall reports itself incomplete.
func uninstallRemovesImage(self string, removed []string) bool {
	for _, dir := range removed {
		if pathWithin(self, dir) {
			return true
		}
	}
	return false
}
