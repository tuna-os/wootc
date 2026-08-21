package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Offline image bundle (#177).
//
// A release may ship a pre-staged image store beside wootc.exe so the
// migration needs no network after the initial download. The deployer picks it
// up from C:\wootc\bundle\ and hands it to fisherman as an
// additionalImageStores path, which bootc bind-mounts read-only — so podman
// resolves the image locally instead of pulling several gigabytes from inside
// a stripped initramfs, the step most likely to strand a user mid-migration.
//
// Everything here is best-effort by design. A missing, unreadable or
// mismatched bundle must never block an install: falling back to the network
// still works, whereas refusing would turn a merely-suboptimal bundle into a
// failed migration.

// BundleInfo describes a staged offline image bundle. Written by
// payload/bundle/make-bundle.sh as bundle.json.
type BundleInfo struct {
	// Image is the reference the store holds, e.g. ghcr.io/tuna-os/dakota:latest.
	Image string `json:"image"`
	// Digest pins exactly what will be installed. A tag can be re-pointed
	// upstream, so someone installing offline months later needs this to know
	// what they are actually booting.
	Digest string `json:"digest"`
	// StoreBytes is the on-disk size, for showing the user what the bundle
	// saves them downloading.
	StoreBytes int64  `json:"storeBytes"`
	CreatedAt  string `json:"createdAt"`
}

// bundleDir is where the deployer looks: C:\wootc\bundle.
func bundleDir() string { return filepath.Join(wootcDir(), "bundle") }

// readBundleInfo returns the staged bundle, or nil when there is none.
func readBundleInfo() *BundleInfo { return readBundleInfoAt(bundleDir()) }

// readBundleInfoAt is the testable core. Split out because wootcDir() is a
// fixed path per platform, so the only way to exercise the failure modes below
// is to point the lookup somewhere else.
//
// Requires BOTH bundle.json and a store/ directory: bundle.json alone
// describes a bundle whose payload never made it across, and treating that as
// usable would make the deployer skip the pull and then find no image.
func readBundleInfoAt(dir string) *BundleInfo {
	data, err := os.ReadFile(filepath.Join(dir, "bundle.json"))
	if err != nil {
		return nil
	}
	var b BundleInfo
	if err := json.Unmarshal(data, &b); err != nil {
		return nil
	}
	if b.Image == "" {
		return nil
	}
	if st, err := os.Stat(filepath.Join(dir, "store")); err != nil || !st.IsDir() {
		return nil
	}
	return &b
}

// GetBundleInfo reports the staged offline bundle to the GUI, or nil. The
// launchpad uses it to say the chosen image needs no download — and, when the
// bundle is for a different image than the one selected, to avoid implying an
// offline install that will not happen.
func (a *App) GetBundleInfo() *BundleInfo { return readBundleInfo() }
