package main

import (
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"
)

func TestBrandMetadataOverlay(t *testing.T) {
	base := defaultBranding()
	overlay := Branding{Publisher: "Acme", Copyright: "Acme 2026", FileDescription: "Acme Setup", WebsiteURL: "https://example.com", SupportURL: "https://example.com/help"}
	mergeBranding(&base, overlay)
	if base.Publisher != overlay.Publisher || base.Copyright != overlay.Copyright || base.FileDescription != overlay.FileDescription || base.WebsiteURL != overlay.WebsiteURL || base.SupportURL != overlay.SupportURL {
		t.Fatalf("metadata lost: %+v", base)
	}
	for _, bad := range []string{"javascript:alert(1)", "file:///etc/passwd", "http://example.com", "https://user:pass@example.com", "https:///no-host"} {
		if safeBrandURL(bad) != "" {
			t.Errorf("unsafe link accepted: %s", bad)
		}
	}
	if safeBrandURL(overlay.SupportURL) != overlay.SupportURL {
		t.Fatal("valid support URL rejected")
	}
}

func TestBrandLocalCatalog(t *testing.T) {
	assets := fstest.MapFS{"branding/acme/images.json": {Data: []byte(`[{"id":"acme","name":"Acme","imageRef":"registry.example/acme:stable","status":"experimental"}]`)}}
	images, err := catalogForBrand(assets, "acme")
	if err != nil || len(images) != 1 || images[0].ID != "acme" {
		t.Fatalf("local catalog not used: %v %v", images, err)
	}
	assets["branding/acme/images.json"].Data = []byte(`{broken`)
	if _, err := catalogForBrand(assets, "acme"); err == nil {
		t.Fatal("malformed local catalog fell back to upstream")
	}
	assets["branding/acme/images.json"].Data = []byte(`[]`)
	if _, err := catalogForBrand(assets, "acme"); err == nil {
		t.Fatal("empty local catalog fell back to upstream")
	}
	if images, err := catalogForBrand(assets, "wootc"); err != nil || len(images) == 0 {
		t.Fatalf("shared catalog unavailable: %v", err)
	}
}

func TestBrandSelectionStillHonorsChannel(t *testing.T) {
	// Exercise GetImages, not just the selection helper. Branding must not
	// promote an experimental image by returning before the channel gate.
	dir := wootcDir()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "brand.json")
	old, readErr := os.ReadFile(path)
	t.Cleanup(func() {
		if readErr == nil {
			_ = os.WriteFile(path, old, 0644)
		} else {
			_ = os.Remove(path)
		}
	})
	images, err := catalogForBrand(brandFS, "wootc")
	if err != nil {
		t.Fatal(err)
	}
	var candidate Image
	for _, img := range images {
		if img.Status != "green" {
			candidate = img
			break
		}
	}
	if candidate.ID == "" {
		t.Skip("catalog has no experimental image")
	}
	if err := os.WriteFile(path, []byte(`{"catalog":["`+candidate.ID+`"]}`), 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WOOTC_CHANNEL", "alpha")
	got, err := NewApp().GetImages()
	if err != nil || len(got) != 0 {
		t.Fatalf("alpha exposed brand's experimental image: %v %v", got, err)
	}
	t.Setenv("WOOTC_CHANNEL", "beta")
	got, err = NewApp().GetImages()
	if err != nil || len(got) != 1 || got[0].ID != candidate.ID {
		t.Fatalf("beta lost configured image: %v %v", got, err)
	}
}
