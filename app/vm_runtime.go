package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"wootc/internal/artifactauth"
)

// verifyVMRuntime authenticates the complete private runtime tree, including
// dependencies loaded by QEMU. Merely hashing the main executable is not enough.
// The release signer uses the same embedded key as boot artifacts. Canonical
// relative paths are matched exactly; case-insensitive collisions are rejected.
func verifyVMRuntime(root, publicKey string) error {
	data, err := readLocalMetadata(filepath.Join(root, "SHA256SUMS"), artifactauth.MaxManifestSize)
	if err != nil {
		return fmt.Errorf("signed VM runtime manifest unavailable: %w", err)
	}
	sig, err := readLocalMetadata(filepath.Join(root, "SHA256SUMS.sig"), 64)
	if err != nil {
		return err
	}
	expected, err := artifactauth.Verify(publicKey, data, sig)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	verified := map[string]bool{}
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("runtime contains a symbolic link: %s", path)
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return fmt.Errorf("runtime contains a nonregular file: %s", path)
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		name := filepath.ToSlash(relative)
		if path == filepath.Join(root, "SHA256SUMS") || path == filepath.Join(root, "SHA256SUMS.sig") {
			return nil
		}
		folded := strings.ToLower(name)
		if seen[folded] {
			return fmt.Errorf("duplicate runtime path: %s", name)
		}
		seen[folded] = true
		checksum, ok := expected[name]
		if !ok {
			return fmt.Errorf("runtime file is not signed: %s", name)
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		hash := sha256.New()
		_, err = io.Copy(hash, f)
		f.Close()
		if err != nil {
			return err
		}
		if hex.EncodeToString(hash.Sum(nil)) != checksum {
			return fmt.Errorf("runtime checksum mismatch: %s", name)
		}
		verified[name] = true
		return nil
	})
	if err != nil {
		return err
	}
	for name := range expected {
		if !verified[name] {
			return fmt.Errorf("signed runtime file is missing: %s", name)
		}
	}
	return nil
}
