package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScrubInstallSecrets(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "bitlocker-key.txt")
	sess := filepath.Join(dir, "slurp", "session")
	if err := os.MkdirAll(sess, 0o700); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(dir, "slurp", "session", "exports.json")
	for _, p := range []string{key, filepath.Join(sess, "chrome.enc"), filepath.Join(sess, "edge.enc"), keep} {
		if err := os.WriteFile(p, []byte("secret material"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// A symlinked envelope must be removed, not followed.
	outside := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(outside, []byte("do not touch"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(sess, "link.enc")); err != nil {
		t.Fatal(err)
	}

	if failed := scrubInstallSecrets(dir); len(failed) != 0 {
		t.Fatalf("failed: %v", failed)
	}
	for _, p := range []string{key, filepath.Join(sess, "chrome.enc"), filepath.Join(sess, "edge.enc"), filepath.Join(sess, "link.enc")} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Errorf("%s still exists", p)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("status ledger exports.json must stay: %v", err)
	}
	if b, _ := os.ReadFile(outside); string(b) != "do not touch" {
		t.Errorf("symlink target was written: %q", b)
	}
	// Idempotent: nothing left to scrub is not a failure.
	if failed := scrubInstallSecrets(dir); len(failed) != 0 {
		t.Fatalf("second run failed: %v", failed)
	}
}

func TestScrubFileZeroesBeforeRemoving(t *testing.T) {
	p := filepath.Join(t.TempDir(), "k")
	if err := os.WriteFile(p, []byte("123456"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Observe the overwritten object without preventing its removal.
	h := openScrubObservation(t, p)
	defer h.Close()
	if err := scrubFile(p); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 6)
	if _, err := h.ReadAt(buf, 0); err != nil {
		t.Fatal(err)
	}
	for _, b := range buf {
		if b != 0 {
			t.Fatalf("content not zeroed: %q", buf)
		}
	}
	if err := h.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(p); !os.IsNotExist(err) {
		t.Fatalf("scrubbed file was not removed: %v", err)
	}
}

func TestScrubFilePreservesSecretWhenOverwriteIsDenied(t *testing.T) {
	path := filepath.Join(t.TempDir(), "readonly-key")
	const secret = "fixture secret bytes"
	if err := os.WriteFile(path, []byte(secret), 0400); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(path, 0600)
	if file, err := os.OpenFile(path, os.O_WRONLY, 0); err == nil {
		file.Close()
		t.Skip("this account can bypass the read-only file permission")
	}
	if err := scrubFile(path); err == nil {
		t.Fatal("failed overwrite was reported as a successful scrub")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != secret {
		t.Fatalf("unscrubbed secret was unlinked instead of preserved for retry: %q, %v", data, err)
	}
}
