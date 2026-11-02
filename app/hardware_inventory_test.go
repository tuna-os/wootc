package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/ulikunitz/xz"
)

type hardwareTarEntry struct {
	name string
	data []byte
	link string
}

func hardwareTestELF(firmware string) []byte {
	// Minimal ELF64 relocatable with a real .modinfo section; no toolchain or
	// executable fixture is needed to exercise debug/elf and each decoder.
	names := []byte("\x00.shstrtab\x00.modinfo\x00")
	info := []byte("license=GPL\x00firmware=" + firmware + "\x00")
	const shoff = 64
	const dataoff = shoff + 3*64
	data := make([]byte, dataoff+len(names)+len(info))
	copy(data, []byte{0x7f, 'E', 'L', 'F', 2, 1, 1})
	binary.LittleEndian.PutUint16(data[16:], 1)
	binary.LittleEndian.PutUint16(data[18:], 62)
	binary.LittleEndian.PutUint32(data[20:], 1)
	binary.LittleEndian.PutUint64(data[40:], shoff)
	binary.LittleEndian.PutUint16(data[52:], 64)
	binary.LittleEndian.PutUint16(data[58:], 64)
	binary.LittleEndian.PutUint16(data[60:], 3)
	binary.LittleEndian.PutUint16(data[62:], 1)
	section := func(offset int, name, kind uint32, start, size uint64) {
		binary.LittleEndian.PutUint32(data[offset:], name)
		binary.LittleEndian.PutUint32(data[offset+4:], kind)
		binary.LittleEndian.PutUint64(data[offset+24:], start)
		binary.LittleEndian.PutUint64(data[offset+32:], size)
		binary.LittleEndian.PutUint64(data[offset+48:], 1)
	}
	section(shoff+64, 1, 3, dataoff, uint64(len(names)))
	section(shoff+128, 11, 1, uint64(dataoff+len(names)), uint64(len(info)))
	copy(data[dataoff:], names)
	copy(data[dataoff+len(names):], info)
	return data
}

func TestHardwareModuleFirmwareDecoders(t *testing.T) {
	elf := hardwareTestELF("iwlwifi-test.ucode.xz")
	for _, suffix := range []string{"", ".gz", ".zst", ".xz"} {
		t.Run(suffix, func(t *testing.T) {
			var b bytes.Buffer
			var w io.WriteCloser
			switch suffix {
			case "":
				b.Write(elf)
			case ".gz":
				w = gzip.NewWriter(&b)
			case ".zst":
				z, err := zstd.NewWriter(&b)
				if err != nil {
					t.Fatal(err)
				}
				w = z
			case ".xz":
				x, err := xz.NewWriter(&b)
				if err != nil {
					t.Fatal(err)
				}
				w = x
			}
			if w != nil {
				if _, err := w.Write(elf); err != nil {
					t.Fatal(err)
				}
				if err := w.Close(); err != nil {
					t.Fatal(err)
				}
			}
			got, err := hardwareReadModuleFirmware("iwlwifi.ko"+suffix, bytes.NewReader(b.Bytes()))
			if err != nil || len(got) != 1 || got[0] != "iwlwifi-test.ucode" {
				t.Fatalf("firmware = %v, %v", got, err)
			}
		})
	}
	if _, err := hardwareReadModuleFirmware("bad.ko", bytes.NewReader([]byte("not ELF"))); err == nil {
		t.Fatal("invalid module accepted")
	}
}

func hardwareTestLayout(t *testing.T, layers [][]hardwareTarEntry, media string) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "blobs", "sha256")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	blob := func(data []byte, media string) ociDescriptor {
		hash := sha256.Sum256(data)
		digest := hex.EncodeToString(hash[:])
		if err := os.WriteFile(filepath.Join(dir, digest), data, 0600); err != nil {
			t.Fatal(err)
		}
		return ociDescriptor{Digest: "sha256:" + digest, MediaType: media, Size: int64(len(data))}
	}
	m := ociManifest{}
	for _, entries := range layers {
		var raw bytes.Buffer
		w := tar.NewWriter(&raw)
		for _, entry := range entries {
			h := &tar.Header{Name: entry.name, Mode: 0600, Size: int64(len(entry.data)), Typeflag: tar.TypeReg}
			if entry.link != "" {
				h.Typeflag = tar.TypeSymlink
				h.Linkname = entry.link
				h.Size = 0
			}
			if err := w.WriteHeader(h); err != nil {
				t.Fatal(err)
			}
			if entry.link == "" {
				if _, err := w.Write(entry.data); err != nil {
					t.Fatal(err)
				}
			}
		}
		if err := w.Close(); err != nil {
			t.Fatal(err)
		}
		data := raw.Bytes()
		if media == "application/vnd.oci.image.layer.v1.tar+gzip" {
			var out bytes.Buffer
			g := gzip.NewWriter(&out)
			if _, err := g.Write(data); err != nil {
				t.Fatal(err)
			}
			if err := g.Close(); err != nil {
				t.Fatal(err)
			}
			data = out.Bytes()
		} else if media == "application/vnd.oci.image.layer.v1.tar+zstd" {
			var out bytes.Buffer
			z, err := zstd.NewWriter(&out)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := z.Write(data); err != nil {
				t.Fatal(err)
			}
			if err := z.Close(); err != nil {
				t.Fatal(err)
			}
			data = out.Bytes()
		}
		m.Layers = append(m.Layers, blob(data, media))
	}
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	descriptor := blob(data, mtOCIManifest)
	index, err := json.Marshal(ociManifest{Manifests: []ociDescriptor{descriptor}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "index.json"), index, 0600); err != nil {
		t.Fatal(err)
	}
	return root
}

