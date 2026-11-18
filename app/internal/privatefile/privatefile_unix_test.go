//go:build !windows

package privatefile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRefusePublicExistingFileWithoutMutation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "public")
	if err := os.WriteFile(path, []byte("existing public bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(path, []byte("secret")); err == nil {
		t.Fatal("accepted a publicly readable destination")
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o644 {
		t.Fatalf("refusal changed existing permissions: %v, %v", st, err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "existing public bytes" {
		t.Fatalf("refusal changed existing bytes: %q, %v", data, err)
	}
}

func TestRefuseSymlinkWithoutTruncatingTarget(t *testing.T) {
	dir := t.TempDir()
	target, link := filepath.Join(dir, "target"), filepath.Join(dir, "link")
	if err := WriteNew(target, []byte("existing secret")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(link, []byte("replacement")); err == nil {
		t.Fatal("followed a symlink destination")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "existing secret" {
		t.Fatalf("symlink refusal changed target bytes: %q, %v", data, err)
	}
}
