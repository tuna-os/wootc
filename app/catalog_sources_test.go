package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"
)

const catalogTestSource = `{
  "version": 1,
  "images": [{"name":"Bluefin","image":"ghcr.io/projectbluefin/bluefin:stable","backend":"ostree","published":true}],
  "families": [{"name":"Yellowfin","repository":"ghcr.io/tuna-os/yellowfin","backend":"ostree","desktops":["gnome","xfce"],"suffixes":["","-hwe"]}]
}`

const catalogTestPolicy = `[{"id":"bluefin","name":"Bluefin local presentation","bootloader":"grub2","status":"experimental","mokEnroll":"universalblue","source":{"image":"Bluefin"}}]`

func TestReviewedCatalogMatchesGeneratedConsumerArtifact(t *testing.T) {
	got, err := resolveReviewedCatalog(catalogSourcesJSON, catalogPolicyJSON)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile("data/images.json")
	if err != nil {
		t.Fatal(err)
	}
	var generated []Image
	if err := json.Unmarshal(data, &generated); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, generated) {
		t.Fatal("Go resolution differs from generated packaging/E2E catalog; run python3 app/catalog_sync.py and review")
	}
	// This intentionally pins wootc evidence, not upstream publication. A pin
	// update must not silently promote entries or add new products (e.g. LTS).
	wantStatuses := map[string]string{
		"bluefin": "green", "dakota": "green", "yellowfin-gnome": "green",
		"yellowfin-kde": "experimental", "bonito-gnome": "green", "bonito-kde": "experimental",
		"yellowfin-xfce": "experimental", "bonito-xfce": "experimental", "bonito-niri": "experimental",
		"marlin-niri": "experimental", "marlin-gnome": "experimental", "aurora": "green",
		"bazzite": "green", "bazzite-deck": "experimental", "flounder-gnome": "experimental",
	}
	if len(got) != len(wantStatuses) {
		t.Fatalf("catalog membership changed without wootc policy review: %d", len(got))
	}
	for _, image := range got {
		if image.Status != wantStatuses[image.ID] {
			t.Errorf("%s status = %q, want %q", image.ID, image.Status, wantStatuses[image.ID])
		}
		if image.ID == "dakota" && (image.ImageRef != "ghcr.io/projectbluefin/dakota:stable" || !image.ComposeFS || image.Bootloader != "systemd-boot") {
			t.Fatalf("Dakota reviewed identity/stack changed: %+v", image)
		}
	}
}

func TestReviewedCatalogSnapshotProvenance(t *testing.T) {
	data, err := os.ReadFile("data/catalog-provenance.json")
	if err != nil {
		t.Fatal(err)
	}
	var provenance struct {
		Repository string `json:"repository"`
		Revision   string `json:"revision"`
		Path       string `json:"path"`
		SHA256     string `json:"sha256"`
	}
	if err := decodeReviewedCatalog(data, &provenance); err != nil {
		t.Fatal(err)
	}
	commit, err := hex.DecodeString(provenance.Revision)
	if err != nil || len(commit) != 20 || provenance.Repository != "https://github.com/tuna-os/bootc-migrate" || provenance.Path != "catalog/sources.json" {
		t.Fatalf("invalid immutable source provenance: %+v", provenance)
	}
	digest := sha256.Sum256(catalogSourcesJSON)
	if provenance.SHA256 != hex.EncodeToString(digest[:]) {
		t.Fatal("embedded source bytes drifted from the reviewed provenance")
	}
}

func TestReviewedCatalogConsumesCanonicalIdentityWithoutPromotingPublication(t *testing.T) {
	for _, published := range []string{"true", "false"} {
		source := strings.Replace(catalogTestSource, `"published":true`, `"published":`+published, 1)
		source = strings.Replace(source, "bluefin:stable", "bluefin:reviewed-next", 1)
		got, err := resolveReviewedCatalog([]byte(source), []byte(catalogTestPolicy))
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 1 || got[0].ImageRef != "ghcr.io/projectbluefin/bluefin:reviewed-next" || got[0].Status != "experimental" || got[0].Name != "Bluefin local presentation" || got[0].MokEnroll != "universalblue" || got[0].ComposeFS {
			t.Fatalf("canonical identity or local policy lost: %+v", got)
		}
	}
}

func TestReviewedCatalogExpandsOnlySelectedReviewedFamilyTags(t *testing.T) {
	policy := `[{"id":"yellowfin-xfce","name":"Yellowfin","bootloader":"grub2","status":"experimental","source":{"family":"Yellowfin","desktop":"xfce","suffix":"-hwe"}}]`
	got, err := resolveReviewedCatalog([]byte(catalogTestSource), []byte(policy))
	if err != nil || len(got) != 1 || got[0].ImageRef != "ghcr.io/tuna-os/yellowfin:xfce-hwe" || got[0].ComposeFS || got[0].Status != "experimental" {
		t.Fatalf("family selection: %+v, %v", got, err)
	}
	for _, bad := range []string{
		strings.Replace(policy, `"xfce"`, `"unreviewed"`, 1),
		strings.Replace(policy, `"-hwe"`, `"-unreviewed"`, 1),
	} {
		if _, err := resolveReviewedCatalog([]byte(catalogTestSource), []byte(bad)); err == nil {
			t.Fatal("accepted a tag outside the reviewed family convention")
		}
	}
}

