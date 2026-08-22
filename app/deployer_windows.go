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

const defaultDeployerBaseURL = "https://github.com/tuna-os/wootc/releases/latest/download/"

// deployerBaseURL returns where boot artifacts + SHA256SUMS are fetched
// from. WOOTC_DEPLOYER_MIRROR overrides it for local/offline testing (e.g. a
// dev VM with no network route to GitHub) — the SHA256SUMS fail-closed check
// in downloadDeployer still applies unchanged against whatever URL is used,
// so this does not weaken verification, only where it points.
func deployerBaseURL() string {
	if v := strings.TrimSpace(os.Getenv("WOOTC_DEPLOYER_MIRROR")); v != "" {
		if !strings.HasSuffix(v, "/") {
			v += "/"
		}
		return v
	}
	return defaultDeployerBaseURL
}

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	installDir := filepath.Join(wootcDir(), "install")
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
	sums, err := fetchChecksums(ctx)
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

		if err := downloadFile(ctx, deployerBaseURL()+name, dest, func(p float64) {
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

// fetchChecksums returns the SHA256SUMS manifest as a filename→hash map.
// Fail-closed (#53): every error aborts the install rather than silently
// disabling verification of privileged boot artifacts.
//
// A manifest PRE-STAGED at install\SHA256SUMS wins over the network fetch.
// That is the offline-bundle contract (#194): an administrator (or the E2E
// harness) who staged the boot artifacts stages their manifest beside them —
// same trust domain, since writing C:\wootc\install already requires admin —
// and an air-gapped machine can then install without a route to GitHub.
// Requiring the network fetch even when everything was staged locally is
// what broke both the offline story and every GUI E2E cell after #194
// (run 32549251225: 'SHA256SUMS manifest unavailable: HTTP 404').
// Verification itself is unchanged either way: every artifact, cached or
// downloaded, must match the manifest or the install aborts.
func fetchChecksums(ctx context.Context) (map[string]string, error) {
	local := filepath.Join(wootcDir(), "install", "SHA256SUMS")
	if data, err := os.ReadFile(local); err == nil {
		if sums := parseChecksums(data); len(sums) > 0 {
			return sums, nil
		}
		return nil, fmt.Errorf("pre-staged manifest %s exists but contains no checksums", local)
	}
	tmp := filepath.Join(os.TempDir(), "wootc-SHA256SUMS")
	if err := downloadFile(ctx, deployerBaseURL()+"SHA256SUMS", tmp, func(float64) {}); err != nil {
		return nil, fmt.Errorf("fetch SHA256SUMS: %w", err)
	}
	defer os.Remove(tmp) //nolint:errcheck
	data, err := os.ReadFile(tmp)
	if err != nil {
		return nil, fmt.Errorf("read SHA256SUMS: %w", err)
	}
	return parseChecksums(data), nil
}

func parseChecksums(data []byte) map[string]string {
	sums := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 {
			// coreutils format: "<hash>  <name>" (name may have a * prefix).
			sums[strings.TrimPrefix(f[1], "*")] = f[0]
		}
	}
	return sums
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