func hardwareBaseLayer() []hardwareTarEntry {
	return []hardwareTarEntry{
		{"usr/lib/modules/6.test/modules.dep", []byte("kernel/iwlwifi.ko:\n"), ""},
		{"usr/lib/modules/6.test/modules.builtin", nil, ""},
		{"usr/lib/modules/6.test/modules.alias", []byte("alias pci:v00008086d*sv*sd*bc02sc*i* iwlwifi\n"), ""},
		{"usr/lib/modules/6.test/kernel/iwlwifi.ko", hardwareTestELF("iwlwifi-test.ucode"), ""},
		{"usr/lib/firmware/iwlwifi-test.ucode.xz", []byte("firmware"), ""},
		{"usr/lib/firmware/vendor/old.bin", []byte("old"), ""},
	}
}

func TestHardwareOCIInventoryLayerFormatsAndWhiteouts(t *testing.T) {
	devices := []hardwareDevice{{ID: "wifi", Modalias: "pci:v00008086d00001234sv00000000sd00000000bc02sc80i00", Class: 0x028000}}
	for _, media := range []string{"application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar+gzip", "application/vnd.oci.image.layer.v1.tar+zstd"} {
		t.Run(media, func(t *testing.T) {
			root := hardwareTestLayout(t, [][]hardwareTarEntry{hardwareBaseLayer(), {
				// Same-layer additions survive an opaque marker even if the tar
				// lists them first (whiteouts only affect lower layers).
				{"usr/lib/firmware/vendor/new.bin.zst", []byte("new"), ""},
				{"usr/lib/firmware/vendor/.wh..wh..opq", nil, ""},
				{"usr/lib/firmware/.wh.iwlwifi-test.ucode.xz", nil, ""},
				{"usr/lib/firmware/live.bin", nil, "vendor/new.bin.zst"},
				{"usr/lib/firmware/dangling.bin", nil, "gone.bin"},
			}}, media)
			k, err := readHardwareInventory(context.Background(), root, devices)
			if err != nil {
				t.Fatal(err)
			}
			if k.partial || !k.hasModule("iwlwifi") || len(k.drivers(devices[0].Modalias)) != 1 {
				t.Fatalf("kernel inventory: %+v", k)
			}
			if k.hasFirmware("iwlwifi-test.ucode") || k.hasFirmware("vendor/old.bin") || k.hasFirmware("dangling.bin") || !k.hasFirmware("vendor/new.bin") || !k.hasFirmware("live.bin") {
				t.Fatalf("firmware overlay: %v", k.firmware)
			}
			if len(k.moduleFirmware["iwlwifi"]) != 1 || k.firmwareUnknown["iwlwifi"] {
				t.Fatalf("module modinfo missing: %+v", k)
			}
			r := assessHardware(devices, k)
			if len(r.Findings) != 1 || r.Findings[0].Severity != "warning" {
				t.Fatalf("missing firmware observation: %+v", r)
			}
		})
	}
}

func TestHardwareOCIUnavailableLayerNeverBlocks(t *testing.T) {
	root := hardwareTestLayout(t, [][]hardwareTarEntry{hardwareBaseLayer()}, "unsupported-layer")
	if _, err := readHardwareInventory(context.Background(), root, nil); err == nil {
		t.Fatal("no readable kernel claimed support")
	}
	if _, err := hardwareBlobPath(root, "sha256:../../escape"); err == nil {
		t.Fatal("unsafe digest accepted")
	}
	root = hardwareTestLayout(t, [][]hardwareTarEntry{hardwareBaseLayer(), {{"usr/lib/firmware/new.bin", nil, ""}}}, "application/vnd.oci.image.layer.v1.tar")
	manifest, err := hardwareManifest(root)
	if err != nil {
		t.Fatal(err)
	}
	name, err := hardwareBlobPath(root, manifest.Layers[1].Digest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	k, err := readHardwareInventory(context.Background(), root, nil)
	if err != nil || !k.partial {
		t.Fatalf("missing layer = %+v, %v", k, err)
	}
	for _, f := range assessHardware([]hardwareDevice{{ID: "storage", Modalias: "pci:absent", Class: 0x010000}}, k).Findings {
		if f.Severity == "blocking" {
			t.Fatal("partial target blocked")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := readHardwareInventory(ctx, root, nil); err != context.Canceled {
		t.Fatalf("cancellation = %v", err)
	}
}

func TestHardwareBuiltinModinfoSuppliesAliasesWithoutDepmodBinary(t *testing.T) {
	layer := append(hardwareBaseLayer(),
		hardwareTarEntry{"usr/lib/modules/6.test/modules.builtin", []byte("kernel/vmd.ko\n"), ""},
		hardwareTarEntry{"usr/lib/modules/6.test/modules.builtin.modinfo", []byte("vmd.alias=pci:v00008086d*sv*sd*bc01sc04i*\x00vmd.license=GPL\x00"), ""},
	)
	devices := []hardwareDevice{{ID: "Intel VMD", Modalias: "pci:v00008086d00001234sv00000000sd00000000bc01sc04i00", Class: 0x010400}}
	root := hardwareTestLayout(t, [][]hardwareTarEntry{layer}, "application/vnd.oci.image.layer.v1.tar")
	k, err := readHardwareInventory(context.Background(), root, devices)
	if err != nil || k.partial {
		t.Fatalf("builtin metadata: %+v, %v", k, err)
	}
	if drivers := k.drivers(devices[0].Modalias); len(drivers) != 1 || drivers[0] != "vmd" {
		t.Fatalf("builtin aliases = %v", drivers)
	}
	if r := assessHardware(devices, k); len(r.Findings) != 0 {
		t.Fatalf("builtin falsely unsupported: %+v", r)
	}
}
