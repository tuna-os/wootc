package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const vmBootExportLimit = int64(512 << 20)

// This record is separate from VMState: exporting a read-only disk cannot
// change its clean-stop evidence, and export completion never arms native boot.
type vmPromotionRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	InstallID     string `json:"installId"`
	DiskID        string `json:"diskId"`
	RunID         string `json:"runId"`
	Phase         string `json:"phase"`
	ExportPath    string `json:"exportPath,omitempty"`
	Error         string `json:"error,omitempty"`
	UpdatedAt     string `json:"updatedAt"`
}

type vmBootExportManifest struct {
	SchemaVersion         int               `json:"schemaVersion"`
	RunID                 string            `json:"runId"`
	InstallID             string            `json:"installId"`
	Image                 string            `json:"image"`
	DiskID                string            `json:"diskId"`
	RootUUID              string            `json:"rootUuid"`
	KernelVersion         string            `json:"kernelVersion"`
	NativeReady           bool              `json:"nativeReady"`
	NativeClosurePrepared bool              `json:"nativeClosurePrepared"`
	Files                 map[string]string `json:"files"`
}

func writeVMPromotionRecord(path string, record vmPromotionRecord) error {
	record.SchemaVersion = 1
	record.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".promotion-state-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

// Hold the image lease before removing interrupted private export stages.
// Published verified inputs and the installed disk are never cleanup targets.
func cleanupVMPromotionStaging(root string) error {
	for _, pattern := range []string{".promotion-export-*", ".promotion-state-*"} {
		paths, err := filepath.Glob(filepath.Join(root, pattern))
		if err != nil {
			return err
		}
		for _, path := range paths {
			if err := os.RemoveAll(path); err != nil {
				return fmt.Errorf("remove interrupted native export: %w", err)
			}
		}
	}
	return nil
}

// Only this fixed five-file transport is accepted. No guest path, link, device,
// executable name or archive metadata is allowed to select a host destination.
func unpackVMBootExport(source io.Reader, destination string, expected VMState, hostUUID string) (vmBootExportManifest, error) {
	var manifest vmBootExportManifest
	allowed := map[string]bool{"manifest.json": true, "entry.conf": true, "kernel": true, "initramfs": true, "native-initramfs": true}
	observed := map[string]string{}
	archive := tar.NewReader(io.LimitReader(source, vmBootExportLimit+1))
	var total int64
	for {
		header, err := archive.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return manifest, err
		}
		if !allowed[header.Name] || observed[header.Name] != "" || header.Typeflag != tar.TypeReg || header.Size <= 0 || header.Size > vmBootExportLimit-total {
			return manifest, fmt.Errorf("invalid installed boot export member")
		}
		if (header.Name == "manifest.json" || header.Name == "entry.conf") && header.Size > 64<<10 {
			return manifest, fmt.Errorf("boot export metadata exceeds bound")
		}
		total += header.Size
		file, err := os.OpenFile(filepath.Join(destination, header.Name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return manifest, err
		}
		hash := sha256.New()
		_, copyErr := io.Copy(io.MultiWriter(file, hash), archive)
		if copyErr == nil {
			copyErr = file.Sync()
		}
		closeErr := file.Close()
		if copyErr != nil {
			return manifest, copyErr
		}
		if closeErr != nil {
			return manifest, closeErr
		}
		observed[header.Name] = fmt.Sprintf("%x", hash.Sum(nil))
	}
	if len(observed) != len(allowed) {
		return manifest, fmt.Errorf("installed boot export is incomplete")
	}
	data, err := os.ReadFile(filepath.Join(destination, "manifest.json"))
	if err != nil {
		return manifest, err
	}
	fields, err := decodeQMPObject(data)
	if err != nil || len(fields) != 10 || !bytes.Equal(bytes.TrimSpace(fields["nativeReady"]), []byte("false")) || !bytes.Equal(bytes.TrimSpace(fields["nativeClosurePrepared"]), []byte("true")) {
		return manifest, fmt.Errorf("invalid installed boot export manifest")
	}
	if err := strictQMPDecode(data, &manifest); err != nil {
		return manifest, err
	}
	if manifest.SchemaVersion != 1 || manifest.RunID != expected.RunID || manifest.InstallID != expected.InstallID || manifest.DiskID != expected.DiskID || manifest.Image != expected.Image || !vmGuestUUID.MatchString(manifest.RootUUID) || manifest.KernelVersion == "" || manifest.NativeReady || !manifest.NativeClosurePrepared || len(manifest.Files) != 4 {
		return manifest, fmt.Errorf("installed boot export identity or scope mismatch")
	}
	for name := range allowed {
		if name != "manifest.json" && manifest.Files[name] != observed[name] {
			return manifest, fmt.Errorf("installed boot export digest mismatch: %s", name)
		}
	}
	entry, err := os.ReadFile(filepath.Join(destination, "entry.conf"))
	if err != nil {
		return manifest, err
	}
	native, err := vmNativeBootEntry(string(entry), manifest.RootUUID, hostUUID)
	if err != nil {
		return manifest, err
	}
	if err := os.WriteFile(filepath.Join(destination, "native-entry.conf"), []byte(native), 0600); err != nil {
		return manifest, err
	}
	return manifest, nil
}

// Native entries are exported separately; never mutate the generic BLS entry
// used by VM firmware. This entry is not staged on the host ESP by this code.
func vmNativeBootEntry(generic, rootUUID, hostUUID string) (string, error) {
	if !vmGuestUUID.MatchString(rootUUID) || !hostUUIDPattern.MatchString(hostUUID) || hostUUID == strings.Repeat("0", 16) {
		return "", fmt.Errorf("native boot needs measured root and host volume identities")
	}
	var options string
	linux, initrd := 0, 0
	for _, line := range strings.Split(generic, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		switch fields[0] {
		case "linux":
			linux++
		case "initrd":
			initrd++
		case "options":
			if options != "" || len(fields) < 2 {
				return "", fmt.Errorf("ambiguous generic boot options")
			}
			options = strings.Join(fields[1:], " ")
		}
	}
	if linux != 1 || initrd != 1 || options == "" {
		return "", fmt.Errorf("unsupported generic boot entry")
	}
	rootSeen := false
	for _, option := range strings.Fields(options) {
		if strings.HasPrefix(option, "loop=") || strings.HasPrefix(option, "wootc.host_uuid=") || strings.ContainsAny(option, "\x00\r\n") {
			return "", fmt.Errorf("generic boot entry already contains native or invalid arguments")
		}
		if strings.HasPrefix(option, "root=") {
			if rootSeen || option != "root=UUID="+rootUUID {
				return "", fmt.Errorf("boot entry root differs from installed root")
			}
			rootSeen = true
		}
	}
	if !rootSeen {
		return "", fmt.Errorf("generic boot entry has no measured root UUID")
	}
	return "title wootc native (same installed system)\nlinux /EFI/wootc/promotion/kernel\ninitrd /EFI/wootc/promotion/native-initramfs\noptions " + options + " wootc.host_uuid=" + strings.ToUpper(hostUUID) + " loop=/wootc/disks/root.disk\n", nil
}
