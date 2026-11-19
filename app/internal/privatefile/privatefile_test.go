package privatefile

import (
	"os"
	"path/filepath"
	"testing"

	"wootc/internal/privatefiletest"
)

func TestPrivateBeforeFirstWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private")
	f, err := open(path, true)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	// Inspect the actual newly created object while it is still empty, before
	// the caller can publish any confidential bytes through the returned handle.
	privatefiletest.AssertPrivate(t, path)
	st, err := f.Stat()
	if err != nil || st.Size() != 0 {
		t.Fatalf("new private file was not empty: %v, %v", st, err)
	}
	if _, err := f.Write([]byte("secret")); err != nil {
		t.Fatal(err)
	}
}

func TestWriteFileReplacesPrivateContents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private")
	if err := WriteNew(path, []byte("long original secret")); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(path, []byte("new")); err != nil {
		t.Fatal(err)
	}
	privatefiletest.AssertPrivate(t, path)
	if err := WriteNew(path, []byte("forbidden replacement")); !os.IsExist(err) {
		t.Fatalf("exclusive creation returned %v, want already exists", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "new" {
		t.Fatalf("private contents = %q, %v", data, err)
	}
}

func TestWriteReportsInvalidDestination(t *testing.T) {
	dir := t.TempDir()
	for _, path := range []string{dir, filepath.Join(dir, "missing", "private")} {
		if err := WriteFile(path, []byte("secret")); err == nil {
			t.Fatalf("accepted invalid destination %q", path)
		}
		if err := WriteNew(path, []byte("secret")); err == nil {
			t.Fatalf("exclusive creation accepted invalid destination %q", path)
		}
	}
}
