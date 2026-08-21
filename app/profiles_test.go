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
// It also decides the directory→account map the first-boot bridge uses, so
// the WindowsDir half must stay the RAW directory name.
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

	real("James Reilly")     // the installer-runner's own profile directory
	real("Alice Smith")      // a real second user, needs sanitising
	real("bob")              // a real third user
	real("Public")           // system
	real("defaultuser0")     // OOBE leftover — Windows often fails to delete it
	bare("Default")          // system, and no NTUSER.DAT
	bare("leftover-profile") // a directory that was never a logged-in user
	if err := os.WriteFile(filepath.Join(users, "desktop.ini"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The primary chose the username "james" — nothing like the directory
	// name. Exclusion must work on the DIRECTORY, or the person who ran the
	// installer gets a locked doppelganger account (and the bridge's #73
	// single-user fallback breaks).
	got := listProfilesIn(users, "james", "James Reilly")

	want := []profileMapping{
		{WindowsDir: "Alice Smith", LinuxUser: "alice-smith"},
		{WindowsDir: "bob", LinuxUser: "bob"},
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v (sorted, deterministic)", got, want)
		}
	}
}

// A profile whose directory happens to match the primary username must not be
// duplicated either — fisherman already created that account.
func TestListWindowsProfilesPrimaryNameCollision(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")
	d := filepath.Join(users, "jreilly")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "NTUSER.DAT"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := listProfilesIn(users, "jreilly", ""); len(got) != 0 {
		t.Errorf("got %v, want none — primary user must be excluded", got)
	}
}

func TestListWindowsProfilesNoUsersDir(t *testing.T) {
	if got := listProfilesIn(filepath.Join(t.TempDir(), "Users"), "jreilly", "jreilly"); got != nil {
		t.Errorf("got %v, want nil when there is no Users directory", got)
	}
}
