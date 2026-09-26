package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestVMStorageExperimentRequiresExactImageAndRuntime(t *testing.T) {
	image := "registry.example/test/yellowfin@sha256:" + strings.Repeat("a", 64)
	runtime := strings.Repeat("b", 64)
	minimums := vmStorageMinimums{32 << 30, 8 << 30}
	candidate := vmStorageProfile{ID: "yellowfin-32-8-trial", Image: image, RuntimeManifestSHA256: runtime, Plan: vmStoragePlan{32 << 30, 8 << 30, 8 << 30}}
	profiles := []vmStorageProfile{candidate}
	selected, err := selectVMStorageProfile(candidate.ID, image, runtime, minimums, profiles)
	if err != nil {
		t.Fatal(err)
	}
	required, err := selected.Plan.requiredFree(minimums)
	if err != nil || required != 48<<30 || selected.ProfileID != candidate.ID {
		t.Fatalf("wrong explicit plan: %+v %v", selected, err)
	}
	if err := selected.Plan.admit(minimums, 48<<30); err != nil {
		t.Fatal(err)
	}
	if err := selected.Plan.admit(minimums, (48<<30)-1); err == nil {
		t.Fatal("candidate bypasses reserve boundary")
	}
	for _, tc := range []struct {
		name, id, image, runtime string
		mins                     vmStorageMinimums
		profiles                 []vmStorageProfile
	}{
		{"tag", candidate.ID, "registry.example/test/yellowfin:latest", runtime, minimums, profiles},
		{"other digest", candidate.ID, strings.Replace(image, strings.Repeat("a", 64), strings.Repeat("c", 64), 1), runtime, minimums, profiles},
		{"other repository", candidate.ID, strings.Replace(image, "yellowfin", "different", 1), runtime, minimums, profiles},
		{"other runtime", candidate.ID, image, strings.Repeat("c", 64), minimums, profiles},
		{"missing runtime", candidate.ID, image, "", minimums, profiles},
		{"malformed runtime", candidate.ID, image, strings.Repeat("z", 64), minimums, profiles},
		{"unapproved ID", "guess", image, runtime, minimums, profiles},
		{"unapproved registry", candidate.ID, image, runtime, minimums, nil},
		{"duplicate ID", candidate.ID, image, runtime, minimums, append(profiles, candidate)},
		{"legacy scratch minimum", candidate.ID, image, runtime, vmStorageMinimums{32 << 30, 32 << 30}, profiles},
		{"16GiB scratch minimum", candidate.ID, image, runtime, vmStorageMinimums{32 << 30, 16 << 30}, profiles},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := selectVMStorageProfile(tc.id, tc.image, tc.runtime, tc.mins, tc.profiles); err == nil {
				t.Fatal("unmeasured or incompatible profile selected")
			}
		})
	}
	selected, err = selectVMStorageProfile("", image, runtime, minimums, profiles)
	if err != nil {
		t.Fatal(err)
	}
	if required, _ := selected.Plan.requiredFree(minimums); required != 88<<30 {
		t.Fatal("default profile changed")
	}
	if len(approvedVMStorageProfiles()) != 0 || vmCapacityExperiment != "" {
		t.Fatal("an unproven experiment was activated")
	}
	if _, err := selectVMStorageProfile(candidate.ID, image, runtime, minimums, approvedVMStorageProfiles()); err == nil {
		t.Fatal("production registry approved a test profile")
	}
}

func TestVMStorageSelectionSurvivesDurableState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state := VMState{InstallID: "installation-123", RunID: "run-12345", DiskPath: "root.disk", Image: "registry.example/os@sha256:" + strings.Repeat("a", 64), StorageProfile: "conservative-40-40", TargetCapacityBytes: 40 << 30, ScratchCapacityBytes: 40 << 30, RuntimeManifestSHA256: strings.Repeat("b", 64), Phase: vmPreparing}
	if err := writeVMState(path, state); err != nil {
		t.Fatal(err)
	}
	loaded, err := readVMState(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.StorageProfile != state.StorageProfile || loaded.TargetCapacityBytes != state.TargetCapacityBytes || loaded.ScratchCapacityBytes != state.ScratchCapacityBytes || loaded.RuntimeManifestSHA256 != state.RuntimeManifestSHA256 {
		t.Fatalf("lost provision profile identity: %+v", loaded)
	}
	if loaded.DesktopReady {
		t.Fatal("capacity profile became desktop evidence")
	}
}
