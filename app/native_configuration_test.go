package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const nativeConfigurationExperimental = `[{"id":"private-test","name":"Experimental fixture","imageRef":"ghcr.io/tuna-os/fixture:latest","status":"experimental"}]`

func nativeConfigurationFile(t *testing.T, root, name, text string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestNativeConfigurationActualOverrideKeepsAlphaAdmissionFalse(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	t.Setenv("WOOTC_E2E_DRIVE", "")
	payload, installed := t.TempDir(), t.TempDir()
	nativeConfigurationFile(t, payload, "channel.txt", "beta")
	nativeConfigurationFile(t, installed, "channel.txt", "alpha")
	nativeConfigurationFile(t, installed, "images.json", nativeConfigurationExperimental)
	snapshot, err := readNativeConfiguration(context.Background(), []string{payload, installed}, installed, true, func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Policy.Channel != "alpha" || snapshot.Policy.ExperimentalImages || len(snapshot.Images) != 1 || snapshot.Images[0].Admitted || snapshot.Images[0].AdmissionBlockedReason == "" {
		t.Fatalf("alpha override falsely admitted: %+v", snapshot.Images)
	}
	sum := sha256.Sum256([]byte(installed))
	if snapshot.RootBinding != hex.EncodeToString(sum[:]) || snapshot.RootScope != "installation" || snapshot.CatalogueSource != "trusted-root" {
		t.Fatal("configuration did not bind selected installation root")
	}
	if snapshot.InstallAuthorized || snapshot.OriginalUserCaptured || snapshot.Images[0].ContentVerified {
		t.Fatal("metadata granted unobserved capability or integrity")
	}
}

func TestNativeConfigurationMissingRootDoesNotCreateOrAssessStorage(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	t.Setenv("WOOTC_E2E_DRIVE", "")
	root := filepath.Join(t.TempDir(), "missing")
	snapshot, err := readNativeConfiguration(context.Background(), []string{root}, "", false, func(string) error { t.Fatal("audited missing root"); return nil })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(root); !os.IsNotExist(err) {
		t.Fatal("configuration created absent root")
	}
	if snapshot.RootScope != "none" || snapshot.RootBinding != "" || snapshot.StorageStatus != "not-observed" || len(snapshot.Storage) != 0 || snapshot.Defaults.Encryption != "tpm2-luks" {
		t.Fatal("configuration invented root/storage or drifted defaults")
	}
}

func TestNativeConfigurationMalformedOverridesNeverFallBack(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	for _, data := range []string{`{}`, `null`, `[]`, `[{"id":"x","id":"y","name":"Fixture","imageRef":"ghcr.io/tuna-os/fixture:latest"}]`, `[{"id":"x","name":"Fixture","imageRef":"ghcr.io/tuna-os/fixture:latest","unknown":true}]`} {
		root := t.TempDir()
		nativeConfigurationFile(t, root, "images.json", data)
		if _, err := readNativeConfiguration(context.Background(), []string{root}, "", false, func(string) error { return nil }); err == nil {
			t.Fatal("malformed override fell back to embedded catalogue")
		}
	}
	root := t.TempDir()
	nativeConfigurationFile(t, root, "channel.txt", "unknown")
	if _, err := readNativeConfiguration(context.Background(), []string{root}, "", false, func(string) error { return nil }); err == nil {
		t.Fatal("unknown channel defaulted to alpha")
	}
}

func TestNativeConfigurationAmbiguousPayloadMetadataRefuses(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	nativeConfigurationFile(t, a, "channel.txt", "alpha")
	nativeConfigurationFile(t, b, "channel.txt", "beta")
	if _, err := readNativeConfiguration(context.Background(), []string{a, b}, "", false, func(string) error { return nil }); err == nil {
		t.Fatal("multiple payload roots became first-root selection")
	}
}

func TestNativeConfigurationAppearedOptionalMetadataOnAnyRootRefuses(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	for _, name := range []string{"brand.json", "channel.txt", "images.json", "bundle/bundle.json"} {
		t.Run(name, func(t *testing.T) {
			first, second, third := t.TempDir(), t.TempDir(), t.TempDir()
			nativeConfigurationFile(t, first, "channel.txt", "alpha")
			calls := map[string]int{}
			_, err := readNativeConfiguration(context.Background(), []string{first, second, third}, "", false, func(root string) error {
				calls[root]++
				// This first-pass callback runs even if the re-observation
				// guard is removed: second's absence was already captured.
				if root == third && calls[root] == 1 {
					nativeConfigurationFile(t, second, name, "new metadata")
				}
				return nil
			})
			if _, statErr := os.Stat(filepath.Join(second, filepath.FromSlash(name))); statErr != nil {
				t.Fatal("appearance control never created its owned metadata")
			}
			if err == nil || !strings.Contains(err.Error(), "changed") {
				t.Fatalf("appeared optional metadata did not refuse: %v", err)
			}
		})
	}
}

func TestNativeConfigurationChangedMetadataAndRootIdentityRefuse(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	for _, change := range []string{"bytes", "delete", "swap"} {
		t.Run(change, func(t *testing.T) {
			parent := t.TempDir()
			root := filepath.Join(parent, "owned")
			nativeConfigurationFile(t, root, "channel.txt", "alpha")
			calls := 0
			_, err := readNativeConfiguration(context.Background(), []string{root}, "", false, func(string) error {
				calls++
				if calls == 2 {
					switch change {
					case "bytes":
						nativeConfigurationFile(t, root, "channel.txt", "beta")
					case "delete":
						if err := os.RemoveAll(root); err != nil {
							t.Fatal(err)
						}
					case "swap":
						if err := os.Rename(root, filepath.Join(parent, "original")); err != nil {
							t.Fatal(err)
						}
						nativeConfigurationFile(t, root, "channel.txt", "alpha")
					}
				}
				return nil
			})
			if err == nil {
				t.Fatalf("changed %s accepted", change)
			}
		})
	}
}

func TestNativeConfigurationBundleMetadataIsNotOfflineIntegrity(t *testing.T) {
	t.Setenv("WOOTC_CHANNEL", "")
	root := t.TempDir()
	nativeConfigurationFile(t, root, "images.json", `[{"id":"fixture","name":"Fixture","imageRef":"ghcr.io/tuna-os/fixture:latest","status":"green"}]`)
	nativeConfigurationFile(t, root, "bundle/bundle.json", `{"image":"ghcr.io/tuna-os/fixture:latest","digest":"sha256:`+strings.Repeat("a", 64)+`","storeBytes":1,"createdAt":"2026-09-27T00:00:00Z"}`)
	snapshot, err := readNativeConfiguration(context.Background(), []string{root}, "", false, func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Bundle.State != "metadata-only" || snapshot.Bundle.ContentVerified || snapshot.Images[0].ContentVerified {
		t.Fatal("bundle metadata was treated as verified contents")
	}
}
