package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

type tarFixtureEntry struct {
	name     string
	body     string
	linkname string
}

func TestInspectOCIBundleAppliesLayersAndWhiteouts(t *testing.T) {
	base := tarLayer(t, "gzip", []tarFixtureEntry{
		{name: "usr/lib/modules/6.17.1/modules.dep", body: "kernel/drivers/old-driver.ko.xz:\n"},
		{name: "usr/lib/modules/6.17.1/modules.builtin", body: "kernel/drivers/simpledrm.ko\n"},
		{name: "usr/lib/modules/6.17.1/modules.alias", body: "alias pci:v00008086d* old_driver\n"},
		{name: "usr/lib/firmware/iwlwifi/old.ucode.xz", body: "firmware"},
		{name: "usr/lib/firmware/brcm/removed.bin", body: "firmware"},
	})
	newer := tarLayer(t, "zstd", []tarFixtureEntry{
		{name: "usr/lib/modules/6.17.1/modules.dep", body: "kernel/drivers/new-driver.ko.zst:\n"},
		{name: "usr/lib/modules/6.17.1/.wh.modules.alias"},
		{name: "usr/lib/firmware/iwlwifi/.wh.old.ucode.xz"},
		{name: "usr/lib/firmware/brcm/.wh..wh..opq"},
		{name: "usr/lib/firmware/brcm/new.bin.zst", body: "firmware"},
	})
	dir := writeOCILayout(t, base, newer)
	kernel, err := inspectOCIBundle(dir)
	if err != nil {
		t.Fatal(err)
	}
	if kernel.KVersion != "6.17.1" || !kernel.hasModule("new-driver") || kernel.hasModule("old-driver") {
		t.Fatalf("module overlay incorrect: %+v", kernel)
	}
	if len(kernel.Aliases) != 0 {
		t.Fatalf("whiteouted aliases survived: %+v", kernel.Aliases)
	}
	if kernel.hasFirmware("iwlwifi/old.ucode") || kernel.hasFirmware("brcm/removed.bin") || !kernel.hasFirmware("brcm/new.bin") {
		t.Fatalf("firmware overlay incorrect: %+v", kernel.Firmware)
	}
	if kernel.LayersSkipped != 0 {
		t.Fatalf("layers skipped = %d", kernel.LayersSkipped)
	}
}

func TestInspectOCIBundleResolvesOstreeHardlink(t *testing.T) {
	layer := tarLayer(t, "none", []tarFixtureEntry{
		{name: "sysroot/ostree/repo/objects/aa/object.file", body: "kernel/drivers/vmd/vmd.ko.xz:\n"},
		{name: "usr/lib/modules/6.18.0/modules.dep", linkname: "sysroot/ostree/repo/objects/aa/object.file"},
	})
	kernel, err := inspectOCIBundle(writeOCILayout(t, layer))
	if err != nil {
		t.Fatal(err)
	}
	if !kernel.hasModule("vmd") {
		t.Fatalf("hard-linked modules.dep was not read: %+v", kernel.Modules)
	}
}

func TestInspectOCIBundleReadsBuiltinModinfoAliases(t *testing.T) {
	layer := tarLayer(t, "gzip", []tarFixtureEntry{
		{name: "usr/lib/modules/6.18.0/modules.dep", body: "\n"},
		{name: "usr/lib/modules/6.18.0/modules.builtin", body: "kernel/drivers/vmd/vmd.ko\n"},
		{name: "usr/lib/modules/6.18.0/modules.builtin.modinfo", body: "vmd.alias=pci:v00008086d00009A0Bsv*sd*bc01sc04i*\x00"},
	})
	kernel, err := inspectOCIBundle(writeOCILayout(t, layer))
	if err != nil {
		t.Fatal(err)
	}
	drivers := kernel.aliasDrivers("pci:v00008086d00009A0Bsv00001028sd00000001bc01sc04i00")
	if len(drivers) != 1 || drivers[0] != "vmd" || !kernel.hasModule("vmd") {
		t.Fatalf("built-in inventory = drivers %v, modules %+v", drivers, kernel.Builtin)
	}
}

