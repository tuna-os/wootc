package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ── Space the deployer needs beside root.disk ────────────────────────────────
//
// root.disk is not the only thing that lands on the storage drive. After the
// reboot the deployer creates its container scratch
// (<drive>:\wootc\cache\deployer-scratch.img, fully allocated: ntfs3 has no
// sparse files) and grows it to fit the selected image before the first pull
// (payload/deployer/deploy.sh, ensure_scratch_capacity). When the drive cannot
// hold that it stops with "[FAIL] … needs about N GiB of temporary space on
// the Windows drive" — correct, but only AFTER the user has rebooted away from
// Windows (E2E run 38821484138: a 40 GB root.disk left 5 GiB free beside the
// 20 GiB scratch, and bazzite-deck:stable needs 27). This preflight asks the
// same question while Windows is still running and can still say so.

const (
	// scratchMinGiB is deploy.sh's SCRATCH_MIN_GIB: the scratch is created at
	// this size whatever the image. Pinned by TestScratchNeedMatchesDeployer.
	scratchMinGiB = 20
	// scratchDriveSlackGiB is the 1 GiB ensure_scratch_capacity keeps free on
	// the drive beyond the growth (`free >= grow + (1 << 30)`).
	scratchDriveSlackGiB = 1
	// deployerArtifactsGiB covers what the install still writes to the drive
	// after this check: the deployer kernel + initramfs and the EFI loaders
	// in <drive>:\wootc\install (well under 1 GiB today).
	deployerArtifactsGiB = 1
	// scratchDefaultCompressedBytes is the image size assumed when neither a
	// staged bundle nor the registry can say (offline, registry down, a
	// private ref). It sits above the largest catalogued image —
	// bazzite-deck:stable, 6.29 GiB of compressed layers — so an unknown size
	// errs toward refusing on Windows rather than failing after the reboot:
	// 7 GiB → 3.5×7 + 4 = 28.5 → 29 GiB of scratch.
	scratchDefaultCompressedBytes int64 = 7 << 30
	// minimumInstallReserveGiB is the reserve of the smallest image: the
	// scratch floor plus slack and deployer artifacts. A volume-level limit
	// (the native engine's MaximumRootDiskSizeGB) can subtract no less.
	minimumInstallReserveGiB = scratchMinGiB + scratchDriveSlackGiB + deployerArtifactsGiB
	// imageSizeLookupTimeout bounds the registry manifest read (a token and
	// one or two small manifests, no blobs).
	imageSizeLookupTimeout = 20 * time.Second
)

// scratchNeedGiB mirrors deploy.sh scratch_need_gib: the peak of one pull of
// an image whose layers total `compressed` bytes is the staged compressed
// blobs plus the unpacked layers, sized as 3.5× compressed + 4 GiB (rounded
// up), never below the 20 GiB floor. A zero/negative size means "unknown" and
// gets the floor, exactly as the shell does. The two are pinned to each other
// by TestScratchNeedMatchesDeployer, which runs the shell function.
func scratchNeedGiB(compressed int64) int {
	if compressed <= 0 {
		return scratchMinGiB
	}
	const gib = int64(1) << 30
	if compressed > 1<<50 { // no overflow in the ×7 below; no real image is a PiB
		compressed = 1 << 50
	}
	need := (compressed*7/2+gib-1)/gib + 4
	if need < scratchMinGiB {
		need = scratchMinGiB
	}
	return int(need)
}

// InstallSpace is what installing one image needs on the storage drive in
// addition to root.disk. The launchpad lowers its largest offered disk size by
// ReserveGiB; validateInstallConfig refuses a plan that does not fit.
type InstallSpace struct {
	ImageRef string `json:"imageRef"`
	// CompressedBytes is the image's layer total the reserve was sized from.
	CompressedBytes int64 `json:"compressedBytes"`
	// SizeSource says where that number came from: "bundle" (an OCI layout
	// already staged for this image), "registry" (its manifest), or
	// "default" (scratchDefaultCompressedBytes, size unknown).
	SizeSource string `json:"sizeSource"`
	// ScratchGiB is the deployer's scratch for this image (scratchNeedGiB).
	ScratchGiB int `json:"scratchGiB"`
	// BundleGiB is the offline copy of the image still to be downloaded to
	// the drive before the reboot (0 when preload is off or already staged).
	BundleGiB int `json:"bundleGiB"`
	// ReserveGiB = ScratchGiB + BundleGiB + slack + deployer artifacts: the
	// free space the drive must keep beside root.disk until the deploy ends.
	ReserveGiB int `json:"reserveGiB"`
}

