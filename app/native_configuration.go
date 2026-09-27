package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// NativeConfigurationSnapshot is a versioned read-only observation. Catalogue
// metadata and bundle presence do not verify image contents or grant consent.
type NativeConfigurationSnapshot struct {
	SchemaVersion           int                          `json:"schemaVersion"`
	BrandID                 string                       `json:"brandId"`
	RootBinding             string                       `json:"rootBinding"`
	RootScope               string                       `json:"rootScope"`
	CatalogueSource         string                       `json:"catalogueSource"`
	CatalogueMetadataSHA256 string                       `json:"catalogueMetadataSha256"`
	PolicySource            string                       `json:"policySource"`
	Policy                  SupportPolicy                `json:"policy"`
	Branding                Branding                     `json:"branding"`
	Images                  []NativeConfigurationImage   `json:"images"`
	Defaults                NativeConfigurationDefaults  `json:"defaults"`
	Steps                   []StepDefinition             `json:"steps"`
	Bundle                  NativeConfigurationBundle    `json:"bundle"`
	StorageStatus           string                       `json:"storageStatus"`
	Storage                 []NativeConfigurationStorage `json:"storage"`
	OriginalUserCaptured    bool                         `json:"originalUserCaptured"`
	InstallAuthorized       bool                         `json:"installAuthorized"`
}

type NativeConfigurationImage struct {
	Image                  Image  `json:"image"`
	Admitted               bool   `json:"admitted"`
	AdmissionBlockedReason string `json:"admissionBlockedReason"`
	RequiresMokEnrollment  bool   `json:"requiresMokEnrollment"`
	ContentVerified        bool   `json:"contentVerified"`
}

type NativeConfigurationDefaults struct {
	DiskSizeGB  int    `json:"diskSizeGB"`
	Encryption  string `json:"encryption"`
	Bootloader  string `json:"bootloader"`
	ComposeFS   bool   `json:"composeFs"`
	WindowsLook bool   `json:"windowsLook"`
}

type NativeConfigurationBundle struct {
	State           string `json:"state"`
	ImageRef        string `json:"imageRef"`
	Digest          string `json:"digest"`
	ContentVerified bool   `json:"contentVerified"`
}

type NativeConfigurationStorage struct {
	ID                    string `json:"id"`
	DriveLetter           string `json:"driveLetter"`
	DiskGUID              string `json:"diskGuid"`
	PartitionGUID         string `json:"partitionGuid"`
	NtfsSerial            string `json:"ntfsSerial"`
	FreeBytes             int64  `json:"freeBytes"`
	MaximumRootDiskSizeGB int    `json:"maximumRootDiskSizeGB"`
}