func TestTargetKernelSelectsNewestVersionNumerically(t *testing.T) {
	overlay := targetOverlay{
		moduleFiles: map[string][]byte{
			"usr/lib/modules/6.9.12-200.fc43/modules.dep": []byte("kernel/drivers/old.ko:\n"),
			"usr/lib/modules/6.10.3-100.fc43/modules.dep": []byte("kernel/drivers/new.ko:\n"),
		},
		firmware: map[string]struct{}{},
	}
	kernel := targetKernelFromOverlay(overlay)
	if kernel == nil || kernel.KVersion != "6.10.3-100.fc43" || !kernel.hasModule("new") || kernel.hasModule("old") {
		t.Fatalf("selected kernel = %+v", kernel)
	}
}

func TestInspectOCIBundleMarksUnreadableLayerPartial(t *testing.T) {
	good := tarLayer(t, "gzip", []tarFixtureEntry{{name: "usr/lib/modules/6.17.1/modules.dep", body: "kernel/drivers/vmd.ko.xz:\n"}})
	bad := []byte("not a tar archive")
	kernel, err := inspectOCIBundle(writeOCILayout(t, good, bad))
	if err != nil {
		t.Fatal(err)
	}
	if kernel.LayersSkipped != 1 || !kernel.hasModule("vmd") {
		t.Fatalf("partial inventory = %+v", kernel)
	}
}

func tarLayer(t *testing.T, compression string, entries []tarFixtureEntry) []byte {
	t.Helper()
	var tarBytes bytes.Buffer
	writer := tar.NewWriter(&tarBytes)
	for _, entry := range entries {
		header := &tar.Header{Name: entry.name, Mode: 0o644, Size: int64(len(entry.body)), Typeflag: tar.TypeReg}
		if entry.linkname != "" {
			header.Typeflag = tar.TypeLink
			header.Linkname = entry.linkname
			header.Size = 0
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if entry.body != "" {
			if _, err := writer.Write([]byte(entry.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	switch compression {
	case "none":
		return tarBytes.Bytes()
	case "gzip":
		var compressed bytes.Buffer
		gzipWriter := gzip.NewWriter(&compressed)
		if _, err := gzipWriter.Write(tarBytes.Bytes()); err != nil {
			t.Fatal(err)
		}
		if err := gzipWriter.Close(); err != nil {
			t.Fatal(err)
		}
		return compressed.Bytes()
	case "zstd":
		var compressed bytes.Buffer
		zstdWriter, err := zstd.NewWriter(&compressed, zstd.WithEncoderConcurrency(1))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := zstdWriter.Write(tarBytes.Bytes()); err != nil {
			t.Fatal(err)
		}
		if err := zstdWriter.Close(); err != nil {
			t.Fatal(err)
		}
		return compressed.Bytes()
	default:
		t.Fatalf("unknown compression %q", compression)
		return nil
	}
}

func writeOCILayout(t *testing.T, layers ...[]byte) string {
	t.Helper()
	dir := t.TempDir()
	blobDir := filepath.Join(dir, "blobs", "sha256")
	if err := os.MkdirAll(blobDir, 0o755); err != nil {
		t.Fatal(err)
	}
	var descriptors []ociDescriptor
	for _, layer := range layers {
		sum := sha256.Sum256(layer)
		hexPart := hex.EncodeToString(sum[:])
		if err := os.WriteFile(filepath.Join(blobDir, hexPart), layer, 0o644); err != nil {
			t.Fatal(err)
		}
		descriptors = append(descriptors, ociDescriptor{Digest: "sha256:" + hexPart, Size: int64(len(layer))})
	}
	manifest := ociManifest{MediaType: mtOCIManifest, Layers: descriptors}
	manifestRaw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	manifestSum := sha256.Sum256(manifestRaw)
	manifestHex := hex.EncodeToString(manifestSum[:])
	if err := os.WriteFile(filepath.Join(blobDir, manifestHex), manifestRaw, 0o644); err != nil {
		t.Fatal(err)
	}
	indexRaw, err := json.Marshal(ociManifest{Manifests: []ociDescriptor{{Digest: "sha256:" + manifestHex, Size: int64(len(manifestRaw))}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "index.json"), indexRaw, 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}
