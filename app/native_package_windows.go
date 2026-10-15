//go:build windows

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

const nativePackageManifestLimit = 1024 * 1024

// Native preview bundles are installed into a protected directory. The
// manifest correlates artifacts; protected ownership/ACLs establish authority.
// It is never accepted from the peer or from a writable download directory.
type nativePackageManifest struct {
	SchemaVersion   int               `json:"schemaVersion"`
	ProtocolVersion int               `json:"protocolVersion"`
	BuildID         string            `json:"buildId"`
	BrandID         string            `json:"brandId"`
	Files           map[string]string `json:"files"`
}

// Set by the preview packaging build, separately from the primary Wails build.
var nativeBuildID string

func auditNativePackagePath(path string) error {
	path = filepath.Clean(path)
	volume := filepath.VolumeName(path)
	if len(volume) != 2 || volume[1] != ':' {
		return fmt.Errorf("native package requires a local fixed volume")
	}
	root := volume + `\`
	rootUTF16, err := windows.UTF16PtrFromString(root)
	if err != nil || windows.GetDriveType(rootUTF16) != windows.DRIVE_FIXED {
		return fmt.Errorf("native package requires a fixed volume")
	}
	if err := inspectStateObject(root, true); err != nil {
		return fmt.Errorf("unsafe native package volume: %w", err)
	}
	relative, err := filepath.Rel(root, path)
	if err != nil || relative == "." || strings.HasPrefix(relative, `..\`) {
		return fmt.Errorf("invalid native package path")
	}
	current := root
	for _, part := range strings.Split(relative, `\`) {
		current = filepath.Join(current, part)
		if err := inspectStateObject(current, current != path); err != nil {
			return fmt.Errorf("unsafe native package component %s: %w", current, err)
		}
	}
	return nil
}

func verifyNativePackageFile(path, expected string) error {
	if !lowerHexLength(expected, 64) {
		return fmt.Errorf("invalid native package digest")
	}
	if err := auditNativePackagePath(path); err != nil {
		return err
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("native package artifact is not a regular file")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != expected {
		return fmt.Errorf("native package artifact digest differs")
	}
	return nil
}

func readNativePackage(enginePath string) (nativePackageManifest, error) {
	var manifest nativePackageManifest
	directory := filepath.Dir(enginePath)
	manifestPath := filepath.Join(directory, "native-package.json")
	if err := auditNativePackagePath(manifestPath); err != nil {
		return manifest, err
	}
	file, err := os.Open(manifestPath)
	if err != nil {
		return manifest, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > nativePackageManifestLimit {
		return manifest, fmt.Errorf("invalid native package manifest file")
	}
	decoder := json.NewDecoder(io.LimitReader(file, nativePackageManifestLimit+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return manifest, fmt.Errorf("invalid native package manifest: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return manifest, fmt.Errorf("trailing native package manifest data")
	}
	if manifest.SchemaVersion != 1 || manifest.ProtocolVersion != nativeProtocolVersion ||
		!lowerHexLength(manifest.BuildID, 40) || manifest.BuildID != nativeBuildID || manifest.BrandID != brandID {
		return manifest, fmt.Errorf("native package differs from this engine build")
	}
	if len(manifest.Files) > 4096 {
		return manifest, fmt.Errorf("native package artifact count exceeds limit")
	}
	for _, required := range []string{filepath.Base(enginePath), "Wootc.Shell.exe", "Wootc.Shell.dll", "Wootc.Shell.pri", "Branding/brand.json"} {
		if _, ok := manifest.Files[required]; !ok {
			return manifest, fmt.Errorf("native package lacks required artifact %s", required)
		}
	}
	seen := map[string]bool{}
	for relative, digest := range manifest.Files {
		if relative == "" || relative == "native-package.json" || strings.ContainsAny(relative, `\:`) ||
			strings.HasPrefix(relative, "/") || relative != filepath.ToSlash(filepath.Clean(filepath.FromSlash(relative))) ||
			strings.HasPrefix(relative, "../") || relative == ".." || !lowerHexLength(digest, 64) {
			return manifest, fmt.Errorf("invalid native package artifact record")
		}
		folded := strings.ToLower(relative)
		if seen[folded] {
			return manifest, fmt.Errorf("ambiguous native package artifact record")
		}
		seen[folded] = true
	}
	observed := map[string]bool{}
	err = filepath.WalkDir(directory, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := inspectStateObject(path, false); err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(directory, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if relative == "native-package.json" {
			return nil
		}
		digest, ok := manifest.Files[relative]
		if !ok {
			return fmt.Errorf("native package has an unrecorded artifact")
		}
		if err := verifyNativePackageFile(path, digest); err != nil {
			return err
		}
		observed[relative] = true
		return nil
	})
	if err != nil {
		return manifest, err
	}
	if len(observed) != len(manifest.Files) {
		return manifest, fmt.Errorf("native package artifact is missing")
	}
	return manifest, nil
}
