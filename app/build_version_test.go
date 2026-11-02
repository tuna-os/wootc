package main

// The title bar's version is the build's (#599 follow-up): it comes from the
// release tag stamped at link time, never from a default or a config file.

import (
	"os"
	"path/filepath"
	"testing"
)

func withReleaseTag(t *testing.T, tag string) {
	t.Helper()
	old := releaseTag
	releaseTag = tag
	t.Cleanup(func() { releaseTag = old })
}

func TestTitleBarVersionIsTheBuildVersion(t *testing.T) {
	for _, id := range []string{"wootc", "bazzite", "bluefin", "aurora", "tunaos"} {
		asBrandBuild(t, id)
		withReleaseTag(t, "v0.4.0")
		if got := effectiveBrandingAt(t.TempDir()).Version; got != "v0.4.0" {
			t.Errorf("%s build stamped v0.4.0 shows version %q", id, got)
		}
		withReleaseTag(t, "")
		if got := effectiveBrandingAt(t.TempDir()).Version; got != "dev" {
			t.Errorf("%s unstamped build shows version %q, want dev", id, got)
		}
	}
}

// A runtime overlay (C:\wootc\brand.json) re-skins the installer; it cannot
// make the title bar report a build this binary is not.
func TestOverlayCannotOverrideTheBuildVersion(t *testing.T) {
	asBrandBuild(t, "wootc")
	withReleaseTag(t, "v0.4.0")
	root := t.TempDir()
	path := filepath.Join(root, "brand.json")
	if err := os.WriteFile(path, []byte(`{"name":"Acme","version":"0.1.0"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	b := effectiveBrandingAt(root)
	if b.Name != "Acme" {
		t.Fatalf("overlay not applied: %q", b.Name)
	}
	if b.Version != "v0.4.0" {
		t.Errorf("overlay version won: %q, want the build's v0.4.0", b.Version)
	}
}
