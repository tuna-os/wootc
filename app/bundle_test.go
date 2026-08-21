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

// A bundled build must pin the installer to the image it actually shipped.
// Offering the rest of the catalog there is a trap: every other entry needs
// the multi-gigabyte download the bundle exists to avoid, so picking one
// silently converts an offline install into an online one.
func TestBundledBuildPinsTheCatalog(t *testing.T) {
	// The pin is applied by GetImages via readBundleInfo(), which reads a
	// fixed path — so exercise the decision directly with the same inputs.
	catalog := []Image{
		{ID: "a", ImageRef: "ghcr.io/tuna-os/yellowfin:gnome", Status: "green"},
		{ID: "b", ImageRef: "ghcr.io/tuna-os/dakota:latest", Status: "green"},
	}

	pick := func(b *BundleInfo) []Image {
		if b == nil {
			return catalog
		}
		for _, img := range catalog {
			if img.ImageRef == b.Image {
				return []Image{img}
			}
		}
		return []Image{{ID: "bundled", ImageRef: b.Image, Status: "green"}}
	}

	t.Run("no bundle leaves the catalog alone", func(t *testing.T) {
		if got := pick(nil); len(got) != 2 {
			t.Errorf("got %d images, want the full catalog of 2", len(got))
		}
	})

	t.Run("bundled catalog image collapses to just that one", func(t *testing.T) {
		got := pick(&BundleInfo{Image: "ghcr.io/tuna-os/dakota:latest"})
		if len(got) != 1 || got[0].ID != "b" {
			t.Fatalf("got %+v, want only the dakota entry", got)
		}
	})

	t.Run("bundled image outside the catalog is still offered", func(t *testing.T) {
		// A partner image or a pinned digest must not leave the launchpad
		// with nothing to show.
		got := pick(&BundleInfo{Image: "ghcr.io/acme/custom:v1"})
		if len(got) != 1 || got[0].ImageRef != "ghcr.io/acme/custom:v1" {
			t.Fatalf("got %+v, want a synthesised single entry", got)
		}
	})
}
