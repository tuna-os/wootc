package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Layer totals of the two images that bracket the deployer failure, as
// `skopeo inspect` reports them (same numbers as deployer-scratch-capacity.bats).
const (
	deckCompressedBytes    int64 = 6757057180 // ghcr.io/ublue-os/bazzite-deck:stable
	bazziteCompressedBytes int64 = 5058316148 // ghcr.io/ublue-os/bazzite:stable
	gibBytes                     = int64(1) << 30
)

func TestScratchNeedGiB(t *testing.T) {
	for _, tc := range []struct {
		bytes int64
		want  int
	}{
		{deckCompressedBytes, 27},
		{bazziteCompressedBytes, 21},
		{gibBytes, 20}, // small images keep the floor
		{0, 20},        // unknown → floor, like the shell
		{-1, 20},
		{scratchDefaultCompressedBytes, 29},
	} {
		if got := scratchNeedGiB(tc.bytes); got != tc.want {
			t.Errorf("scratchNeedGiB(%d) = %d, want %d", tc.bytes, got, tc.want)
		}
	}
	// The default must cover every image we know of, or an unknown size
	// would under-reserve for the very image that motivated this check.
	if scratchNeedGiB(scratchDefaultCompressedBytes) < scratchNeedGiB(deckCompressedBytes) {
		t.Error("the default compressed size reserves less than bazzite-deck needs")
	}
}

// TestScratchNeedMatchesDeployer pins the Go formula to the shell one the
// deployer actually runs: it extracts SCRATCH_MIN_GIB and scratch_need_gib
// from payload/deployer/deploy.sh and compares them value by value. Change
// either side alone and this goes red.
func TestScratchNeedMatchesDeployer(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	src, err := os.ReadFile(filepath.Join("..", "payload", "deployer", "deploy.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(src)
	minLine := regexp.MustCompile(`(?m)^SCRATCH_MIN_GIB=(\d+)$`).FindStringSubmatch(text)
	if minLine == nil {
		t.Fatal("deploy.sh no longer defines SCRATCH_MIN_GIB=<n>")
	}
	if n, _ := strconv.Atoi(minLine[1]); n != scratchMinGiB {
		t.Errorf("deploy.sh SCRATCH_MIN_GIB=%d, Go scratchMinGiB=%d", n, scratchMinGiB)
	}
	fn := regexp.MustCompile(`(?ms)^scratch_need_gib\(\) \{.*?^\}`).FindString(text)
	if fn == "" {
		t.Fatal("deploy.sh no longer defines scratch_need_gib()")
	}
	// The slack ensure_scratch_capacity keeps beyond the growth.
	if !strings.Contains(text, "(( free >= grow + (1 << 30) ))") || scratchDriveSlackGiB != 1 {
		t.Error("deploy.sh's 1 GiB drive slack and scratchDriveSlackGiB disagree")
	}
	samples := []int64{1, gibBytes, 4 * gibBytes, bazziteCompressedBytes, deckCompressedBytes,
		scratchDefaultCompressedBytes, 5*gibBytes + 12345, 9*gibBytes - 1, 9 * gibBytes, 9*gibBytes + 1, 40 * gibBytes}
	script := minLine[0] + "\n" + fn + "\n"
	for _, b := range samples {
		script += fmt.Sprintf("scratch_need_gib %d\n", b)
	}
	out, err := exec.Command(bash, "-c", script).Output()
	if err != nil {
		t.Fatalf("running deploy.sh's scratch_need_gib: %v", err)
	}
	got := strings.Fields(string(out))
	if len(got) != len(samples) {
		t.Fatalf("shell printed %q for %d samples", out, len(samples))
	}
	for i, b := range samples {
		if sh, _ := strconv.Atoi(got[i]); sh != scratchNeedGiB(b) {
			t.Errorf("scratch need for %d bytes: deploy.sh %d GiB, Go %d GiB", b, sh, scratchNeedGiB(b))
		}
	}
}

func TestNewInstallSpaceReserve(t *testing.T) {
	s := newInstallSpace("ref", deckCompressedBytes, "registry", false)
	if s.ScratchGiB != 27 || s.BundleGiB != 0 || s.ReserveGiB != 29 {
		t.Errorf("deck without preload = %+v, want scratch 27, bundle 0, reserve 29", s)
	}
	// A pre-download still to come lands on the same drive and stays there
	// through the deploy.
	s = newInstallSpace("ref", deckCompressedBytes, "registry", true)
	if s.BundleGiB != 7 || s.ReserveGiB != 36 {
		t.Errorf("deck with preload = %+v, want bundle 7, reserve 36", s)
	}
}

// The failure this exists for (E2E run 38821484138): about 65 GiB free on
// the 80G VM's C:, a 40 GB root.disk, bazzite-deck. The deployer found 5 GiB
// beside its 20 GiB scratch and refused after the reboot; Windows must refuse
// first, and say what would fit.
func TestCheckInstallSpaceRefusesWhatTheDeployerWould(t *testing.T) {
	free := uint64(65 * gibBytes)
	deck := newInstallSpace("ghcr.io/ublue-os/bazzite-deck:stable", deckCompressedBytes, "registry", false)
	err := checkInstallSpaceWith("C", 40, free, 0, deck, "Bazzite")
	if err == nil {
		t.Fatal("40 GB root.disk + bazzite-deck scratch on 65 GB free was accepted")
	}
	msg := err.Error()
	for _, want := range []string{"drive C:", "Bazzite", "40 GB", "about 29 GB", "65 GB free", "36 GB or less"} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal %q does not say %q", msg, want)
		}
	}
	for _, banned := range []string{"wootc", "TunaOS", "Bluefin"} {
		if strings.Contains(msg, banned) {
			t.Errorf("refusal names a product %q: %s", banned, msg)
		}
	}
	if err := checkInstallSpaceWith("C", 36, free, 0, deck, "Bazzite"); err != nil {
		t.Errorf("the size the refusal offered is refused too: %v", err)
	}
	// The same drive holds a 40 GB disk for an image at the scratch floor.
	small := newInstallSpace("ghcr.io/tuna-os/yellowfin:gnome", 2*gibBytes, "registry", false)
	if err := checkInstallSpaceWith("C", 40, free, 0, small, "Yellowfin"); err != nil {
		t.Errorf("a floor-sized image does not fit 40 GB on 65 GB free: %v", err)
	}
}

