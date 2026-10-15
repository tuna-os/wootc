package main

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Explicit build-time opt-in only. No environment or GUI field can select an
// unmeasured smaller profile. A release uses the conservative default.
var vmCapacityExperiment string

type vmStorageProfile struct {
	ID                    string
	Image                 string
	RuntimeManifestSHA256 string
	Plan                  vmStoragePlan
}

type vmStorageSelection struct {
	ProfileID             string
	RuntimeManifestSHA256 string
	Plan                  vmStoragePlan
	Minimums              vmStorageMinimums
}

// Entries require an immutable image, exact signed runtime closure and recorded
// capacity evidence. Leave empty until the experiment has passed its gates.
func approvedVMStorageProfiles() []vmStorageProfile { return nil }

func canonicalSHA256(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32 && value == strings.ToLower(value)
}

func selectVMStorageProfile(experimentID, image, runtimeManifestSHA256 string, minimums vmStorageMinimums, profiles []vmStorageProfile) (vmStorageSelection, error) {
	host, repo, digest, err := registryRef(image)
	if err != nil || host == "" || repo == "" || !strings.Contains(image, "@sha256:") || strings.ContainsAny(image, " \t\r\n?#\\") || strings.HasPrefix(repo, "/") || !strings.HasPrefix(digest, "sha256:") || !canonicalSHA256(strings.TrimPrefix(digest, "sha256:")) {
		return vmStorageSelection{}, fmt.Errorf("VM storage selection requires an immutable SHA-256 image reference")
	}
	if !canonicalSHA256(runtimeManifestSHA256) {
		return vmStorageSelection{}, fmt.Errorf("VM storage selection requires an authenticated runtime manifest identity")
	}
	selection := vmStorageSelection{ProfileID: "conservative-40-40", RuntimeManifestSHA256: runtimeManifestSHA256, Plan: defaultVMStoragePlan(), Minimums: minimums}
	if experimentID != "" {
		found := false
		for _, profile := range profiles {
			if profile.ID != experimentID {
				continue
			}
			if found {
				return vmStorageSelection{}, fmt.Errorf("ambiguous VM capacity experiment")
			}
			found = true
			if profile.Image != image || profile.RuntimeManifestSHA256 != runtimeManifestSHA256 {
				return vmStorageSelection{}, fmt.Errorf("this VM capacity experiment is not approved for the selected image and runtime")
			}
			selection.ProfileID = profile.ID
			selection.Plan = profile.Plan
		}
		if !found {
			return vmStorageSelection{}, fmt.Errorf("unknown or unapproved VM capacity experiment")
		}
	}
	if _, err := selection.Plan.requiredFree(minimums); err != nil {
		return vmStorageSelection{}, err
	}
	return selection, nil
}
