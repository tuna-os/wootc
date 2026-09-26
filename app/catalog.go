package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// imageNeedsMok reports whether the embedded catalog requires MOK enrollment.
func imageNeedsMok(ref string) bool {
	catalog, err := catalogForBrand(brandFS, brandID)
	if err != nil {
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

	catalog, err := catalogForBrand(brandFS, brandID)
	if err != nil {
		return nil, err
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
			Description: "Included with this installer — no download needed.",
			Bootloader:  "auto",
		}}, nil
	}

	if ids := effectiveBranding().Catalog; len(ids) > 0 {
		catalog = brandCatalogImages(catalog, ids)
		if len(catalog) == 0 {
			return nil, fmt.Errorf("brand catalog contains no known images")
		}
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

// A distro may embed its catalog beside its brand without editing the shared
// upstream catalog. A malformed override must not fall back to another distro.
func catalogForBrand(assets fs.FS, id string) ([]Image, error) {
	data, err := fs.ReadFile(assets, "branding/"+id+"/images.json")
	if errors.Is(err, fs.ErrNotExist) {
		data = catalogJSON
	} else if err != nil {
		return nil, err
	}
	var catalog []Image
	if err := json.Unmarshal(data, &catalog); err != nil {
		return nil, fmt.Errorf("parse brand catalog: %w", err)
	}
	if len(catalog) == 0 {
		return nil, fmt.Errorf("brand catalog is empty")
	}
	return catalog, nil
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
