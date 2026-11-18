package slurp

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestCategories_CanonicalOrderAndCopy(t *testing.T) {
	var names []string
	for _, c := range Categories() {
		names = append(names, c.Name)
	}
	want := []string{"Documents", "Pictures", "Downloads", "Music", "Videos", "Desktop", "Wallpapers"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("Categories() = %v, want %v (the order is the dashboard order)", names, want)
	}
	got := Categories()
	got[0].Name = "mutated"
	if Categories()[0].Name != "Documents" {
		t.Error("Categories() returned the package's own slice")
	}
}

func TestUserFolders(t *testing.T) {
	want := []string{"Documents", "Pictures", "Downloads", "Music", "Videos", "Desktop"}
	if got := UserFolders(); !reflect.DeepEqual(got, want) {
		t.Fatalf("UserFolders() = %v, want %v", got, want)
	}
	for _, f := range want {
		if !IsUserFolder(f) {
			t.Errorf("IsUserFolder(%q) = false", f)
		}
	}
	for _, f := range []string{"Wallpapers", "documents", "steam", "", "../Documents"} {
		if IsUserFolder(f) {
			t.Errorf("IsUserFolder(%q) = true", f)
		}
	}
}

func TestIsSystemProfile(t *testing.T) {
	for _, name := range []string{"Public", "Default", "Default User", "All Users", ".hidden"} {
		if !IsSystemProfile(name) {
			t.Errorf("IsSystemProfile(%q) = false", name)
		}
	}
	for _, name := range []string{"Alice", "public", "Jane Smith", "田中"} {
		if IsSystemProfile(name) {
			t.Errorf("IsSystemProfile(%q) = true", name)
		}
	}
}