func TestCheckInstallSpaceNoDiskFits(t *testing.T) {
	deck := newInstallSpace("ref", deckCompressedBytes, "registry", false)
	err := checkInstallSpaceWith("D", 20, uint64(40*gibBytes), 0, deck, "")
	if err == nil || !strings.Contains(err.Error(), "Free up space") || strings.Contains(err.Error(), "or less") {
		t.Fatalf("40 GB free cannot hold any disk plus 29 GB; got %v", err)
	}
	if !strings.Contains(err.Error(), "installing Linux") || !strings.Contains(err.Error(), "drive D:") {
		t.Errorf("unbranded refusal should say Linux and name the drive: %v", err)
	}
}

// A scratch an earlier attempt left behind is already counted against free
// space and is reused by the deployer, so it must not be demanded twice.
func TestCheckInstallSpaceCreditsExistingScratch(t *testing.T) {
	deck := newInstallSpace("ref", deckCompressedBytes, "registry", false)
	free := uint64(50 * gibBytes) // 70 before a 20 GiB scratch was left behind
	if err := checkInstallSpaceWith("C", 40, free, 20*gibBytes, deck, "x"); err != nil {
		t.Errorf("existing 20 GiB scratch not credited: %v", err)
	}
	// The credit never exceeds what this image's scratch needs.
	if err := checkInstallSpaceWith("C", 40, uint64(40*gibBytes), 100*gibBytes, deck, "x"); err == nil {
		t.Error("an oversized leftover scratch was credited beyond the image's need")
	}
}

