package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wootc/internal/privatefiletest"
)

func TestReleaseSigningRoundTrip(t *testing.T) {
	dir := t.TempDir()
	seed := filepath.Join(dir, "seed")
	pub := seed + ".pub"
	manifest := filepath.Join(dir, "SHA256SUMS")
	sig := manifest + ".sig"
	if err := run([]string{"generate", seed, pub}); err != nil {
		t.Fatal(err)
	}
	privatefiletest.AssertPrivate(t, seed)
	originalSeed, err := os.ReadFile(seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"generate", seed, pub}); err == nil {
		t.Fatal("overwrote signing identity")
	}
	preservedSeed, err := os.ReadFile(seed)
	if err != nil || string(preservedSeed) != string(originalSeed) {
		t.Fatalf("refused generation changed signing identity: %v", err)
	}
	if err := os.WriteFile(manifest, []byte(strings.Repeat("f", 64)+"  deployer-vmlinuz\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"sign", seed, manifest, sig}); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"verify", pub, manifest, sig}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifest, []byte(strings.Repeat("a", 64)+"  deployer-vmlinuz\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"verify", pub, manifest, sig}); err == nil {
		t.Fatal("verified replacement manifest")
	}
}