func newInstallSpace(imageRef string, compressed int64, source string, bundlePending bool) InstallSpace {
	s := InstallSpace{ImageRef: imageRef, CompressedBytes: compressed, SizeSource: source}
	s.ScratchGiB = scratchNeedGiB(compressed)
	if bundlePending && compressed > 0 {
		s.BundleGiB = int((compressed + (1 << 30) - 1) >> 30)
	}
	s.ReserveGiB = s.ScratchGiB + s.BundleGiB + scratchDriveSlackGiB + deployerArtifactsGiB
	return s
}

// ── Learning the image's compressed size cheaply ─────────────────────────────

var imageSizeCache = struct {
	sync.Mutex
	bytes map[string]int64
}{bytes: map[string]int64{}}

// imageSizeLookup is swapped by tests; production reads the registry.
var imageSizeLookup = func(ctx context.Context, imageRef string) (int64, error) {
	return registryCompressedBytes(ctx, &http.Client{Timeout: imageSizeLookupTimeout}, imageRef)
}

// imageCompressedBytes returns the image's layer total and where it came
// from: an OCI layout already staged for this image under wootcRoot\bundle,
// else its registry manifest (cached per ref for the process), else the
// documented default.
func imageCompressedBytes(ctx context.Context, wootcRoot, imageRef string) (int64, string) {
	if imageRef == "" {
		return scratchDefaultCompressedBytes, "default"
	}
	if n := stagedBundleCompressedBytes(filepath.Join(wootcRoot, "bundle"), imageRef); n > 0 {
		return n, "bundle"
	}
	imageSizeCache.Lock()
	n, ok := imageSizeCache.bytes[imageRef]
	imageSizeCache.Unlock()
	if ok {
		return n, "registry"
	}
	ctx, cancel := context.WithTimeout(ctx, imageSizeLookupTimeout)
	defer cancel()
	if n, err := imageSizeLookup(ctx, imageRef); err == nil && n > 0 {
		imageSizeCache.Lock()
		imageSizeCache.bytes[imageRef] = n
		imageSizeCache.Unlock()
		return n, "registry"
	} else if err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] could not read the size of %s (%v); assuming %d GiB compressed\n",
			imageRef, err, scratchDefaultCompressedBytes>>30)
	}
	return scratchDefaultCompressedBytes, "default"
}

// registryCompressedBytes sums the linux/amd64 manifest's layer sizes — what
// `skopeo inspect` reports as LayersData[].Size in the deployer. Manifests
// only; no blob is downloaded.
func registryCompressedBytes(ctx context.Context, client *http.Client, imageRef string) (int64, error) {
	host, repo, ref, err := registryRef(imageRef)
	if err != nil {
		return 0, err
	}
	p := &ociPuller{client: client, host: host, repo: repo}
	if err := p.authorize(ctx); err != nil {
		return 0, err
	}
	raw, _, err := p.fetchManifest(ctx, ref)
	if err != nil {
		return 0, err
	}
	return manifestLayerBytes(raw)
}

func manifestLayerBytes(raw []byte) (int64, error) {
	var m ociManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return 0, fmt.Errorf("parse manifest: %w", err)
	}
	var total int64
	for _, l := range m.Layers {
		if l.Size < 0 {
			return 0, fmt.Errorf("manifest has a negative layer size")
		}
		total += l.Size
	}
	if total == 0 {
		return 0, fmt.Errorf("manifest lists no layers")
	}
	return total, nil
}

// stagedBundleCompressedBytes reads the layer total of an OCI layout bundle
// staged for imageRef (the app's own pre-download, or a shipped one in that
// form), or 0 when there is none. This is the layout the deployer sizes its
// scratch from (`ensure_scratch_capacity "oci:${BUNDLE_OCI}"`).
func stagedBundleCompressedBytes(dir, imageRef string) int64 {
	b := readBundleInfoAt(dir)
	if b == nil || b.Image != imageRef {
		return 0
	}
	oci := filepath.Join(dir, "oci")
	idx, err := os.ReadFile(filepath.Join(oci, "index.json"))
	if err != nil {
		return 0
	}
	var index ociManifest
	if json.Unmarshal(idx, &index) != nil || len(index.Manifests) == 0 {
		return 0
	}
	digest := index.Manifests[0].Digest
	hex, ok := strings.CutPrefix(digest, "sha256:")
	if !ok || hex == "" || strings.ContainsAny(hex, `/\.`) {
		return 0
	}
	raw, err := os.ReadFile(filepath.Join(oci, "blobs", "sha256", hex))
	if err != nil {
		return 0
	}
	n, err := manifestLayerBytes(raw)
	if err != nil {
		return 0
	}
	return n
}

