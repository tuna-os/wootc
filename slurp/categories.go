package slurp

import "strings"

// Category is one kind of user data in a Windows profile.
type Category struct {
	// Name is the stable identifier frontends show and recipes carry
	// ("Documents", "Wallpapers", ...).
	Name string
	// Path is where the category lives, relative to the profile directory,
	// with forward slashes.
	Path string
}

// categories is the canonical list, in the order Scan reports them. The
// order is part of the `fisherman scan` JSON contract.
var categories = []Category{
	{"Documents", "Documents"},
	{"Desktop", "Desktop"},
	{"Downloads", "Downloads"},
	{"Pictures", "Pictures"},
	{"Music", "Music"},
	{"Videos", "Videos"},
	{"Wallpapers", "AppData/Roaming/Microsoft/Windows/Themes"},
}

// Categories returns every migratable data category, in canonical order.
// The slice is a copy; callers may modify it.
func Categories() []Category {
	return append([]Category(nil), categories...)
}

// UserFolders returns the names of the categories that are plain top-level
// profile folders (Documents, Desktop, Downloads, Pictures, Music, Videos),
// in canonical order: the folders a Linux home has a same-named
// counterpart for.
func UserFolders() []string {
	var out []string
	for _, c := range categories {
		if c.Path == c.Name {
			out = append(out, c.Name)
		}
	}
	return out
}

// IsUserFolder reports whether name is exactly one of UserFolders.
func IsUserFolder(name string) bool {
	for _, f := range UserFolders() {
		if f == name {
			return true
		}
	}
	return false
}

// CategoryPath maps a category name (case-insensitive) to its
// profile-relative path, or "" when the name is not a known category.
func CategoryPath(name string) string {
	for _, c := range categories {
		if strings.EqualFold(c.Name, name) {
			return c.Path
		}
	}
	return ""
}
