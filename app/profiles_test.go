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
	got, err := listProfilesIn(users, "james", "James Reilly")
	if err != nil {
		t.Fatal(err)
	}

	want := []ProfileAccount{
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

// A different profile that matches the selected primary Linux username must
// still get its own account, not disappear from the migration.
func TestListWindowsProfilesPrimaryNameCollision(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")
	d := filepath.Join(users, "jreilly")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "NTUSER.DAT"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := listProfilesIn(users, "jreilly", "actual-owner")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != (ProfileAccount{"jreilly", "user1"}) {
		t.Errorf("got %v, want a separate fallback account for the other profile", got)
	}
}

func TestListWindowsProfilesNoUsersDir(t *testing.T) {
	if _, err := listProfilesIn(filepath.Join(t.TempDir(), "Users"), "jreilly", "jreilly"); err == nil {
		t.Fatal("an unreadable profile inventory must not silently become an empty plan")
	}
}

// Non-Latin profiles (CJK, Cyrillic) and collisions after truncation must
// receive userN fallback accounts instead of being silently dropped (#197, #224).
func TestListWindowsProfilesNonLatinAndCollisionFallbacks(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")
	createProfile := func(name string) {
		d := filepath.Join(users, name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "NTUSER.DAT"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	createProfile("田中")
	createProfile("Иван")
	createProfile("very-long-profile-name-that-truncates-1111")
	createProfile("very-long-profile-name-that-truncates-2222")

	got, err := listProfilesIn(users, "primary", "PrimaryUser")
	if err != nil {
		t.Fatal(err)
	}

	want := []ProfileAccount{
		{WindowsDir: "very-long-profile-name-that-truncates-2222", LinuxUser: "user1"},
		{WindowsDir: "Иван", LinuxUser: "user2"},
		{WindowsDir: "田中", LinuxUser: "user3"},
		{WindowsDir: "very-long-profile-name-that-truncates-1111", LinuxUser: "very-long-profile-name-that-trun"},
	}

	if len(got) != len(want) {
		t.Fatalf("got %d profiles (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("[%d] got %v, want %v", i, got[i], want[i])
		}
	}
}

// Localized built-in system accounts (Administrator, Guest, DefaultAccount in
// French, German, Spanish, Russian, Chinese, Japanese, etc.) must not become
// login-screen accounts (#197, #224).
func TestListWindowsProfilesLocalizedBuiltinsExcluded(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")
	createProfile := func(name string) {
		d := filepath.Join(users, name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "NTUSER.DAT"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Built-in accounts across locales
	createProfile("Administrateur") // French Admin
	createProfile("Invité")         // French Guest
	createProfile("Gast")           // German Guest
	createProfile("Administrador")  // Spanish Admin
	createProfile("Invitado")       // Spanish Guest
	createProfile("Администратор")  // Russian Admin
	createProfile("Гость")          // Russian Guest
	createProfile("管理员")            // Chinese Admin
	createProfile("管理者")            // Japanese Admin
	createProfile("ゲスト")            // Japanese Guest
	createProfile("Guest")          // English Guest
	createProfile("All Users")      // English Builtin

	// A real user
	createProfile("realuser")

	got, err := listProfilesIn(users, "admin", "admin")
	if err != nil {
		t.Fatal(err)
	}
	want := []ProfileAccount{
		{WindowsDir: "realuser", LinuxUser: "realuser"},
	}

	if len(got) != len(want) {
		t.Fatalf("got %v, want %v (all localized built-ins must be excluded)", got, want)
	}
	if got[0] != want[0] {
		t.Fatalf("got %v, want %v", got[0], want[0])
	}
}

func TestProfileAccountEdits(t *testing.T) {
	discovered := []ProfileAccount{{"田中", "user1"}, {"alice", "alice"}}
	edited := []ProfileAccount{{"alice", "alice"}, {"田中", "tanaka"}}
	got, err := applyProfileAccountEdits(discovered, edited, "owner")
	if err != nil || len(got) != 2 || got[1] != edited[1] {
		t.Fatalf("editable name not preserved: %v, %v", got, err)
	}
	for _, edits := range [][]ProfileAccount{
		{},
		{{"田中", "tanaka"}},
		{{"田中", "tanaka"}, {"unexpected", "alice"}},
		{{"田中", "tanaka"}, {"田中", "alice"}},
		{{"田中", "owner"}, {"alice", "alice"}},
		{{"田中", "alice"}, {"alice", "alice"}},
		{{"田中", "root"}, {"alice", "alice"}},
		{{"田中", "Not legal"}, {"alice", "alice"}},
	} {
		if _, err := applyProfileAccountEdits(discovered, edits, "owner"); err == nil {
			t.Fatalf("accepted unsafe/incomplete mapping %v", edits)
		}
	}
	if warnings := profileAccountWarnings(discovered); len(warnings) != 1 {
		t.Fatalf("generated mapping must have a visible warning: %v", warnings)
	}
}

func TestProfileFallbackReservesRealNames(t *testing.T) {
	users := filepath.Join(t.TempDir(), "Users")
	for _, name := range []string{"a!", "a.", "user1", "root", "田中"} {
		path := filepath.Join(users, name)
		if err := os.MkdirAll(path, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "NTUSER.DAT"), []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := listProfilesIn(users, "owner", "Owner")
	if err != nil || len(got) != 5 {
		t.Fatalf("profile omitted: %v, %v", got, err)
	}
	for _, account := range got {
		if account.WindowsDir == "user1" && account.LinuxUser != "user1" {
			t.Fatal("fallback stole an existing profile's account name")
		}
		if reservedProfileAccount(account.LinuxUser) {
			t.Fatal("system account used for a Windows profile")
		}
	}
}

func TestProfileIdentityFailsClosed(t *testing.T) {
	for _, pair := range [][2]string{{"", ""}, {"S-1-5-21-1", ""}, {"", "S-1-5-21-1"}, {"S-1-5-21-1", "S-1-5-21-2"}} {
		if err := requireMatchingProfileIdentity(pair[0], pair[1]); err == nil {
			t.Fatalf("unverified or alternative-admin identity accepted: %v", pair)
		}
	}
	if err := requireMatchingProfileIdentity("S-1-5-21-1", "S-1-5-21-1"); err != nil {
		t.Fatal(err)
	}
}