// The caller supplies audited roots and the successful startup selection.
// Payload metadata is usable only from one unambiguous audited root; a real
// installation binds configuration to its selected root, never a C: proxy.
func readNativeConfiguration(ctx context.Context, roots []string, selectedRoot string, found bool, audit func(string) error) (NativeConfigurationSnapshot, error) {
	var snapshot NativeConfigurationSnapshot
	root := selectedRoot
	if found && root == "" {
		return snapshot, fmt.Errorf("configuration root binding missing")
	}
	candidates := map[string]map[string][]byte{}
	rootObjects := map[string]os.FileInfo{}
	for _, candidate := range roots {
		if err := ctx.Err(); err != nil {
			return snapshot, err
		}
		if info, err := os.Lstat(candidate); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return snapshot, err
		} else {
			rootObjects[candidate] = info
		}
		if err := audit(candidate); err != nil {
			return snapshot, err
		}
		files := map[string][]byte{}
		for _, name := range []string{"brand.json", "channel.txt", "images.json", "bundle/bundle.json"} {
			data, err := readBoundedStatusRecord(filepath.Join(candidate, filepath.FromSlash(name)))
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return snapshot, err
			}
			files[name] = data
		}
		candidates[candidate] = files
		if !found && len(files) != 0 {
			if root != "" {
				return snapshot, fmt.Errorf("ambiguous configuration roots")
			}
			root = candidate
		}
	}
	if found {
		if _, ok := candidates[root]; !ok {
			return snapshot, fmt.Errorf("selected configuration root disappeared")
		}
	}
	files := candidates[root]
	brand := defaultBranding()
	if embedded, ok := embeddedBranding(); ok {
		mergeBranding(&brand, embedded)
	}
	if data, ok := files["brand.json"]; ok {
		var override Branding
		if err := decodeNativeMetadataObject(data, &override, nil); err != nil {
			return snapshot, err
		}
		mergeBranding(&brand, override)
	}
	channel, policySource := os.Getenv("WOOTC_CHANNEL"), "environment"
	if channel == "" {
		channel, policySource = "alpha", "default"
		if data, ok := files["channel.txt"]; ok {
			channel, policySource = strings.TrimSpace(string(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}))), "trusted-root"
		}
	}
	if channel != "alpha" && channel != "beta" && channel != "stable" {
		return snapshot, fmt.Errorf("unsupported configuration channel")
	}
	policy := supportPolicyFor(channel, brand, os.Getenv("WOOTC_E2E_DRIVE") == "1")
	catalogue, err := resolveImageCatalogue(brandFS, brandID, brand, policy, nil)
	if err != nil {
		return snapshot, err
	}
	catalogueSource := "embedded"
	if data, ok := files["images.json"]; ok {
		catalogue, err = decodeNativeImageCatalogue(data)
		if err != nil {
			return snapshot, err
		}
		catalogueSource = "trusted-root"
	}
	if len(catalogue) == 0 || len(catalogue) > 256 {
		return snapshot, fmt.Errorf("configuration catalogue unavailable")
	}
	ids, refs := map[string]bool{}, map[string]bool{}
	var images []NativeConfigurationImage
	for _, image := range catalogue {
		if image.ID == "" || image.Name == "" || image.ImageRef == "" || ids[image.ID] || refs[image.ImageRef] || len(image.MokEnroll) > 32 {
			return snapshot, fmt.Errorf("ambiguous configuration image")
		}
		if image.Status == "" {
			image.Status = "experimental"
		}
		if image.Status != "green" && image.Status != "experimental" {
			return snapshot, fmt.Errorf("unsupported catalogue status")
		}
		ids[image.ID], refs[image.ImageRef] = true, true
		admitted, reason := nativeImageAdmission(image, brand, policy)
		images = append(images, NativeConfigurationImage{Image: image, Admitted: admitted, AdmissionBlockedReason: reason, RequiresMokEnrollment: image.MokEnroll != ""})
	}
	bundle := NativeConfigurationBundle{State: "absent"}
	if data, ok := files["bundle/bundle.json"]; ok {
		var metadata BundleInfo
		if err := decodeNativeMetadataObject(data, &metadata, []string{"image", "digest", "storeBytes", "createdAt"}); err != nil {
			return snapshot, err
		}
		if !refs[metadata.Image] || !strings.HasPrefix(metadata.Digest, "sha256:") || len(metadata.Digest) != 71 || metadata.StoreBytes < 0 {
			return snapshot, fmt.Errorf("bundle metadata does not bind an offered image")
		}
		if _, err := hex.DecodeString(strings.TrimPrefix(metadata.Digest, "sha256:")); err != nil {
			return snapshot, fmt.Errorf("bundle digest invalid")
		}
		bundle = NativeConfigurationBundle{State: "metadata-only", ImageRef: metadata.Image, Digest: metadata.Digest}
	}
	// Re-observe presence as well as contents across every candidate root.
	// Newly created metadata cannot silently replace an embedded fallback.
	for _, candidate := range roots {
		if err := ctx.Err(); err != nil {
			return snapshot, err
		}
		original, existed := candidates[candidate]
		_, statErr := os.Lstat(candidate)
		if os.IsNotExist(statErr) {
			if existed {
				return snapshot, fmt.Errorf("configuration root disappeared")
			}
			continue
		}
		if statErr != nil {
			return snapshot, statErr
		}
		if !existed {
			return snapshot, fmt.Errorf("configuration root appeared")
		}
		if err := audit(candidate); err != nil {
			return snapshot, err
		}
		for _, name := range []string{"brand.json", "channel.txt", "images.json", "bundle/bundle.json"} {
			expected, present := original[name]
			current, err := readBoundedStatusRecord(filepath.Join(candidate, filepath.FromSlash(name)))
			if os.IsNotExist(err) && !present {
				continue
			}
			if err != nil || !present || !bytes.Equal(current, expected) {
				return snapshot, fmt.Errorf("configuration metadata changed")
			}
		}

		after, err := os.Lstat(candidate)
		if err != nil || !os.SameFile(rootObjects[candidate], after) {
			return snapshot, fmt.Errorf("configuration root identity changed")
		}
	}
	encoded, err := json.Marshal(images)
	if err != nil {
		return snapshot, err
	}
	sum := sha256.Sum256(encoded)
	scope, binding := "none", ""
	if root != "" {
		scope = "payload"
		if found {
			scope = "installation"
		}
		rootHash := sha256.Sum256([]byte(root))
		binding = hex.EncodeToString(rootHash[:])
	}
	return NativeConfigurationSnapshot{SchemaVersion: 1, BrandID: brandID, RootBinding: binding, RootScope: scope,
		CatalogueSource: catalogueSource, CatalogueMetadataSHA256: hex.EncodeToString(sum[:]), PolicySource: policySource,
		Policy: policy, Branding: brand, Images: images, Defaults: NativeConfigurationDefaults{DiskSizeGB: 40, Encryption: "tpm2-luks", Bootloader: "auto"},
		Steps: InstallerSteps(), Bundle: bundle, StorageStatus: "not-observed", Storage: []NativeConfigurationStorage{}}, nil
}

