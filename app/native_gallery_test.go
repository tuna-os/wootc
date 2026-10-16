package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The native screen gallery (shell/Wootc.Shell.Gallery) shows the
// configuration screen from this recorded engine snapshot: the embedded
// catalogue as the engine reads it with no installation root, plus one
// synthetic observed volume. The catalogue changes with releases, so the
// fixture is not compared byte for byte; it must keep the exact wire shape
// of NativeConfigurationSnapshot, which this test checks on every run.
// Update: WOOTC_UPDATE_NATIVE_GALLERY_FIXTURE=1 go test -run TestNativeGalleryConfigurationFixture .
func TestNativeGalleryConfigurationFixture(t *testing.T) {
	path := filepath.Join("..", "tests", "unit", "fixtures", "native-gallery", "configuration.json")
	if os.Getenv("WOOTC_UPDATE_NATIVE_GALLERY_FIXTURE") == "1" {
		t.Setenv("WOOTC_CHANNEL", "")
		t.Setenv("WOOTC_E2E_DRIVE", "")
		wearBrand(t, "wootc")
		snapshot, err := readNativeConfiguration(context.Background(), []string{filepath.Join(t.TempDir(), "missing")}, "", false, func(string) error { return nil })
		if err != nil {
			t.Fatal(err)
		}
		snapshot.StorageStatus = "observed"
		snapshot.Storage = []NativeConfigurationStorage{{ID: "gallery-volume-d", DriveLetter: "D", DiskGUID: "11111111-1111-1111-1111-111111111111",
			PartitionGUID: "22222222-2222-2222-2222-222222222222", NtfsSerial: "0123456789abcdef", FreeBytes: 128 << 30, MaximumRootDiskSizeGB: 100}}
		server := newConfigurationAssessmentServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}, func(context.Context) (NativeConfigurationSnapshot, error) { return snapshot, nil })
		result, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"})
		if failure != nil {
			t.Fatal(failure)
		}
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("gallery configuration fixture missing: %v", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var snapshot NativeConfigurationSnapshot
	if err := decoder.Decode(&snapshot); err != nil {
		t.Fatalf("gallery configuration no longer matches the engine's snapshot: %v", err)
	}
	var recorded, current map[string]any
	_ = json.Unmarshal(data, &recorded)
	again, _ := json.Marshal(snapshot)
	_ = json.Unmarshal(again, &current)
	if !jsonShapeEqual(recorded, current) {
		t.Fatal("gallery configuration lacks fields the engine now sends; regenerate it")
	}
	if snapshot.StorageStatus != "observed" || len(snapshot.Storage) != 1 || len(snapshot.Images) == 0 || len(snapshot.Steps) == 0 || snapshot.BrandID != "wootc" {
		t.Fatalf("gallery configuration cannot drive the configuration screen: %+v", snapshot.Storage)
	}
}

// jsonShapeEqual compares the key sets of two decoded JSON values, recursively.
func jsonShapeEqual(a, b any) bool {
	switch left := a.(type) {
	case map[string]any:
		right, ok := b.(map[string]any)
		if !ok || len(left) != len(right) {
			return false
		}
		for key, value := range left {
			other, ok := right[key]
			if !ok || !jsonShapeEqual(value, other) {
				return false
			}
		}
		return true
	case []any:
		right, ok := b.([]any)
		if !ok || len(left) != len(right) {
			return false
		}
		for index := range left {
			if !jsonShapeEqual(left[index], right[index]) {
				return false
			}
		}
		return true
	}
	return true
}
