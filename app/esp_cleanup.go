package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Validate before normalizing: trimming separators or cleaning dot components
// would turn an invalid manifest claim into an apparently safe destination.
func validateESPRelativeFile(rel string) error {
	rel = strings.ReplaceAll(rel, `\`, "/")
	for _, part := range strings.Split(rel, "/") {
		if part == "" || part == "." || part == ".." || strings.TrimRight(part, " .") != part || strings.ContainsAny(part, ":<>\"|?*\x00\r\n\t") {
			return fmt.Errorf("invalid ESP ownership path %q", rel)
		}
	}
	return nil
}

// Resolve FAT's case-insensitive spelling without following a symlink, and
// reject ambiguous names on test/other filesystems instead of picking one.
func resolveESPCleanupPath(root, rel string) (string, bool, error) {
	if err := validateESPRelativeFile(rel); err != nil {
		return "", false, err
	}
	info, err := os.Lstat(root)
	if err != nil {
		return "", false, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", false, fmt.Errorf("unsafe ESP root")
	}
	current := root
	parts := strings.Split(strings.ReplaceAll(rel, `\`, "/"), "/")
	for i, part := range parts {
		entries, err := os.ReadDir(current)
		if err != nil {
			return "", false, err
		}
		matched := ""
		for _, entry := range entries {
			if strings.EqualFold(entry.Name(), part) {
				if matched != "" {
					return "", false, fmt.Errorf("ambiguous ESP ownership path %q", rel)
				}
				matched = entry.Name()
			}
		}
		if matched == "" {
			return filepath.Join(current, filepath.Join(parts[i:]...)), false, nil
		}
		current = filepath.Join(current, matched)
		info, err = os.Lstat(current)
		if err != nil {
			return "", false, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", false, fmt.Errorf("symlink in ESP ownership path %q", rel)
		}
		if i != len(parts)-1 && !info.IsDir() {
			return "", false, fmt.Errorf("non-directory in ESP ownership path %q", rel)
		}
		if i == len(parts)-1 && !info.Mode().IsRegular() {
			return "", false, fmt.Errorf("ESP ownership claim is not a regular file: %q", rel)
		}
	}
	return current, true, nil
}

// Legacy configs authorize only this fixed historical staging set. A marker
// never grants ownership of a directory or of future files placed beside it.
func legacyESPCleanupClaims(root string) (map[string]bool, error) {
	claims := map[string]bool{}
	for _, vendor := range []string{"fedora", "redhat", "wootc"} {
		rel := "EFI/" + vendor + "/grub.cfg"
		path, exists, err := resolveESPCleanupPath(root, rel)
		if err != nil {
			return nil, err
		}
		if !exists {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if strings.Contains(string(data), wootcGrubOwnership) {
			claims[normalizeESPPath(rel)] = true
			if vendor == "fedora" {
				for _, name := range []string{"shimx64.efi", "grubx64.efi", "mmx64.efi"} {
					claims["efi/fedora/"+name] = true
				}
			}
		}
	}
	rel := "loader/loader.conf"
	path, exists, err := resolveESPCleanupPath(root, rel)
	if err != nil {
		return nil, err
	}
	if exists {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		if strings.Contains(string(data), wootcGrubOwnership) {
			claims[rel] = true
			claims["loader/entries/wootc-deployer.conf"] = true
			claims["loader/entries/wootc.conf"] = true
			for _, name := range []string{"shimx64.efi", "grubx64.efi", "systemd-bootx64.efi"} {
				claims["efi/systemd/"+name] = true
			}
		}
	}
	// Product-specific historical files; other files in EFI/wootc stay intact.
	for _, name := range []string{"deployer-vmlinuz", "deployer-initramfs.img", "phase2-vmlinuz", "phase2-initramfs.img", "wubildr.efi"} {
		claims["efi/wootc/"+name] = true
	}
	return claims, nil
}

func espCleanupClaims(root string) (map[string]bool, string, bool, error) {
	manifest, exists, err := resolveESPCleanupPath(root, espOwnershipManifest)
	if err != nil {
		return nil, "", false, err
	}
	owned, err := readESPOwnershipFile(manifest)
	if err != nil {
		return nil, "", false, err
	}
	legacy, err := legacyESPCleanupClaims(root)
	if err != nil {
		return nil, "", false, err
	}
	// Legacy writers also stage config/kernel files without recording them.
	// Retain only their explicit historical filenames, including mixed installs.
	for rel := range legacy {
		owned[rel] = true
	}
	delete(owned, normalizeESPPath(espOwnershipManifest))
	return owned, manifest, exists, nil
}

func cleanupESPOwnedFiles(root string) error { return cleanupESPOwnedFilesWithRemove(root, os.Remove) }

func cleanupESPOwnedFilesWithRemove(root string, remove func(string) error) error {
	claims, manifest, hasManifest, err := espCleanupClaims(root)
	if err != nil {
		return err
	}
	rels := make([]string, 0, len(claims))
	for rel := range claims {
		if !allowedESPCleanupClaim(rel) {
			return fmt.Errorf("ESP cleanup claim outside product files: %q", rel)
		}
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	// Preflight every claim before deleting any file.
	paths := make([]string, 0, len(rels))
	for _, rel := range rels {
		path, exists, err := resolveESPCleanupPath(root, rel)
		if err != nil {
			return err
		}
		if exists {
			paths = append(paths, path)
		}
	}
	for _, path := range paths {
		if err := remove(path); err != nil {
			return fmt.Errorf("remove owned ESP file: %w", err)
		}
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			return fmt.Errorf("owned ESP file removal not verified: %s", path)
		}
	}
	// Recheck the whole plan: a later operation must not conceal a recreated
	// earlier file before the ownership record is discarded.
	for _, rel := range rels {
		_, exists, err := resolveESPCleanupPath(root, rel)
		if err != nil {
			return err
		}
		if exists {
			return fmt.Errorf("owned ESP file remains after cleanup: %s", rel)
		}
	}
	// Ownership evidence is the retry plan. Never erase it before confirming
	// all its files are absent; a partial failure leaves the complete plan.
	if hasManifest {
		if err := remove(manifest); err != nil {
			return fmt.Errorf("remove ESP ownership manifest: %w", err)
		}
		if _, err := os.Lstat(manifest); !os.IsNotExist(err) {
			return fmt.Errorf("ESP manifest removal not verified")
		}
	}
	return nil
}

// A manifest may never authorize removal of the Windows or firmware fallback
// namespace. New shared-namespace staging destinations require an explicit rule.
func allowedESPCleanupClaim(rel string) bool {
	rel = normalizeESPPath(rel)
	if strings.HasPrefix(rel, "efi/wootc/") {
		return true
	}
	switch rel {
	case "efi/fedora/grub.cfg", "efi/fedora/shimx64.efi", "efi/fedora/grubx64.efi", "efi/fedora/mmx64.efi", "efi/redhat/grub.cfg",
		"efi/systemd/shimx64.efi", "efi/systemd/grubx64.efi", "efi/systemd/systemd-bootx64.efi",
		"loader/loader.conf", "loader/entries/wootc-deployer.conf", "loader/entries/wootc.conf":
		return true
	}
	return false
}

// Namespace existence is not installation evidence: foreign files and empty
// directories preserved by cleanup do not make an installation remain present.
func hasESPOwnedFiles(root string) (bool, error) {
	claims, _, hasManifest, err := espCleanupClaims(root)
	if err != nil {
		return false, err
	}
	if hasManifest {
		return true, nil
	}
	for rel := range claims {
		_, exists, err := resolveESPCleanupPath(root, rel)
		if err != nil {
			return false, err
		}
		if exists {
			return true, nil
		}
	}
	return false, nil
}