func writeOCIBundle(t *testing.T, dir, image string, layers ...int64) {
	t.Helper()
	descs := []map[string]any{}
	for i, n := range layers {
		descs = append(descs, map[string]any{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
			"digest": fmt.Sprintf("sha256:%064x", i+1), "size": n})
	}
	manifest, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": mtOCIManifest,
		"config": map[string]any{"digest": "sha256:" + strings.Repeat("c", 64), "size": 100}, "layers": descs})
	sum := sha256.Sum256(manifest)
	hexDigest := hex.EncodeToString(sum[:])
	blobs := filepath.Join(dir, "oci", "blobs", "sha256")
	if err := os.MkdirAll(blobs, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(blobs, hexDigest), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	index, _ := json.Marshal(map[string]any{"schemaVersion": 2, "manifests": []map[string]any{
		{"mediaType": mtOCIManifest, "digest": "sha256:" + hexDigest, "size": len(manifest)}}})
	if err := os.WriteFile(filepath.Join(dir, "oci", "index.json"), index, 0o644); err != nil {
		t.Fatal(err)
	}
	info, _ := json.Marshal(BundleInfo{Image: image, Source: "predownload"})
	if err := os.WriteFile(filepath.Join(dir, "bundle.json"), info, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestImageCompressedBytesPrefersStagedBundle(t *testing.T) {
	root := t.TempDir()
	writeOCIBundle(t, filepath.Join(root, "bundle"), "ghcr.io/x/y:1", 3*gibBytes, 2*gibBytes)
	old := imageSizeLookup
	defer func() { imageSizeLookup = old }()
	imageSizeLookup = func(context.Context, string) (int64, error) {
		t.Error("the registry was asked although a bundle is staged")
		return 0, errors.New("unexpected")
	}
	n, src := imageCompressedBytes(context.Background(), root, "ghcr.io/x/y:1")
	if n != 5*gibBytes || src != "bundle" {
		t.Errorf("bundle size = %d (%s), want %d (bundle)", n, src, 5*gibBytes)
	}
	if !bundleStagedFor(root, "ghcr.io/x/y:1") || bundleStagedFor(root, "ghcr.io/x/other:1") {
		t.Error("bundleStagedFor does not match the staged image exactly")
	}
}

func TestImageCompressedBytesRegistryThenDefault(t *testing.T) {
	old := imageSizeLookup
	defer func() { imageSizeLookup = old }()
	calls := 0
	imageSizeLookup = func(_ context.Context, ref string) (int64, error) {
		calls++
		if ref == "ghcr.io/x/down:1" {
			return 0, errors.New("offline")
		}
		return deckCompressedBytes, nil
	}
	root := t.TempDir()
	for i := 0; i < 2; i++ {
		if n, src := imageCompressedBytes(context.Background(), root, "ghcr.io/x/cached:1"); n != deckCompressedBytes || src != "registry" {
			t.Errorf("registry size = %d (%s)", n, src)
		}
	}
	if calls != 1 {
		t.Errorf("registry asked %d times for one ref, want 1 (cached)", calls)
	}
	if n, src := imageCompressedBytes(context.Background(), root, "ghcr.io/x/down:1"); n != scratchDefaultCompressedBytes || src != "default" {
		t.Errorf("unreachable registry = %d (%s), want the documented default", n, src)
	}
	if n, src := imageCompressedBytes(context.Background(), root, ""); n != scratchDefaultCompressedBytes || src != "default" {
		t.Errorf("empty ref = %d (%s), want default without a lookup", n, src)
	}
}

func TestRegistryCompressedBytesSumsPlatformLayers(t *testing.T) {
	manifest, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": mtOCIManifest,
		"config": map[string]any{"digest": "sha256:" + strings.Repeat("c", 64), "size": 999999},
		"layers": []map[string]any{{"digest": "sha256:" + strings.Repeat("1", 64), "size": 4 * gibBytes},
			{"digest": "sha256:" + strings.Repeat("2", 64), "size": 2*gibBytes + 7}}})
	sum := sha256.Sum256(manifest)
	digest := "sha256:" + hex.EncodeToString(sum[:])
	index, _ := json.Marshal(map[string]any{"schemaVersion": 2, "mediaType": mtOCIIndex, "manifests": []map[string]any{
		{"digest": "sha256:" + strings.Repeat("a", 64), "platform": map[string]string{"os": "linux", "architecture": "arm64"}},
		{"digest": digest, "platform": map[string]string{"os": "linux", "architecture": "amd64"}}}})
	var srv *httptest.Server
	blobFetched := false
	srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v2/" && r.Header.Get("Authorization") == "":
			w.Header().Set("Www-Authenticate", `Bearer realm="`+srv.URL+`/token",service="test"`)
			w.WriteHeader(http.StatusUnauthorized)
		case r.URL.Path == "/token":
			json.NewEncoder(w).Encode(map[string]string{"token": "t"})
		case strings.HasSuffix(r.URL.Path, "/manifests/stable"):
			w.Write(index)
		case strings.HasSuffix(r.URL.Path, "/manifests/"+digest):
			w.Write(manifest)
		case strings.Contains(r.URL.Path, "/blobs/"):
			blobFetched = true
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()
	host := strings.TrimPrefix(srv.URL, "https://")
	n, err := registryCompressedBytes(context.Background(), srv.Client(), host+"/org/img:stable")
	if err != nil {
		t.Fatal(err)
	}
	if n != 6*gibBytes+7 {
		t.Errorf("layer total = %d, want %d (config excluded, amd64 manifest)", n, 6*gibBytes+7)
	}
	if blobFetched {
		t.Error("sizing the image downloaded a blob")
	}
}