// bundleStagedFor reports whether wootcRoot already holds an offline copy of
// imageRef, so the pre-download will not need the space again.
func bundleStagedFor(wootcRoot, imageRef string) bool {
	b := readBundleInfoAt(filepath.Join(wootcRoot, "bundle"))
	return b != nil && b.Image == imageRef
}

// installSpaceAt sizes the reserve for imageRef on the drive whose wootc
// directory is wootcRoot.
func installSpaceAt(ctx context.Context, wootcRoot, imageRef string) InstallSpace {
	compressed, source := imageCompressedBytes(ctx, wootcRoot, imageRef)
	pending := shouldPreloadImage(effectiveBranding()) && !bundleStagedFor(wootcRoot, imageRef)
	return newInstallSpace(imageRef, compressed, source, pending)
}

// GetInstallSpace tells the launchpad how much of C:'s free space installing
// imageRef needs beyond the Linux disk, so it never offers a disk size the
// deployer would refuse after the reboot.
func (a *App) GetInstallSpace(imageRef string) InstallSpace {
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	return installSpaceAt(ctx, storageWootcDir(""), imageRef)
}

// ── The preflight ────────────────────────────────────────────────────────────

// storageFreeBytesFn reads a drive's free space; tests swap it.
var storageFreeBytesFn = storageFreeBytes

// checkInstallSpaceWith is the pure decision. free is the drive's free space
// now; existingScratch is a deployer scratch file a previous attempt left on
// the drive (already counted against free, and reused by the deployer).
func checkInstallSpaceWith(drive string, diskSizeGB int, free uint64, existingScratch int64, space InstallSpace, distro string) error {
	const gib = uint64(1) << 30
	if diskSizeGB <= 0 {
		return nil // the size itself is refused elsewhere
	}
	reserve := uint64(space.ReserveGiB) * gib
	if existingScratch > 0 {
		credit := uint64(existingScratch)
		if most := uint64(space.ScratchGiB) * gib; credit > most {
			credit = most
		}
		reserve -= credit
	}
	need := uint64(diskSizeGB)*gib + reserve
	if free >= need {
		return nil
	}
	if distro == "" {
		distro = "Linux"
	}
	freeGB := int(free / gib)
	largest := int((free - min(free, reserve)) / gib)
	advice := "Free up space on the drive, then try again."
	if largest >= 20 {
		advice = fmt.Sprintf("Choose a Linux disk of %d GB or less, or free up space on the drive, then try again.", largest)
	}
	return fmt.Errorf("not enough free space on drive %s: installing %s needs %d GB for its disk plus about %d GB of "+
		"working space to unpack it after the restart (given back when the install finishes), and the drive has %d GB free. %s",
		drive+":", distro, diskSizeGB, space.ReserveGiB, freeGB, advice)
}

// checkInstallSpace refuses, before anything is written, an install whose
// root.disk and deployer scratch cannot both fit on the storage drive. On a
// platform that cannot read free space (the dev build) it checks nothing.
func checkInstallSpace(ctx context.Context, cfg InstallConfig) error {
	drive := strings.ToUpper(strings.TrimSuffix(strings.TrimSpace(cfg.StorageDrive), ":"))
	if drive == "" {
		drive = "C"
	}
	free, ok := storageFreeBytesFn(drive)
	if !ok {
		return nil
	}
	root := storageWootcDir(drive)
	var existing int64
	if st, err := os.Stat(filepath.Join(root, "cache", "deployer-scratch.img")); err == nil && st.Mode().IsRegular() {
		existing = st.Size()
	}
	space := installSpaceAt(ctx, root, cfg.ImageRef)
	return checkInstallSpaceWith(drive, cfg.DiskSizeGB, free, existing, space, effectiveBranding().Name)
}
