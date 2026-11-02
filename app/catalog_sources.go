package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
)

// This is an exact reviewed upstream sources.json, not the registry-probed
// catalog-feed. catalog-provenance.json records its immutable revision and hash.
// Update with: python3 app/catalog_sync.py --revision <full-reviewed-commit>
//
//go:embed data/catalog-sources.json
var catalogSourcesJSON []byte

var embeddedCatalog, embeddedCatalogErr = resolveReviewedCatalog(catalogSourcesJSON, catalogPolicyJSON)

type reviewedCatalogSource struct {
	Version  int                     `json:"version"`
	Images   []reviewedCatalogImage  `json:"images"`
	Families []reviewedCatalogFamily `json:"families"`
}

type reviewedCatalogImage struct {
	Name      string `json:"name"`
	Image     string `json:"image"`
	Backend   string `json:"backend"`
	Published *bool  `json:"published"`
}

type reviewedCatalogFamily struct {
	Name       string   `json:"name"`
	Repository string   `json:"repository"`
	Backend    string   `json:"backend"`
	Desktops   []string `json:"desktops"`
	Suffixes   []string `json:"suffixes"`
}

type catalogSourceSelector struct {
	Image   string `json:"image,omitempty"`
	Family  string `json:"family,omitempty"`
	Desktop string `json:"desktop,omitempty"`
	Suffix  string `json:"suffix,omitempty"`
}

type reviewedCatalogPolicy struct {
	Image
	Source *catalogSourceSelector `json:"source,omitempty"`
	// Pointers distinguish explicit local fields from omitted ones. Shared
	// images must not carry second, potentially drifting identity/backend fields.
	LocalImageRef  *string `json:"imageRef,omitempty"`
	LocalComposeFS *bool   `json:"composeFs,omitempty"`
}

type catalogSourceIndex struct {
	images   map[string]reviewedCatalogImage
	families map[string]reviewedCatalogFamily
	refs     map[string]string
}

var reviewedCatalogReference = regexp.MustCompile(`^ghcr\.io/[A-Za-z0-9._/:-]+$`)

func validReviewedCatalogReference(ref string) bool {
	return len(ref) <= 200 && reviewedCatalogReference.MatchString(ref)
}

func decodeReviewedCatalog(data []byte, into any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("expected one JSON value")
	}
	return nil
}

func indexReviewedCatalog(data []byte) (catalogSourceIndex, error) {
	var source reviewedCatalogSource
	index := catalogSourceIndex{
		images:   make(map[string]reviewedCatalogImage),
		families: make(map[string]reviewedCatalogFamily),
		refs:     make(map[string]string),
	}
	if err := decodeReviewedCatalog(data, &source); err != nil {
		return index, fmt.Errorf("parse reviewed catalog source: %w", err)
	}
	if source.Version != 1 {
		return index, fmt.Errorf("unsupported catalog source version %d", source.Version)
	}
	if len(source.Images) == 0 || len(source.Images) > 512 {
		return index, fmt.Errorf("invalid reviewed catalog image count")
	}
	addRef := func(ref, backend string) error {
		if !validReviewedCatalogReference(ref) {
			return fmt.Errorf("invalid reviewed image reference %q", ref)
		}
		if previous, exists := index.refs[ref]; exists && previous != backend {
			return fmt.Errorf("conflicting reviewed backends for %q", ref)
		}
		index.refs[ref] = backend
		return nil
	}
	for _, image := range source.Images {
		_, duplicate := index.images[image.Name]
		if image.Name == "" || duplicate || image.Published == nil || !reviewedCatalogBackend(image.Backend) {
			return index, fmt.Errorf("invalid or duplicate reviewed image %q", image.Name)
		}
		if image.Image != "" {
			if _, exists := index.refs[image.Image]; exists {
				return index, fmt.Errorf("duplicate reviewed image reference %q", image.Image)
			}
			if err := addRef(image.Image, image.Backend); err != nil {
				return index, err
			}
		} else if *image.Published {
			return index, fmt.Errorf("published reviewed image %q has no reference", image.Name)
		}
		index.images[image.Name] = image
	}
	for _, family := range source.Families {
		_, duplicate := index.families[family.Name]
		if family.Name == "" || duplicate || !reviewedCatalogBackend(family.Backend) || len(family.Desktops) == 0 || len(family.Suffixes) == 0 {
			return index, fmt.Errorf("invalid or duplicate reviewed family %q", family.Name)
		}
		for _, desktop := range family.Desktops {
			if desktop == "" {
				return index, fmt.Errorf("empty desktop in reviewed family %q", family.Name)
			}
			for _, suffix := range family.Suffixes {
				if err := addRef(family.Repository+":"+desktop+suffix, family.Backend); err != nil {
					return index, err
				}
			}
		}
		index.families[family.Name] = family
	}
	if len(index.refs) > 512 {
		return index, fmt.Errorf("reviewed catalog is too large")
	}
	return index, nil
}

