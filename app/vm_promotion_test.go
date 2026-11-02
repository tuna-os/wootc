package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func vmExportFixture(t *testing.T, change func(*vmBootExportManifest, map[string][]byte)) ([]byte, VMState) {
	t.Helper()
	state := VMState{RunID: "run-12345", InstallID: "install-12345", DiskID: "12345678-1234-1234-1234-123456789abc", Image: "repo@sha256:" + strings.Repeat("a", 64)}
	root := "87654321-1234-1234-1234-123456789abc"
	files := map[string][]byte{"kernel": []byte("exact installed kernel"), "initramfs": []byte("untouched generic initramfs"), "native-initramfs": []byte("target matched native closure"), "entry.conf": []byte("title Linux\nversion 6.1\nlinux /ostree/kernel\ninitrd /ostree/initramfs\noptions root=UUID=" + root + " rw ostree=/ostree/boot.1/example/0\n")}
	manifest := vmBootExportManifest{SchemaVersion: 1, RunID: state.RunID, InstallID: state.InstallID, DiskID: state.DiskID, Image: state.Image, RootUUID: root, KernelVersion: "6.1", NativeClosurePrepared: true, Files: map[string]string{}}
	for name, data := range files {
		manifest.Files[name] = fmtVMExportDigest(data)
	}
	if change != nil {
		change(&manifest, files)
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	files["manifest.json"] = data
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	for _, name := range []string{"manifest.json", "entry.conf", "kernel", "initramfs", "native-initramfs"} {
		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0600, Size: int64(len(files[name])), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(files[name]); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return output.Bytes(), state
}

func fmtVMExportDigest(data []byte) string {
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

func TestVMBootExportKeepsGenericEntryAndSeparatesNativeInputs(t *testing.T) {
	data, state := vmExportFixture(t, nil)
	root := t.TempDir()
	manifest, err := unpackVMBootExport(bytes.NewReader(data), root, state, "0123456789ABCDEF")
	if err != nil {
		t.Fatal(err)
	}
	if manifest.NativeReady || !manifest.NativeClosurePrepared {
		t.Fatal("export was promoted to native acceptance")
	}
	generic, err := os.ReadFile(filepath.Join(root, "entry.conf"))
	if err != nil {
		t.Fatal(err)
	}
	native, err := os.ReadFile(filepath.Join(root, "native-entry.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(generic), "loop=") || !strings.Contains(string(native), "ostree=/ostree/boot.1/example/0") || !strings.Contains(string(native), "loop=/wootc/disks/root.disk") || !strings.Contains(string(native), "initrd /EFI/wootc/promotion/native-initramfs") {
		t.Fatal("generic and native boot contracts were mixed")
	}
}

func TestVMBootExportRejectsStaleCorruptOrUnpreparedInputs(t *testing.T) {
	cases := map[string]func(*vmBootExportManifest, map[string][]byte){
		"run":       func(m *vmBootExportManifest, _ map[string][]byte) { m.RunID = "stale" },
		"disk":      func(m *vmBootExportManifest, _ map[string][]byte) { m.DiskID = "87654321-1234-1234-1234-123456789abc" },
		"kernel":    func(_ *vmBootExportManifest, f map[string][]byte) { f["kernel"] = []byte("another kernel") },
		"closure":   func(m *vmBootExportManifest, _ map[string][]byte) { m.NativeClosurePrepared = false },
		"readiness": func(m *vmBootExportManifest, _ map[string][]byte) { m.NativeReady = true },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			data, state := vmExportFixture(t, change)
			if _, err := unpackVMBootExport(bytes.NewReader(data), t.TempDir(), state, "0123456789ABCDEF"); err == nil {
				t.Fatal("invalid export accepted")
			}
		})
	}
}

func TestVMBootExportRejectsArchivePathsAndLinks(t *testing.T) {
	for _, header := range []*tar.Header{{Name: "../escape", Mode: 0600, Size: 1, Typeflag: tar.TypeReg}, {Name: "kernel", Linkname: "/etc/shadow", Typeflag: tar.TypeSymlink}, {Name: "kernel", Size: vmBootExportLimit + 1, Typeflag: tar.TypeReg}} {
		var body bytes.Buffer
		writer := tar.NewWriter(&body)
		if err := writer.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := unpackVMBootExport(bytes.NewReader(body.Bytes()), t.TempDir(), VMState{}, "0123456789ABCDEF"); err == nil {
			t.Fatalf("unsafe archive header accepted: %+v", header)
		}
	}
}

func TestVMNativeEntryRejectsChangedRootAndNativeArguments(t *testing.T) {
	root := "87654321-1234-1234-1234-123456789abc"
	base := "linux /kernel\ninitrd /initramfs\noptions root=UUID=" + root
	for _, entry := range []string{base + " loop=/another.disk", base + " wootc.host_uuid=0123456789ABCDEF", base + "\noptions root=UUID=" + root, strings.ReplaceAll(base, root, "00000000-0000-0000-0000-000000000000")} {
		if _, err := vmNativeBootEntry(entry, root, "0123456789ABCDEF"); err == nil {
			t.Fatal("unsafe native entry accepted")
		}
	}
}

func TestVMPromotionJournalDoesNotChangeVMState(t *testing.T) {
	root := t.TempDir()
	statePath := filepath.Join(root, "state.json")
	state := VMState{InstallID: "install-12345", DiskPath: "root.disk", Phase: vmStopped}
	if err := writeVMState(statePath, state); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "promotion.json")
	for _, phase := range []string{"exporting", "export-failed", "boot-inputs-verified"} {
		if err := writeVMPromotionRecord(path, vmPromotionRecord{InstallID: state.InstallID, Phase: phase}); err != nil {
			t.Fatal(err)
		}
	}
	after, err := os.ReadFile(statePath)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("export transaction changed the VM lifecycle")
	}
}

func TestVMPromotionCleanupPreservesDiskAndPublishedInputs(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{".promotion-export-interrupted", "native-boot-verified"} {
		if err := os.Mkdir(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, name, "kernel"), []byte("kernel"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "root.disk"), []byte("user files"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := cleanupVMPromotionStaging(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".promotion-export-interrupted")); !os.IsNotExist(err) {
		t.Fatal("interrupted export survived cleanup")
	}
	for _, name := range []string{"root.disk", filepath.Join("native-boot-verified", "kernel")} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("cleanup removed %s: %v", name, err)
		}
	}
}
