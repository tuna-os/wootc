package main

import (
	"os"
	"path/filepath"
	"testing"
)

// listWindowsProfiles decides who gets a Linux account, so both directions
// matter: missing a real person means their files are silently left behind
// (the bridge skips profiles with no matching account), while inventing one
// for a system or leftover directory puts a stranger on the login screen.
func TestListWindowsProfiles(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")

	// A real profile is a directory containing NTUSER.DAT.
	real := func(name string) {
		d := filepath.Join(users, name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "NTUSER.DAT"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	bare := func(name string) {
		if err := os.MkdirAll(filepath.Join(users, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	real("jreilly")          // the installer-runner (primary)
	real("Alice Smith")      // a real second user, needs sanitising
	real("bob")              // a real third user
	real("Public")           // system
	real("defaultuser0")     // system-ish leftover from OOBE
	bare("Default")          // system, and no NTUSER.DAT
	bare("leftover-profile") // a directory that was never a logged-in user
	if err := os.WriteFile(filepath.Join(users, "desktop.ini"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := listProfilesIn(users, "jreilly")

	want := []string{"alice-smith", "bob", "defaultuser0"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v (sorted, deterministic)", got, want)
		}
	}

	// The primary must never be duplicated — fisherman already created it.
	for _, g := range got {
		if g == "jreilly" {
			t.Error("primary user must be excluded")
		}
	}
}

func TestListWindowsProfilesNoUsersDir(t *testing.T) {
	if got := listProfilesIn(filepath.Join(t.TempDir(), "Users"), "jreilly"); got != nil {
		t.Errorf("got %v, want nil when there is no Users directory", got)
	}
}
