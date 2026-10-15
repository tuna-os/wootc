package main

// The title bar's version is the build's (#599 follow-up): it comes from the
// release tag stamped at link time, never from a default or a config file.

import (
	"os"
	"path/filepath"
	"testing"
)

// asBuildOf makes this test binary the -X main.brandID=<id> exe, with the
// runtime overlays that would mask the embedded brand moved aside.
func asBuildOf(t *testing.T, id string) {
	t.Helper()
	old := brandID
	brandID = id
	t.Cleanup(func() { brandID = old })
	for _, name := range []string{"brand.json", "brand.css"} {
		path := filepath.Join(wootcDir(), name)
		saved, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if err := os.Remove(path); err != nil {
			t.Fatalf("clear overlay %s: %v", path, err)
		}
		t.Cleanup(func() { _ = os.WriteFile(path, saved, 0o644) })
	}
}

func withReleaseTag(t *testing.T, tag string) {
	t.Helper()
	old := releaseTag
	releaseTag = tag
	t.Cleanup(func() { releaseTag = old })
}

func TestTitleBarVersionIsTheBuildVersion(t *testing.T) {
	for _, id := range []string{"wootc", "bazzite", "bluefin", "aurora", "tunaos"} {
		asBuildOf(t, id)
		withReleaseTag(t, "v0.4.0")
		if got := effectiveBranding().Version; got != "v0.4.0" {
			t.Errorf("%s build stamped v0.4.0 shows version %q", id, got)
		}
		withReleaseTag(t, "")
		if got := effectiveBranding().Version; got != "dev" {
			t.Errorf("%s unstamped build shows version %q, want dev", id, got)
		}
	}
}

// A runtime overlay (C:\wootc\brand.json) re-skins the installer; it cannot
// make the title bar report a build this binary is not.
func TestOverlayCannotOverrideTheBuildVersion(t *testing.T) {
	asBuildOf(t, "wootc")
	withReleaseTag(t, "v0.4.0")
	if err := os.MkdirAll(wootcDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(wootcDir(), "brand.json")
	if err := os.WriteFile(path, []byte(`{"name":"Acme","version":"0.1.0"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	b := effectiveBranding()
	if b.Name != "Acme" {
		t.Fatalf("overlay not applied: %q", b.Name)
	}
	if b.Version != "v0.4.0" {
		t.Errorf("overlay version won: %q, want the build's v0.4.0", b.Version)
	}
}
