//go:build linux

package main

import (
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvedWindowsProfileIn(t *testing.T) {
	for _, tc := range []struct {
		name, username, mapping, want, wantErr string
		profiles                               []string
		missingRoot                            bool
	}{
		{name: "missing mount", username: "alice", missingRoot: true, wantErr: "Windows profiles are unavailable"},
		{name: "empty mount", username: "alice", wantErr: "choose a profile"},
		{name: "builtins excluded", username: "Public", profiles: []string{"Public", "Default", "Default User", "All Users"}, wantErr: "choose a profile"},
		{name: "case insensitive username", username: "alice", profiles: []string{"Alice", "Bob"}, want: "Alice"},
		{name: "mapping wins over username", username: "alice", profiles: []string{"Alice", "Bob"}, mapping: `{"windowsProfile":"bOB"}`, want: "Bob"},
		{name: "non Latin mapping", username: "migrated", profiles: []string{"田中", "Bob"}, mapping: `{"windowsProfile":"田中"}`, want: "田中"},
		{name: "sole real profile", username: "newname", profiles: []string{"Public", "Default", "Default User", "All Users", "Jane Smith"}, want: "Jane Smith"},
		{name: "ambiguous profiles", username: "newname", profiles: []string{"Alice", "Bob"}, wantErr: "choose a profile"},
		{name: "malformed map falls back to username", username: "alice", profiles: []string{"Alice", "Bob"}, mapping: `{bad`, want: "Alice"},
		{name: "stale map without fallback stays ambiguous", username: "newname", profiles: []string{"Alice", "Bob"}, mapping: `{"windowsProfile":"Missing"}`, wantErr: "choose a profile"},
		{name: "mapping cannot escape root", username: "newname", profiles: []string{"Alice", "Bob"}, mapping: `{"windowsProfile":"../../outside"}`, wantErr: "choose a profile"},
		{name: "mapping cannot select builtin", username: "newname", profiles: []string{"Public", "Alice", "Bob"}, mapping: `{"windowsProfile":"Public"}`, wantErr: "choose a profile"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			base := t.TempDir()
			root := filepath.Join(base, "Users")
			home := filepath.Join(base, "home")
			if !tc.missingRoot {
				if err := os.Mkdir(root, 0700); err != nil {
					t.Fatal(err)
				}
				for _, profile := range tc.profiles {
					if err := os.Mkdir(filepath.Join(root, profile), 0700); err != nil {
						t.Fatal(err)
					}
				}
				// Files and symlinks must never add candidates or win a mapping.
				if err := os.WriteFile(filepath.Join(root, "ordinary-file"), nil, 0600); err != nil {
					t.Fatal(err)
				}
				outside := filepath.Join(base, "outside")
				if err := os.Mkdir(outside, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, filepath.Join(root, "linked-profile")); err != nil {
					t.Fatal(err)
				}
			}
			if tc.mapping != "" {
				config := filepath.Join(home, ".config", "wootc")
				if err := os.MkdirAll(config, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(config, "profile-map.json"), []byte(tc.mapping), 0600); err != nil {
					t.Fatal(err)
				}
			}
			path, profile, err := resolvedWindowsProfileIn(&user.User{Username: tc.username, HomeDir: home}, root)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) || path != "" || profile != "" {
					t.Fatalf("got (%q, %q, %v), want no selection and %q", path, profile, err, tc.wantErr)
				}
				return
			}
			if err != nil || profile != tc.want || path != filepath.Join(root, tc.want) {
				t.Fatalf("got (%q, %q, %v), want exact on-disk profile %q", path, profile, err, tc.want)
			}
		})
	}
}
