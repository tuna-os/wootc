package main

// Tests for the pure branding / channel-resolution logic (defaultBranding,
// mergeBranding, previewMode, supportChannel fallbacks). These ran at 0%
// before this file: the enterprise re-skin contract (C:\wootc\brand.json
// overlay) and the channel.txt fallback are what alpha/beta/stable gating
// and partner branding depend on.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultBranding(t *testing.T) {
	b := defaultBranding()
	if b.Name == "" || b.Version == "" || b.Tagline == "" {
		t.Errorf("defaultBranding() incomplete: %+v", b)
	}
	if b.Accent == "" || b.AccentText == "" || b.Background == "" || b.Card == "" || b.Text == "" {
		t.Errorf("defaultBranding() missing color tokens: %+v", b)
	}
	if b.Accent == b.Background {
		t.Error("defaultBranding() accent and background are identical")
	}
	if b.InstallVerb == "" {
		t.Error("defaultBranding() missing install verb")
	}
}

func TestMergeBranding_OverlaysNonEmptyFields(t *testing.T) {
	base := defaultBranding()
	over := Branding{Name: "Acme", Tagline: "Acme edition", Accent: "#123456"}
	mergeBranding(&base, over)
	if base.Name != "Acme" || base.Tagline != "Acme edition" || base.Accent != "#123456" {
		t.Errorf("mergeBranding() did not overlay: %+v", base)
	}
	// Unset overlay fields must keep the base values.
	if base.Version != "0.1.0" || base.Background == "" || base.InstallVerb == "" {
		t.Errorf("mergeBranding() clobbered defaults: %+v", base)
	}
}

func TestMergeBranding_EmptyOverFieldsKeepBase(t *testing.T) {
	base := defaultBranding()
	orig := base
	over := Branding{Name: "Acme"} // everything else empty
	mergeBranding(&base, over)
	if base.Name != "Acme" {
		t.Errorf("name = %q, want Acme", base.Name)
	}
	if base.Tagline != orig.Tagline || base.Accent != orig.Accent || base.Background != orig.Background {
		t.Errorf("empty overlay fields clobbered base: %+v vs %+v", base, orig)
	}
}

func TestPreviewMode(t *testing.T) {
	t.Setenv("WOOTC_UI_PREVIEW", "")
	if previewMode() {
		t.Error("previewMode() = true without WOOTC_UI_PREVIEW")
	}
	t.Setenv("WOOTC_UI_PREVIEW", "1")
	if !previewMode() {
		t.Error("previewMode() = false with WOOTC_UI_PREVIEW=1")
	}
}

func TestSupportChannel_EnvTakesPrecedence(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "beta")
	if got := supportChannel(); got != "beta" {
		t.Errorf("supportChannel() = %q, want beta", got)
	}
}

