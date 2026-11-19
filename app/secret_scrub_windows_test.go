//go:build windows

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func openScrubObservation(t *testing.T, path string) *os.File {
	t.Helper()
	return openScrubTestHandle(t, path, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE)
}

func openScrubTestHandle(t *testing.T, path string, share uint32) *os.File {
	t.Helper()
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(name, windows.GENERIC_READ, share, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		t.Fatal(err)
	}
	return os.NewFile(uintptr(handle), path)
}

func TestScrubFilePreservesSecretWhenSharingDisallowsOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "locked-key")
	const secret = "fixture secret bytes"
	if err := os.WriteFile(path, []byte(secret), 0600); err != nil {
		t.Fatal(err)
	}
	// Unlike the zeroing observer, this handle deliberately excludes write
	// sharing: a real failed overwrite must preserve the secret for retry.
	file := openScrubTestHandle(t, path, windows.FILE_SHARE_READ|windows.FILE_SHARE_DELETE)
	defer file.Close()
	if err := scrubFile(path); !errors.Is(err, windows.ERROR_SHARING_VIOLATION) {
		t.Fatalf("expected sharing refusal, got %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != secret {
		t.Fatalf("unscrubbed secret was changed or unlinked: %q, %v", data, err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := scrubFile(path); err != nil {
		t.Fatalf("scrub retry after releasing the lock failed: %v", err)
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("retry did not remove scrubbed secret: %v", err)
	}
}
