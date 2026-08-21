package main

import (
	"os"
	"path/filepath"
	"testing"
)

// readBundleInfo must be conservative: a half-staged bundle that claims an
// image whose store never arrived would make the deployer skip the pull and
// then find nothing to install. Every failure mode has to read as "no bundle"
// so the install falls back to the network and still completes.
func TestReadBundleInfo(t *testing.T) {
	write := func(t *testing.T, jsonBody string, withStore bool) string {
		t.Helper()
		dir := filepath.Join(t.TempDir(), "bundle")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if jsonBody != "" {
			if err := os.WriteFile(filepath.Join(dir, "bundle.json"), []byte(jsonBody), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if withStore {
			if err := os.MkdirAll(filepath.Join(dir, "store"), 0o755); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}

	good := `{"image":"ghcr.io/tuna-os/dakota:latest","digest":"sha256:abc","storeBytes":123}`

	t.Run("complete bundle is accepted", func(t *testing.T) {
		b := readBundleInfoAt(write(t, good, true))
		if b == nil {
			t.Fatal("got nil, want a bundle")
		}
		if b.Image != "ghcr.io/tuna-os/dakota:latest" || b.Digest != "sha256:abc" {
			t.Errorf("unexpected contents: %+v", b)
		}
	})

	t.Run("manifest without a store is rejected", func(t *testing.T) {
		if b := readBundleInfoAt(write(t, good, false)); b != nil {
			t.Errorf("got %+v, want nil — the payload never arrived", b)
		}
	})

	t.Run("store without a manifest is rejected", func(t *testing.T) {
		if b := readBundleInfoAt(write(t, "", true)); b != nil {
			t.Errorf("got %+v, want nil", b)
		}
	})

	t.Run("malformed json is rejected", func(t *testing.T) {
		if b := readBundleInfoAt(write(t, `{"image":`, true)); b != nil {
			t.Errorf("got %+v, want nil", b)
		}
	})

	t.Run("empty image is rejected", func(t *testing.T) {
		if b := readBundleInfoAt(write(t, `{"image":"","digest":"sha256:abc"}`, true)); b != nil {
			t.Errorf("got %+v, want nil — an unnamed image cannot be matched", b)
		}
	})

	t.Run("no bundle at all", func(t *testing.T) {
		if b := readBundleInfoAt(t.TempDir()); b != nil {
			t.Errorf("got %+v, want nil", b)
		}
	})
}