func reviewedCatalogBackend(backend string) bool {
	return backend == "ostree" || backend == "composefs"
}

func (index catalogSourceIndex) resolve(selector catalogSourceSelector) (string, string, error) {
	if selector.Image != "" {
		if selector.Family != "" || selector.Desktop != "" || selector.Suffix != "" {
			return "", "", fmt.Errorf("mixed primary and family source selector")
		}
		image, exists := index.images[selector.Image]
		if !exists || image.Image == "" {
			return "", "", fmt.Errorf("unknown reviewed image %q", selector.Image)
		}
		return image.Image, image.Backend, nil
	}
	family, exists := index.families[selector.Family]
	if !exists {
		return "", "", fmt.Errorf("unknown reviewed family %q", selector.Family)
	}
	desktopOK, suffixOK := false, false
	for _, desktop := range family.Desktops {
		desktopOK = desktopOK || desktop == selector.Desktop
	}
	for _, suffix := range family.Suffixes {
		suffixOK = suffixOK || suffix == selector.Suffix
	}
	if !desktopOK || !suffixOK {
		return "", "", fmt.Errorf("unreviewed tag in family %q", selector.Family)
	}
	return family.Repository + ":" + selector.Desktop + selector.Suffix, family.Backend, nil
}

// resolveReviewedCatalog deliberately does not import upstream publication as a
// support status, nor add every upstream choice to wootc. Only explicit local
// policy entries are offered. Upstream has no bootloader, MOK, or consumer
// support evidence: those remain independently reviewed wootc policy.
func resolveReviewedCatalog(sourceJSON, policyJSON []byte) ([]Image, error) {
	index, err := indexReviewedCatalog(sourceJSON)
	if err != nil {
		return nil, err
	}
	var policy []reviewedCatalogPolicy
	if err := decodeReviewedCatalog(policyJSON, &policy); err != nil {
		return nil, fmt.Errorf("parse wootc catalog policy: %w", err)
	}
	if len(policy) == 0 {
		return nil, fmt.Errorf("wootc catalog policy is empty")
	}
	catalog := make([]Image, 0, len(policy))
	ids, refs := make(map[string]bool, len(policy)), make(map[string]bool, len(policy))
	for _, entry := range policy {
		image := entry.Image
		if image.ID == "" || image.Name == "" || ids[image.ID] {
			return nil, fmt.Errorf("invalid or duplicate wootc catalog ID %q", image.ID)
		}
		backend := "ostree"
		if entry.Source != nil {
			if entry.LocalImageRef != nil || entry.LocalComposeFS != nil {
				return nil, fmt.Errorf("%s duplicates upstream identity or backend", image.ID)
			}
			image.ImageRef, backend, err = index.resolve(*entry.Source)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", image.ID, err)
			}
			image.ComposeFS = backend == "composefs"
		} else {
			if entry.LocalImageRef == nil || !validReviewedCatalogReference(*entry.LocalImageRef) || entry.LocalComposeFS == nil {
				return nil, fmt.Errorf("%s requires an explicit local identity and backend", image.ID)
			}
			image.ImageRef = *entry.LocalImageRef
			if _, shared := index.refs[image.ImageRef]; shared {
				return nil, fmt.Errorf("%s must select its shared upstream source", image.ID)
			}
			image.ComposeFS = *entry.LocalComposeFS
			if image.ComposeFS {
				backend = "composefs"
			}
		}
		// This is wootc's reviewed supported-stack constraint, not upstream
		// bootloader evidence. A backend change requires boot policy review.
		if (backend == "ostree" && image.Bootloader != "grub2") || (backend == "composefs" && image.Bootloader != "systemd-boot") {
			return nil, fmt.Errorf("%s: reviewed wootc bootloader %q conflicts with source backend %q", image.ID, image.Bootloader, backend)
		}
		if refs[image.ImageRef] {
			return nil, fmt.Errorf("duplicate wootc image reference %q", image.ImageRef)
		}
		ids[image.ID], refs[image.ImageRef] = true, true
		catalog = append(catalog, image)
	}
	return catalog, nil
}