func decodeNativeImageCatalogue(data []byte) ([]Image, error) {
	var rows []json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})))
	if err := decoder.Decode(&rows); err != nil {
		return nil, err
	}
	if len(rows) == 0 || len(rows) > 256 {
		return nil, fmt.Errorf("invalid override catalogue")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("trailing catalogue data")
	}
	images := make([]Image, len(rows))
	for i, row := range rows {
		if err := decodeNativeMetadataObject(row, &images[i], []string{"id", "name", "imageRef"}); err != nil {
			return nil, err
		}
	}
	return images, nil
}

func decodeNativeMetadataObject(data []byte, target any, required []string) error {
	value := reflect.ValueOf(target).Elem()
	fields := map[string]reflect.Type{}
	for i := 0; i < value.Type().NumField(); i++ {
		field := value.Type().Field(i)
		name := strings.Split(field.Tag.Get("json"), ",")[0]
		fields[name] = field.Type
	}
	decoder := json.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return fmt.Errorf("metadata must be an object")
	}
	seen := map[string]bool{}
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		kind, known := fields[key]
		if err != nil || !ok || !known || seen[key] {
			return fmt.Errorf("ambiguous metadata field")
		}
		seen[key] = true
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return err
		}
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("null metadata field")
		}
		if err := json.Unmarshal(raw, reflect.New(kind).Interface()); err != nil {
			return err
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("trailing metadata data")
	}
	for _, key := range required {
		if !seen[key] {
			return fmt.Errorf("missing metadata field")
		}
	}
	return json.Unmarshal(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}), target)
}

func nativeImageAdmission(image Image, brand Branding, policy SupportPolicy) (bool, string) {
	if _, _, _, err := registryRef(image.ImageRef); err != nil || strings.ContainsAny(image.ImageRef, " \t\r\n") {
		return false, "This image reference is not supported."
	}
	if len(brand.Catalog) != 0 {
		included := false
		for _, id := range brand.Catalog {
			if id == image.ID {
				included = true
				break
			}
		}
		if !included {
			return false, "This variant is not included in this installer."
		}
	}
	if !policy.ExperimentalImages && image.Status != "green" {
		return false, "This variant is not supported in this release channel."
	}
	return true, ""
}