// End to end through the install gate both the Wails GUI (StartInstall) and
// the native engine use.
func TestValidateInstallConfigRefusesWhenScratchDoesNotFit(t *testing.T) {
	t.Setenv("WOOTC_PRELOAD", "0")
	oldFree, oldLookup := storageFreeBytesFn, imageSizeLookup
	defer func() { storageFreeBytesFn, imageSizeLookup = oldFree, oldLookup }()
	imageSizeLookup = func(context.Context, string) (int64, error) { return deckCompressedBytes, nil }
	var asked string
	storageFreeBytesFn = func(drive string) (uint64, bool) { asked = drive; return uint64(65 * gibBytes), true }

	a := &App{}
	imgs, err := a.GetImages()
	if err != nil || len(imgs) == 0 {
		t.Fatalf("no catalogue: %v", err)
	}
	cfg := InstallConfig{ImageRef: imgs[0].ImageRef, DiskSizeGB: 40, Encryption: "none", Bootloader: "auto",
		Username: "u", Password: "p", StorageDrive: "e:"}
	if _, err := a.validateInstallConfig(cfg); err == nil || !strings.Contains(err.Error(), "36 GB or less") {
		t.Fatalf("validateInstallConfig accepted or mis-explained an install that cannot fit: %v", err)
	}
	if asked != "E" {
		t.Errorf("free space read from drive %q, want the storage drive E", asked)
	}
	cfg.DiskSizeGB = 35
	if _, err := a.validateInstallConfig(cfg); err != nil {
		t.Errorf("35 GB + 29 GB on 65 GB free refused: %v", err)
	}
}

// The launchpad assumes the smallest image's reserve until GetInstallSpace
// answers; that constant must stay the engine's.
func TestLaunchpadMinimumReserveMatchesEngine(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("frontend", "src", "screens", "launchpad.js"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^const MIN_INSTALL_RESERVE_GB = (\d+);`).FindSubmatch(src)
	if m == nil {
		t.Fatal("launchpad.js no longer defines MIN_INSTALL_RESERVE_GB")
	}
	if n, _ := strconv.Atoi(string(m[1])); n != minimumInstallReserveGiB {
		t.Errorf("launchpad.js MIN_INSTALL_RESERVE_GB=%d, engine minimumInstallReserveGiB=%d", n, minimumInstallReserveGiB)
	}
	if got := newInstallSpace("", 1, "registry", false).ReserveGiB; got != minimumInstallReserveGiB {
		t.Errorf("smallest image reserve = %d, want minimumInstallReserveGiB %d", got, minimumInstallReserveGiB)
	}
}
