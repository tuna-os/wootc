package main

import "testing"

// Universal Blue images that ship akmods-signed modules need the ublue MOK
// key under Secure Boot, whether or not their kernel does (#248). Bluefin and
// Aurora boot a Fedora-signed kernel, but run 39886118219 (bluefin:stable)
// showed lockdown refusing v4l2loopback ("Loading of module with unavailable
// key is rejected") because the catalog left them without mokEnroll. Each
// image here was checked in its registry layers for
// /etc/pki/akmods/certs/akmods-ublue.der; images without that cert must not
// be handed a firmware prompt.
func TestCatalogMokEnrollment_FollowsTheImagesAkmodsKey(t *testing.T) {
	needs := map[string]bool{
		"bluefin":      true,
		"aurora":       true,
		"bazzite":      true,
		"bazzite-deck": true,
	}
	// Every brand build resolves imageNeedsMok against its own catalog; none
	// of them may disagree with the image about its key.
	for _, brand := range []string{"wootc", "tunaos", "bluefin", "aurora", "bazzite"} {
		catalog, err := catalogForBrand(brandFS, brand)
		if err != nil {
			t.Fatalf("%s: catalog: %v", brand, err)
		}
		old := brandID
		brandID = brand
		for _, img := range catalog {
			want := needs[img.ID]
			if want && img.MokEnroll != "universalblue" {
				t.Errorf("%s: %s mokEnroll = %q, want universalblue (the image ships akmods-ublue.der)", brand, img.ID, img.MokEnroll)
			}
			if !want && img.MokEnroll != "" {
				t.Errorf("%s: %s mokEnroll = %q, want none (no akmods cert in the image)", brand, img.ID, img.MokEnroll)
			}
			if got := imageNeedsMok(img.ImageRef); got != want {
				t.Errorf("%s: imageNeedsMok(%s) = %v, want %v", brand, img.ImageRef, got, want)
			}
		}
		brandID = old
	}
}
