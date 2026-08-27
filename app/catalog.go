package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// imageNeedsMok reports whether the embedded catalog requires MOK enrollment.
func imageNeedsMok(ref string) bool {
	var catalog []Image
	if json.Unmarshal(catalogJSON, &catalog) != nil {
		return false
	}
	for _, img := range catalog {
		if img.ImageRef == ref {
			return img.MokEnroll != ""
		}
	}
	return false
}

// GetImages resolves enterprise overrides, offline bundles, branding, and the
// active release-channel gate into the catalog exposed through Wails.
func (a *App) GetImages() ([]Image, error) {
	custom := filepath.Join(wootcDir(), "images.json")
	if data, err := os.ReadFile(custom); err == nil {
		var override []Image
		if json.Unmarshal(data, &override) == nil && len(override) > 0 {
			return override, nil
		}
	}

	var catalog []Image
	if err := json.Unmarshal(catalogJSON, &catalog); err != nil {
		return nil, fmt.Errorf("parse embedded catalog: %w", err)
	}

	if b := readBundleInfo(); b != nil && b.Source != "predownload" {
		for _, img := range catalog {
			if img.ImageRef == b.Image {
				return []Image{img}, nil
			}
		}
		return []Image{{
			ID: "bundled", Name: "Included with this installer", Emoji: "📦",
			ImageRef: b.Image, Status: "green",
			Description: "Shipped with wootc — no download needed.",
			Bootloader:  "auto",
		}}, nil
	}

	if picked := brandCatalogImages(catalog, effectiveBranding().Catalog); len(picked) > 0 {
		return picked, nil
	}
	if a.GetSupportPolicy().ExperimentalImages {
		return catalog, nil
	}
	green := catalog[:0]
	for _, img := range catalog {
		if img.Status == "green" {
			green = append(green, img)
		}
	}
	return green, nil
}

// brandCatalogImages preserves the configured brand order and skips stale IDs.
func brandCatalogImages(catalog []Image, ids []string) []Image {
	if len(ids) == 0 {
		return nil
	}
	byID := make(map[string]Image, len(catalog))
	for _, img := range catalog {
		byID[img.ID] = img
	}
	picked := make([]Image, 0, len(ids))
	for _, id := range ids {
		if img, ok := byID[id]; ok {
			picked = append(picked, img)
		}
	}
	return picked
}
