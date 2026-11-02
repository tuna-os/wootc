//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidFlatpakID(t *testing.T) {
	for _, id := range []string{"org.mozilla.firefox", "com.visualstudio.code"} {
		if !validFlatpakID(id) {
			t.Errorf("expected valid Flatpak ID %q", id)
		}
	}
	for _, id := range []string{"", "org/foo", "..", "org.example;rm"} {
		if validFlatpakID(id) {
			t.Errorf("expected invalid Flatpak ID %q", id)
		}
	}
}

func TestReadSessionConsentsFailClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-consent.json")
	if err := os.WriteFile(path, []byte(`{"chrome":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !readSessionConsents(path)["chrome"] {
		t.Fatal("expected consent to be read")
	}
	if got := readSessionConsents(filepath.Join(t.TempDir(), "missing")); len(got) != 0 {
		t.Fatalf("missing consent file = %#v", got)
	}
}

func TestReadSessionConsentsMalformedJSON(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-consent.json")
	if err := os.WriteFile(path, []byte(`not json`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := readSessionConsents(path); len(got) != 0 {
		t.Fatalf("malformed consent file = %#v, want empty map", got)
	}
}

func TestFileExists(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "present")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !fileExists(file) {
		t.Errorf("fileExists(%q) = false, want true", file)
	}
	if fileExists(filepath.Join(dir, "absent")) {
		t.Error("fileExists on a missing path = true, want false")
	}
	if !fileExists(dir) {
		t.Error("fileExists on an existing directory = false, want true (it only checks os.Stat succeeds)")
	}
}

func TestDirExists(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "present")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !dirExists(dir) {
		t.Errorf("dirExists(%q) = false, want true", dir)
	}
	if dirExists(filepath.Join(dir, "absent")) {
		t.Error("dirExists on a missing path = true, want false")
	}
	if dirExists(file) {
		t.Error("dirExists on a regular file = true, want false")
	}
}

func TestDirSize(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a"), make([]byte, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "b"), make([]byte, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := dirSize(dir); got <= 0 {
		t.Errorf("dirSize(%q) = %d, want a positive byte count", dir, got)
	}
}

func TestDirSizeMissingPath(t *testing.T) {
	if got := dirSize(filepath.Join(t.TempDir(), "does-not-exist")); got != -1 {
		t.Errorf("dirSize(missing) = %d, want -1 (du fails, UI shows \"calculating…\")", got)
	}
}

func TestReadSessionExportsFrom(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "exports.json")
	payload := `[{"app":"chrome","state":"staged","reason":"protected envelope staged; Linux app import still required"},{"app":"spotify","state":"imported","reason":"imported"}]`
	if err := os.WriteFile(path, []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	exports := readSessionExportsFrom(path)
	if len(exports) != 1 {
		t.Fatalf("expected only one staged export, got %d", len(exports))
	}
	if exports["chrome"].State != "staged" {
		t.Errorf("chrome state = %q, want staged", exports["chrome"].State)
	}
	if _, exists := exports["spotify"]; exists {
		t.Error("Windows exporter must not supply Linux imported/authentication evidence")
	}
}

func TestReadSessionExportsFromFailClosed(t *testing.T) {
	if got := readSessionExportsFrom(filepath.Join(t.TempDir(), "absent.json")); len(got) != 0 {
		t.Errorf("absent exports file = %#v, want empty map", got)
	}
	malformed := filepath.Join(t.TempDir(), "malformed.json")
	if err := os.WriteFile(malformed, []byte("bad-json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := readSessionExportsFrom(malformed); len(got) != 0 {
		t.Errorf("malformed exports file = %#v, want empty map", got)
	}
}

func TestBrowserImportRequiresCompletedNonemptyOutcome(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bridge-browser.json")
	for _, payload := range []string{
		`{}`, `{"imported":["firefox"]}`,
		`{"state":"native","imported":[]}`,
		`{"state":"failed","imported":["chrome-bookmarks"],"errors":["history failed"]}`,
		`{"state":"native","imported":["firefox"],"errors":["manual registration required"]}`,
	} {
		if err := os.WriteFile(path, []byte(payload), 0o600); err != nil {
			t.Fatal(err)
		}
		if browserImportComplete(path) {
			t.Fatalf("incomplete import promoted: %s", payload)
		}
	}
	if err := os.WriteFile(path, []byte(`{"state":"native","imported":["chrome-bookmarks"],"errors":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if !browserImportComplete(path) {
		t.Fatal("completed import not recognized")
	}
}
