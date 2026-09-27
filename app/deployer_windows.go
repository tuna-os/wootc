//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ── Deployer download ─────────────────────────────────────────────────────────

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	return downloadDeployerTo(ctx, filepath.Join(wootcDir(), "install"), progress)
}

func downloadDeployerTo(ctx context.Context, installDir string, progress func(float64)) error {
	// The signed shim+grub pair carries the Secure Boot chain; mmx64.efi
	// (MokManager) lets shim complete the MOK enrollment that custom-kernel
	// images queue during deploy (#248); wubildr.efi remains only for the
	// legacy NTFS fallback path.
	files := []string{"deployer-vmlinuz", "deployer-initramfs.img", "shimx64.efi", "grubx64.efi", "mmx64.efi", "wubildr.efi"}

	// The SHA256SUMS manifest is REQUIRED for production boot artifacts (#53).
	// These files become privileged kernel/initramfs/EFI inputs; wootc must
	// never install a boot artifact it cannot verify. This is fail-closed:
	// an unreachable manifest, a missing entry, a corrupt cache, and a
	// checksum mismatch all abort the install.
	sums, err := fetchArtifactChecksums(ctx, installDir)
	if err != nil {
		return fmt.Errorf("cannot verify boot artifacts: SHA256SUMS manifest unavailable: %w", err)
	}

	for i, name := range files {
		dest := filepath.Join(installDir, name)
		want, inManifest := sums[name]
		if !inManifest {
			// wubildr.efi is the one genuinely optional artifact: the release
			// pipeline builds it best-effort (the signed shim+grub chain is
			// the real boot path), so a release may legitimately ship
			// without it. Absent from the manifest → skip it; PRESENT in the
			// manifest, it is verified exactly like everything else. Every
			// other artifact stays fail-closed (#53): no manifest entry, no
			// install.
			if isOptionalArtifact(name) {
				// Later staging checks file existence. An optional cache not
				// authenticated by this manifest must not reach the ESP.
				if err := os.Remove(dest); err != nil && !os.IsNotExist(err) {
					return fmt.Errorf("remove unverified optional artifact %s: %w", name, err)
				}
				progress(float64(i+1) / float64(len(files)))
				continue
			}
			return fmt.Errorf("checksum not found in manifest for %s: refusing to install an unverified boot artifact", name)
		}

		// Verify cached file before reuse (#53). A stale or corrupt cache must
		// not be accepted as a privileged boot input.
		if _, statErr := os.Stat(dest); statErr == nil {
			got, hashErr := sha256File(dest)
			if hashErr != nil {
				// Corrupt or unreadable cache — remove and re-download.
				os.Remove(dest) //nolint:errcheck
			} else if strings.EqualFold(got, want) {
				progress(float64(i+1) / float64(len(files)))
				continue
			}
			// Checksum mismatch on cached file — remove and re-download.
			os.Remove(dest) //nolint:errcheck
		}

		if err := downloadBootArtifact(ctx, deployerBaseURL()+name, dest, func(p float64) {
			base := float64(i) / float64(len(files))
			progress(base + p/float64(len(files)))
		}); err != nil {
			return fmt.Errorf("download %s: %w", name, err)
		}
		// Verify freshly downloaded file against the manifest (fail-closed).
		got, err := sha256File(dest)
		if err != nil {
			return fmt.Errorf("hashing %s: %w", name, err)
		}
		if !strings.EqualFold(got, want) {
			os.Remove(dest) //nolint:errcheck — don't leave a bad artifact
			return fmt.Errorf("checksum mismatch for %s: the download may be corrupt or tampered "+
				"(expected %s, got %s)", name, want[:12], got[:12])
		}
	}
	return nil
}

// isOptionalArtifact names the boot artifacts an install can proceed
// without. Only wubildr.efi qualifies — it serves the legacy NTFS fallback
// path; the Secure Boot chain (shim+grub) and the deployer pair are the
// install.
func isOptionalArtifact(name string) bool { return name == "wubildr.efi" || name == "mmx64.efi" }

// fetchChecksums authenticates both staged and downloaded manifests.
func fetchChecksums(ctx context.Context) (map[string]string, error) {
	return fetchArtifactChecksums(ctx, filepath.Join(wootcDir(), "install"))
}

// sha256File returns the lowercase hex SHA-256 of a file.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