// usersFixture makes a Users directory with the given profile directories,
// plus a file and a symlink to a directory outside, neither of which may
// ever count as a profile.
func usersFixture(t *testing.T, profiles ...string) string {
	t.Helper()
	base := t.TempDir()
	root := filepath.Join(base, "Users")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, p := range profiles {
		if err := os.Mkdir(filepath.Join(root, p), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "desktop.ini"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(base, "outside")
	if err := os.Mkdir(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked-profile")); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestProfiles(t *testing.T) {
	root := usersFixture(t, "Public", "Default", "Default User", "All Users", ".hidden", "Bob", "Alice")
	got, err := Profiles(root)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"Alice", "Bob"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Profiles = %v, want %v", got, want)
	}
	if _, err := Profiles(filepath.Join(root, "missing")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("missing Users dir: err = %v, want ErrNotExist", err)
	}
}

func TestResolveProfile(t *testing.T) {
	for _, tc := range []struct {
		name      string
		profiles  []string
		preferred []string
		want      string
		ambiguous bool
	}{
		{name: "empty volume", ambiguous: true},
		{name: "builtins only", profiles: []string{"Public", "Default", "Default User", "All Users"}, preferred: []string{"Public"}, ambiguous: true},
		{name: "case-insensitive", profiles: []string{"Alice", "Bob"}, preferred: []string{"alice"}, want: "Alice"},
		{name: "first preference wins", profiles: []string{"Alice", "Bob"}, preferred: []string{"bOB", "alice"}, want: "Bob"},
		{name: "empty preference skipped", profiles: []string{"Alice", "Bob"}, preferred: []string{"", "alice"}, want: "Alice"},
		{name: "stale preference falls through", profiles: []string{"Alice", "Bob"}, preferred: []string{"Missing", "bob"}, want: "Bob"},
		{name: "non-Latin", profiles: []string{"田中", "Bob"}, preferred: []string{"田中"}, want: "田中"},
		{name: "sole profile", profiles: []string{"Public", "Jane Smith"}, preferred: []string{"newname"}, want: "Jane Smith"},
		{name: "ambiguous", profiles: []string{"Alice", "Bob"}, preferred: []string{"newname"}, ambiguous: true},
		{name: "no escape", profiles: []string{"Alice", "Bob"}, preferred: []string{"../../outside", "linked-profile"}, ambiguous: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := usersFixture(t, tc.profiles...)
			path, profile, err := ResolveProfile(root, tc.preferred...)
			if tc.ambiguous {
				if !errors.Is(err, ErrProfileAmbiguous) || path != "" || profile != "" {
					t.Fatalf("got (%q, %q, %v), want ErrProfileAmbiguous", path, profile, err)
				}
				return
			}
			if err != nil || profile != tc.want || path != filepath.Join(root, tc.want) {
				t.Fatalf("got (%q, %q, %v), want %q", path, profile, err, tc.want)
			}
		})
	}
	if _, _, err := ResolveProfile(filepath.Join(t.TempDir(), "nope"), "alice"); err == nil || errors.Is(err, ErrProfileAmbiguous) {
		t.Errorf("unreadable Users dir: err = %v, want the listing error", err)
	}
}

func TestXKBFromLanguageTag(t *testing.T) {
	for tag, want := range map[string]string{
		"en-US": "us", "en-GB": "gb", "pt-BR": "br", "pt-PT": "pt", "fr-CA": "ca",
		"de-CH": "ch", "fr-CH": "ch", "es-ES": "es", "es-MX": "latam", "de-DE": "de",
		"ja": "jp", "nb-NO": "no", "uk-UA": "ua", "EN-gb": "gb", "xx-YY": "", "": "", "-": "",
	} {
		if got := XKBFromLanguageTag(tag); got != want {
			t.Errorf("XKBFromLanguageTag(%q) = %q, want %q", tag, got, want)
		}
	}
}

func TestIANAFromWindowsZone(t *testing.T) {
	if z, ok := IANAFromWindowsZone("Pacific Standard Time"); !ok || z != "America/Los_Angeles" {
		t.Errorf("Pacific = %q, %v", z, ok)
	}
	if z, ok := IANAFromWindowsZone("UTC"); !ok || z != "Etc/UTC" {
		t.Errorf("UTC = %q, %v", z, ok)
	}
	if z, ok := IANAFromWindowsZone("Mars Standard Time"); ok || z != "" {
		t.Errorf("unmapped = %q, %v", z, ok)
	}
}

// The look bundle must encode exactly as the map[string]any the collector
// marshalled before it had a type: keys in sorted order, absent when unset.
func TestLook_EncodesLikeTheMap(t *testing.T) {
	apps := []PinnedApp{{Name: "Firefox", Exe: "firefox.exe"}}
	look := Look{
		AccentColor: "#E62D42", DarkMode: "true", DesktopApps: apps, KeyboardLayout: "us",
		Language: "en-US", TaskbarApps: apps, Timezone: "America/New_York",
		Wallpaper: "wallpaper.jpg", WindowsTimeZoneID: "Eastern Standard Time",
	}
	asMap := map[string]any{
		"accentColor": "#E62D42", "darkMode": "true", "desktopApps": apps, "keyboardLayout": "us",
		"language": "en-US", "taskbarApps": apps, "timezone": "America/New_York",
		"wallpaper": "wallpaper.jpg", "windowsTimeZoneId": "Eastern Standard Time",
	}
	for _, indent := range []string{"", "  "} {
		got, err := json.MarshalIndent(look, "", indent)
		if err != nil {
			t.Fatal(err)
		}
		want, err := json.MarshalIndent(asMap, "", indent)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(want) {
			t.Errorf("Look encodes as\n%s\nwant\n%s", got, want)
		}
	}
	if got, _ := json.Marshal(Look{DarkMode: "false"}); string(got) != `{"darkMode":"false"}` {
		t.Errorf("sparse Look = %s", got)
	}
	var back Look
	if err := json.Unmarshal([]byte(`{"darkMode":"true","taskbarApps":[{"exe":"steam.exe","name":"Steam"}]}`), &back); err != nil {
		t.Fatal(err)
	}
	if back.DarkMode != "true" || len(back.TaskbarApps) != 1 || back.TaskbarApps[0].Exe != "steam.exe" {
		t.Errorf("decoded %+v", back)
	}
}

func TestLookPath(t *testing.T) {
	want := filepath.Join("/run/wootc/host", "wootc", "install", "slurp", "slurp.json")
	if got := LookPath("/run/wootc/host"); got != want {
		t.Errorf("LookPath = %q, want %q", got, want)
	}
}

func TestWallpaperSources(t *testing.T) {
	got := WallpaperSources()
	if len(got) != 3 || got[0] != "AppData/Roaming/Microsoft/Windows/Themes/TranscodedWallpaper" {
		t.Fatalf("WallpaperSources() = %v", got)
	}
	got[0] = "mutated"
	if WallpaperSources()[0] == "mutated" {
		t.Error("WallpaperSources() returned the package's own slice")
	}
}
