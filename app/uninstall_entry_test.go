package main

import "testing"

// The Apps entry must not depend on the program that happened to start the
// install. A native install starts from the preview engine under Program
// Files, which the preview's uninstaller deletes (and which an upgrade of the
// preview deletes first, since preview.iss refuses an existing destination).
func TestUninstallEntryNamesTheStagedEngineNotTheStartingProgram(t *testing.T) {
	const (
		engine = `C:\Program Files\wootc Native Preview\example\bundle\wootc-engine.exe`
		staged = `C:\wootc\install\wootc.exe`
	)
	present := func(p string) bool { return p == staged }
	target := uninstallEntryTarget(staged, engine, present)
	if target != staged {
		t.Fatalf("Apps entry runs %q; want the staged copy %q that outlives the preview package", target, staged)
	}
	values := uninstallEntryValues(Branding{ProductName: "Example", Publisher: "Example Project"}, target, `C:\wootc`)
	if got, want := values["UninstallString"], `"`+staged+`" uninstall`; got != want {
		t.Fatalf("UninstallString = %q, want %q", got, want)
	}
	if values["DisplayIcon"] != staged {
		t.Fatalf("DisplayIcon = %q, want %q", values["DisplayIcon"], staged)
	}
	if values["InstallLocation"] != `C:\wootc` {
		t.Fatalf("InstallLocation = %q", values["InstallLocation"])
	}
}

func TestUninstallEntryFallsBackToTheRunningProgramWithoutAStagedCopy(t *testing.T) {
	const self = `C:\Users\me\Downloads\wootc.exe`
	none := func(string) bool { return false }
	if got := uninstallEntryTarget(`C:\wootc\install\wootc.exe`, self, none); got != self {
		t.Fatalf("got %q, want the running program %q", got, self)
	}
	if got := uninstallEntryTarget("", self, func(string) bool { return true }); got != self {
		t.Fatalf("an empty staged path must not win: got %q", got)
	}
}

// Running from the staged copy, uninstall deletes its own directory; the
// image has to move aside first or install\ survives and uninstall fails.
func TestUninstallRemovesImageWhenRunFromTheStagedCopy(t *testing.T) {
	removed := []string{`D:\wootc\install`, `C:\wootc\install`}
	cases := []struct {
		self string
		want bool
	}{
		{`C:\wootc\install\wootc.exe`, true},
		{`c:\WOOTC\Install\WOOTC.EXE`, true},
		{`D:\wootc\install\wootc.exe`, true},
		{`C:\wootc\wootc.exe`, false},
		{`C:\wootc\installer\wootc.exe`, false},
		{`C:\Program Files\wootc Native Preview\example\bundle\wootc-engine.exe`, false},
	}
	for _, c := range cases {
		if got := uninstallRemovesImage(c.self, removed); got != c.want {
			t.Errorf("uninstallRemovesImage(%q) = %v, want %v", c.self, got, c.want)
		}
	}
	if uninstallRemovesImage(`C:\wootc\install\wootc.exe`, []string{""}) {
		t.Error("an empty directory must not contain everything")
	}
}