func TestReviewedCatalogRejectsSchemaIdentityAndBootPolicyDrift(t *testing.T) {
	for _, test := range []struct {
		name   string
		source string
		policy string
	}{
		{"unsupported-version", strings.Replace(catalogTestSource, `"version": 1`, `"version": 2`, 1), catalogTestPolicy},
		{"unreviewed-source-field", strings.Replace(catalogTestSource, `"version": 1`, `"version": 1, "bootloader":"grub2"`, 1), catalogTestPolicy},
		{"unknown-backend", strings.Replace(catalogTestSource, `"backend":"ostree"`, `"backend":"unknown"`, 1), catalogTestPolicy},
		{"changed-backend-requires-boot-review", strings.Replace(catalogTestSource, `"backend":"ostree"`, `"backend":"composefs"`, 1), catalogTestPolicy},
		{"missing-source", strings.Replace(catalogTestSource, `"name":"Bluefin"`, `"name":"Renamed"`, 1), catalogTestPolicy},
		{"duplicate-identity", catalogTestSource, strings.Replace(catalogTestPolicy, `"id":"bluefin"`, `"id":"bluefin","imageRef":"ghcr.io/projectbluefin/bluefin:stable"`, 1)},
		{"duplicate-backend-even-false", catalogTestSource, strings.Replace(catalogTestPolicy, `"id":"bluefin"`, `"id":"bluefin","composeFs":false`, 1)},
		{"shared-local-identity", catalogTestSource, `[{"id":"x","name":"X","imageRef":"ghcr.io/projectbluefin/bluefin:stable","composeFs":false,"bootloader":"grub2"}]`},
		{"shared-family-identity", catalogTestSource, `[{"id":"x","name":"X","imageRef":"ghcr.io/tuna-os/yellowfin:xfce-hwe","composeFs":false,"bootloader":"grub2"}]`},
		{"empty-policy", catalogTestSource, `[]`},
		{"trailing-source", catalogTestSource + `{}`, catalogTestPolicy},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := resolveReviewedCatalog([]byte(test.source), []byte(test.policy)); err == nil {
				t.Fatal("accepted reviewed catalog drift")
			}
		})
	}
}

func TestReviewedCatalogRetainsLocalOnlyChoicesAndPrivateBrandOverrides(t *testing.T) {
	policy := `[{"id":"deck","name":"Deck","imageRef":"ghcr.io/ublue-os/bazzite-deck:stable","composeFs":false,"bootloader":"grub2","status":"experimental","mokEnroll":"universalblue"}]`
	got, err := resolveReviewedCatalog([]byte(catalogTestSource), []byte(policy))
	if err != nil || len(got) != 1 || got[0].ID != "deck" || got[0].MokEnroll != "universalblue" {
		t.Fatalf("local-only choice lost: %+v, %v", got, err)
	}
	// Partner catalogs still use the public Image format and may intentionally
	// supply identities/backends outside the shared reviewed-source contract.
	assets := fstest.MapFS{"branding/acme/images.json": {Data: []byte(`[{"id":"acme","name":"Acme","imageRef":"registry.example/private:release","composeFs":true,"bootloader":"custom","status":"experimental"}]`)}}
	got, err = resolveImageCatalogue(assets, "acme", Branding{Catalog: []string{"acme"}}, SupportPolicy{ExperimentalImages: true}, nil)
	if err != nil || len(got) != 1 || got[0].ImageRef != "registry.example/private:release" || got[0].Bootloader != "custom" || !got[0].ComposeFS {
		t.Fatalf("private brand override lost: %+v, %v", got, err)
	}
	got, err = resolveImageCatalogue(assets, "acme", Branding{}, SupportPolicy{}, nil)
	if err != nil || len(got) != 0 {
		t.Fatalf("private brand bypassed channel gate: %+v, %v", got, err)
	}
}

func TestReviewedCatalogCachedResultsCannotBeMutatedByCallers(t *testing.T) {
	first, err := catalogForBrand(fstest.MapFS{}, "wootc")
	if err != nil || len(first) == 0 {
		t.Fatalf("embedded catalog unavailable: %v", err)
	}
	want := first[0]
	first[0].ImageRef = "changed by caller"
	second, err := catalogForBrand(fstest.MapFS{}, "wootc")
	if err != nil || len(second) == 0 || second[0] != want {
		t.Fatalf("caller changed cached reviewed catalog: %+v, %v", second, err)
	}
}

func TestReviewedCatalogEnterpriseOverrideRemainsAuthoritative(t *testing.T) {
	asBrandBuild(t, "wootc")
	t.Setenv("WOOTC_CHANNEL", "alpha")
	if err := os.MkdirAll(wootcDir(), 0755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(wootcDir(), "images.json")
	t.Cleanup(func() { _ = os.Remove(path) })
	data := `[{"id":"enterprise","name":"Enterprise","imageRef":"registry.example/private:release","composeFs":true,"bootloader":"custom","status":"experimental"}]`
	if err := os.WriteFile(path, []byte(data), 0644); err != nil {
		t.Fatal(err)
	}
	got, err := NewApp().GetImages()
	if err != nil || len(got) != 1 || got[0].ID != "enterprise" || got[0].Bootloader != "custom" || !got[0].ComposeFS {
		t.Fatalf("trusted enterprise catalog no longer overrides shared policy: %+v, %v", got, err)
	}
}
