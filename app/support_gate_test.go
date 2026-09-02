package main

import "testing"

// The green-gate is the release contract (docs/RELEASING.md): alpha offers
// only proven-green images and refuses un-proven scenarios.
func TestAlphaOffersOnlyGreenImages(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "alpha")
	a := NewApp()
	imgs, err := a.GetImages()
	if err != nil {
		t.Fatalf("GetImages: %v", err)
	}
	if len(imgs) == 0 {
		t.Fatal("alpha offers no images")
	}
	for _, im := range imgs {
		if im.Status != "green" {
			t.Errorf("alpha offered a non-green image: %s (%s)", im.ImageRef, im.Status)
		}
	}
}

func TestBetaOffersExperimental(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "beta")
	a := NewApp()
	imgs, _ := a.GetImages()
	green := len(imgs)
	t.Setenv("WOOTC_CHANNEL", "alpha")
	ags, _ := a.GetImages()
	if green <= len(ags) {
		t.Errorf("beta (%d) should offer more images than alpha (%d)", green, len(ags))
	}
}

func TestBetaOffersBitLocker(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "beta")
	p := NewApp().GetSupportPolicy()
	if !p.BitLockerSupported {
		t.Errorf("beta policy must support BitLocker: %+v", p)
	}
	if !p.ExperimentalImages {
		t.Errorf("beta policy must offer experimental images: %+v", p)
	}
	if !p.CustomImageAllowed {
		t.Errorf("beta policy must allow custom images: %+v", p)
	}
}

func TestAlphaPolicyGatesScenarios(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "alpha")
	p := NewApp().GetSupportPolicy()
	if p.ExperimentalImages || p.BitLockerSupported || p.CustomImageAllowed {
		t.Errorf("alpha policy must gate every unproven axis: %+v", p)
	}
}

func TestStablePolicyOpensAllGates(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "stable")
	p := NewApp().GetSupportPolicy()
	if !p.ExperimentalImages || !p.BitLockerSupported || !p.CustomImageAllowed {
		t.Errorf("stable policy must allow all scenarios: %+v", p)
	}
}

func TestDriveModeEnablesExperimentalImages(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "alpha")
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	p := NewApp().GetSupportPolicy()
	if !p.ExperimentalImages {
		t.Errorf("E2E drive mode must enable experimental images even on alpha: %+v", p)
	}
}