func TestSupportChannel_FileFallbackAndDefault(t *testing.T) {
	dir := wootcDir() // dev mode: /tmp/wootc
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Skipf("cannot create %s: %v", dir, err)
	}
	path := filepath.Join(dir, "channel.txt")

	t.Setenv("WOOTC_CHANNEL", "")

	// No file → conservative alpha default.
	_ = os.Remove(path)
	if got := supportChannel(); got != "alpha" {
		t.Errorf("supportChannel() no-file = %q, want alpha", got)
	}

	// channel.txt fallback.
	if err := os.WriteFile(path, []byte("stable\n"), 0o644); err != nil {
		t.Skipf("cannot write %s: %v", path, err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	if got := supportChannel(); got != "stable" {
		t.Errorf("supportChannel() file fallback = %q, want stable", got)
	}

	// Whitespace-only file → alpha.
	if err := os.WriteFile(path, []byte("   \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := supportChannel(); got != "alpha" {
		t.Errorf("supportChannel() empty file = %q, want alpha", got)
	}
}

func TestGetBranding_OverlaysCustomFile(t *testing.T) {
	dir := wootcDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Skipf("cannot create %s: %v", dir, err)
	}
	path := filepath.Join(dir, "brand.json")
	if err := os.WriteFile(path, []byte(`{"name":"Acme","accent":"#123456"}`), 0o644); err != nil {
		t.Skipf("cannot write %s: %v", path, err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })

	a := NewApp()
	b := a.GetBranding()
	if b.Name != "Acme" || b.Accent != "#123456" {
		t.Errorf("GetBranding() = %+v, want Acme overlay", b)
	}
	// Unset fields fall back to the default.
	if b.Tagline == "" || b.Version == "" || b.Background == "" {
		t.Errorf("GetBranding() lost defaults: %+v", b)
	}
}

func TestGetBranding_MissingFileUsesDefaults(t *testing.T) {
	// Ensure no brand.json is present.
	_ = os.Remove(filepath.Join(wootcDir(), "brand.json"))
	a := NewApp()
	b := a.GetBranding()
	// Generic build: the distribution is TunaOS, the installer is wootc.
	if b.Name != "TunaOS" || b.ProductName != "wootc" {
		t.Errorf("GetBranding() = %+v, want generic TunaOS/wootc branding", b)
	}
}

// ── Brand builds (docs/branding-and-distribution.md) ─────────────────────────

// Every embedded brand config must parse and be internally consistent: its
// catalog ids must exist in images.json (a typo would blank the launchpad),
// its default must be in its catalog, and — the point of the whole system —
// a branded build must never surface the word "wootc".
func TestEmbeddedBrands_ValidAndConsistent(t *testing.T) {
	entries, err := brandFS.ReadDir("branding")
	if err != nil {
		t.Fatalf("read embedded branding dir: %v", err)
	}
	if len(entries) == 0 {
		t.Fatalf("expected at least one embedded brand entry, got %d", len(entries))
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue // README etc.
		}
		id := e.Name()
		catalog, err := catalogForBrand(brandFS, id)
		if err != nil {
			t.Fatal(err)
		}
		known := map[string]bool{}
		for _, img := range catalog {
			known[img.ID] = true
		}
		data, err := brandFS.ReadFile("branding/" + id + "/brand.json")
		if err != nil {
			t.Errorf("brand %s: missing brand.json: %v", id, err)
			continue
		}
		var b Branding
		if err := json.Unmarshal(data, &b); err != nil {
			t.Errorf("brand %s: unparseable brand.json: %v", id, err)
			continue
		}
		if b.Name == "" || b.ProductName == "" || b.ExeName == "" || b.Tagline == "" {
			t.Errorf("brand %s: identity incomplete: %+v", id, b)
		}
		for _, imgID := range b.Catalog {
			if !known[imgID] {
				t.Errorf("brand %s: catalog names unknown image %q", id, imgID)
			}
		}
		if b.DefaultImage != "" {
			found := false
			for _, imgID := range b.Catalog {
				if imgID == b.DefaultImage {
					found = true
				}
			}
			if !found {
				t.Errorf("brand %s: defaultImage %q not in its catalog", id, b.DefaultImage)
			}
		}
		if id == "wootc" {
			continue // the generic build owns the word
		}
		for field, v := range map[string]string{
			"name": b.Name, "productName": b.ProductName,
			"exeName": b.ExeName, "tagline": b.Tagline,
		} {
			if strings.Contains(strings.ToLower(v), "wootc") {
				t.Errorf("brand %s: %s %q contains 'wootc' — branded builds must not use the project name", id, field, v)
			}
		}
		if !b.HideCustomImage || !b.PreloadImage || len(b.Catalog) == 0 {
			t.Errorf("brand %s: branded builds must set catalog, hideCustomImage and preloadImage: %+v", id, b)
		}
	}
}

func TestBrandCatalogImages(t *testing.T) {
	catalog := []Image{{ID: "a"}, {ID: "b"}, {ID: "c"}}
	if got := brandCatalogImages(catalog, nil); got != nil {
		t.Errorf("empty ids should return nil, got %+v", got)
	}
	// Brand order wins, unknown ids are skipped rather than failing.
	got := brandCatalogImages(catalog, []string{"c", "nope", "a"})
	if len(got) != 2 || got[0].ID != "c" || got[1].ID != "a" {
		t.Errorf("brandCatalogImages order/skip wrong: %+v", got)
	}
}

func TestMergeBranding_DistributionFields(t *testing.T) {
	base := defaultBranding()
	over := Branding{ProductName: "Bazzite Installer", ExeName: "Bazzite-Installer",
		Catalog: []string{"bazzite"}, DefaultImage: "bazzite",
		HideCustomImage: true, PreloadImage: true}
	mergeBranding(&base, over)
	if base.ProductName != "Bazzite Installer" || base.ExeName != "Bazzite-Installer" ||
		base.DefaultImage != "bazzite" || len(base.Catalog) != 1 ||
		!base.HideCustomImage || !base.PreloadImage {
		t.Errorf("distribution fields not merged: %+v", base)
	}
	// An empty later overlay (the runtime brand.json) must not clear them.
	mergeBranding(&base, Branding{Name: "Acme"})
	if base.ProductName != "Bazzite Installer" || len(base.Catalog) != 1 || !base.HideCustomImage {
		t.Errorf("empty overlay clobbered distribution fields: %+v", base)
	}
}

// A branded build must refuse a custom OCI ref on every channel: the frontend
// hides the field, but this is the enforcement.
func TestHideCustomImage_TightensPolicy(t *testing.T) {
	old := brandID
	brandID = "bazzite"
	t.Cleanup(func() { brandID = old })
	_ = os.Remove(filepath.Join(wootcDir(), "brand.json"))
	t.Setenv("WOOTC_CHANNEL", "stable") // the loosest channel
	pol := NewApp().GetSupportPolicy()
	if pol.CustomImageAllowed {
		t.Errorf("bazzite build allows custom images on stable: %+v", pol)
	}
}
