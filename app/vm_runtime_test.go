package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"wootc/internal/artifactauth"
)

func TestVMRuntimeRequiresCompleteSignedClosure(t *testing.T) {
	pub, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	key := hex.EncodeToString(pub)
	content := []byte("trusted-runtime")
	manifest := []byte(fmt.Sprintf("%x  qemu-system-x86_64.exe\n%x  required.dll\n", sha256.Sum256(content), sha256.Sum256(content)))
	for name, data := range map[string][]byte{"qemu-system-x86_64.exe": content, "required.dll": content, "SHA256SUMS": manifest, "SHA256SUMS.sig": artifactauth.Sign(private, manifest)} {
		if err := os.WriteFile(filepath.Join(root, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := verifyVMRuntime(root, key); err != nil {
		t.Fatal(err)
	}
	extra := filepath.Join(root, "ambient.dll")
	if err := os.WriteFile(extra, []byte("unsigned"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyVMRuntime(root, key); err == nil {
		t.Fatal("unsigned DLL accepted")
	}
	os.Remove(extra)
	os.WriteFile(filepath.Join(root, "qemu-system-x86_64.exe"), []byte("replaced"), 0600)
	if err := verifyVMRuntime(root, key); err == nil {
		t.Fatal("replacement executable accepted")
	}
	os.WriteFile(filepath.Join(root, "qemu-system-x86_64.exe"), content, 0600)
	if err := os.Remove(filepath.Join(root, "required.dll")); err != nil {
		t.Fatal(err)
	}
	if err := verifyVMRuntime(root, key); err == nil {
		t.Fatal("deleted signed DLL accepted as a complete runtime")
	}
	if err := os.WriteFile(filepath.Join(root, "required.dll"), content, 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyVMRuntime(root, key); err != nil {
		t.Fatal(err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := verifyVMRuntime(root, hex.EncodeToString(other)); err == nil {
		t.Fatal("untrusted signing key accepted")
	}
}
