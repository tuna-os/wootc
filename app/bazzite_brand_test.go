package main

// The Bazzite-branded build (-X main.brandID=bazzite, Bazzite-Installer.exe)
// end to end on the Go side: identity, catalog, channel gate, MOK warning,
// offline preload, the Windows-facing strings, and assets that never reach
// for the network. Each test sets brandID itself, exactly as the ldflag does,
// and clears the runtime overlay files in wootcDir() that would otherwise
// mask the embedded brand.

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// asBazziteBuild makes this test binary behave like Bazzite-Installer.exe.
func asBazziteBuild(t *testing.T) {
	t.Helper()
	old := brandID
	brandID = "bazzite"
	t.Cleanup(func() { brandID = old })
	// The runtime overlays win over the embedded brand; a leftover from
	// another test (or a dev machine) would make these tests assert the
	// overlay, not the build.
	for _, name := range []string{"brand.json", "brand.css", "images.json", "channel.txt"} {
		path := filepath.Join(wootcDir(), name)
		saved, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if err := os.Remove(path); err != nil {
			t.Fatalf("clear overlay %s: %v", path, err)
		}
		t.Cleanup(func() { _ = os.WriteFile(path, saved, 0o644) })
	}
	t.Setenv("WOOTC_PRELOAD", "")
	t.Setenv("WOOTC_E2E_DRIVE", "")
}

func TestBazziteBuild_WearsItsOwnIdentity(t *testing.T) {
	asBazziteBuild(t)
	b := effectiveBranding()
	if b.Name != "Bazzite" || b.ProductName != "Bazzite Installer" || b.ExeName != "Bazzite-Installer" {
		t.Fatalf("bazzite build identity = %q / %q / %q", b.Name, b.ProductName, b.ExeName)
	}
	if productName() != "Bazzite Installer" {
		t.Errorf("productName() = %q, want Bazzite Installer", productName())
	}
	// The real mark, the typeface and the deep theme are compiled in.
	if !strings.HasPrefix(b.LogoDataURI, "data:image/svg+xml;base64,") {
		t.Errorf("logo not embedded: %.40q", b.LogoDataURI)
	}
	if !strings.HasPrefix(b.FontDataURI, "data:font/woff2;base64,") {
		t.Errorf("font not embedded: %.40q", b.FontDataURI)
	}
	if !strings.Contains(b.ThemeCSS, "--bg:          #0f0f0f") {
		t.Errorf("theme.css not embedded or not Bazzite's ground")
	}
	for field, v := range map[string]string{
		"name": b.Name, "productName": b.ProductName, "exeName": b.ExeName,
		"tagline": b.Tagline, "publisher": b.Publisher, "fileDescription": b.FileDescription,
	} {
		if strings.Contains(strings.ToLower(v), "wootc") {
			t.Errorf("bazzite %s %q says wootc", field, v)
		}
	}
}

// The catalog a Bazzite user is offered: Bazzite and Bazzite Deck, in that
// order, Bazzite first and selected — never Bluefin, never a custom ref.
func TestBazziteBuild_OffersOnlyBazziteImages(t *testing.T) {
	asBazziteBuild(t)
	want := []struct{ id, ref string }{
		{"bazzite", "ghcr.io/ublue-os/bazzite:stable"},
		{"bazzite-deck", "ghcr.io/ublue-os/bazzite-deck:stable"},
	}
	for _, channel := range []string{"beta", "stable"} {
		t.Setenv("WOOTC_CHANNEL", channel)
		got, err := NewApp().GetImages()
		if err != nil {
			t.Fatalf("%s: GetImages: %v", channel, err)
		}
		if len(got) != len(want) {
			t.Fatalf("%s: bazzite build offers %d images, want %d: %+v", channel, len(got), len(want), got)
		}
		for i, w := range want {
			img := got[i]
			if img.ID != w.id || img.ImageRef != w.ref {
				t.Errorf("%s: image %d = %s (%s), want %s (%s)", channel, i, img.ID, img.ImageRef, w.id, w.ref)
			}
			// Bazzite ships a GRUB2 / ostree image with a custom kernel:
			// the deployer must take the 3-partition GRUB2 path and queue
			// Universal Blue's MOK enrollment (#248).
			if img.Bootloader != "grub2" || img.ComposeFS {
				t.Errorf("%s: %s boot stack = %s composefs=%v, want grub2 without composefs", channel, img.ID, img.Bootloader, img.ComposeFS)
			}
			if img.MokEnroll != "universalblue" {
				t.Errorf("%s: %s mokEnroll = %q, want universalblue", channel, img.ID, img.MokEnroll)
			}
			if !imageNeedsMok(img.ImageRef) {
				t.Errorf("%s: imageNeedsMok(%s) = false; the deployer would not queue the enrollment", channel, img.ImageRef)
			}
		}
		if pol := NewApp().GetSupportPolicy(); pol.CustomImageAllowed {
			t.Errorf("%s: bazzite build allows a custom image ref: %+v", channel, pol)
		}
	}
	if d := effectiveBranding().DefaultImage; d != "bazzite" {
		t.Errorf("default image = %q, want bazzite", d)
	}
}

// The default channel is alpha, which offers green images only. A Bazzite
// installer that offered nothing — or whose pre-selected card is gated out —
// would install the generic default or nothing at all. The default image
// must survive the gate the build ships with.
func TestBazziteBuild_DefaultChannelStillOffersTheDefaultImage(t *testing.T) {
	asBazziteBuild(t)
	t.Setenv("WOOTC_CHANNEL", "")
	if c := supportChannel(); c != "alpha" {
		t.Fatalf("default channel = %q; this test pins the alpha gate", c)
	}
	got, err := NewApp().GetImages()
	if err != nil {
		t.Fatalf("GetImages: %v", err)
	}
	if len(got) == 0 {
		t.Fatal("the Bazzite installer offers no image on the default channel")
	}
	if got[0].ID != effectiveBranding().DefaultImage {
		t.Errorf("first offered image = %s, want the brand default %s", got[0].ID, effectiveBranding().DefaultImage)
	}
	for _, img := range got {
		if img.Status != "green" {
			t.Errorf("alpha offered non-green %s (%s)", img.ID, img.Status)
		}
		if !strings.HasPrefix(img.ImageRef, "ghcr.io/ublue-os/bazzite") {
			t.Errorf("alpha bazzite build offered a foreign image %s", img.ImageRef)
		}
	}
}

// Offline-first: a branded build fetches the image on Windows, because the
// deployer has no Wi-Fi. WOOTC_PRELOAD=0 is the harness's off switch only.
func TestBazziteBuild_PreloadsTheImageOnWindows(t *testing.T) {
	asBazziteBuild(t)
	b := effectiveBranding()
	if !shouldPreloadImage(b) {
		t.Error("bazzite build does not preload its image; the deployer would need a network")
	}
	t.Setenv("WOOTC_PRELOAD", "0")
	if shouldPreloadImage(b) {
		t.Error("WOOTC_PRELOAD=0 must disable the preload even for a branded build")
	}
	t.Setenv("WOOTC_PRELOAD", "")
	generic := defaultBranding()
	if shouldPreloadImage(generic) {
		t.Error("the generic build preloads without opting in")
	}
	t.Setenv("WOOTC_PRELOAD", "1")
	if !shouldPreloadImage(generic) {
		t.Error("WOOTC_PRELOAD=1 must opt the generic build in")
	}
}

// What Windows itself shows for this install: the Apps & features entry and
// the restart notice. Neither may say a word the Bazzite user never saw.
func TestBazziteBuild_WindowsSurfacesNeverSayWootc(t *testing.T) {
	asBazziteBuild(t)
	b := effectiveBranding()
	if got := uninstallDisplayName(b); got != "Bazzite" {
		t.Errorf("Add/Remove entry = %q, want Bazzite", got)
	}
	if got := rebootMessage(b); got != "Bazzite Installer is rebooting to start the installer" {
		t.Errorf("restart notice = %q", got)
	}
	// The generic build keeps its documented listing.
	if got := uninstallDisplayName(defaultBranding()); got != "TunaOS (wootc)" {
		t.Errorf("generic Add/Remove entry = %q, want TunaOS (wootc)", got)
	}
}

// Every recovery message the interrupted screen can show a Bazzite user.
func TestBazziteBuild_RecoveryMessagesNeverSayWootc(t *testing.T) {
	asBazziteBuild(t)
	running := JournalRunning
	observations := []InstallObservation{}
	for _, outcome := range []string{JournalRunning, JournalCancelled, JournalFailed} {
		for _, touched := range []bool{false, true} {
			j := InstallJournal{Outcome: outcome}
			if touched {
				j.CompletedSteps = []string{StepInstallerGettingLinuxPrepared}
			}
			observations = append(observations, InstallObservation{Journal: &j})
		}
	}
	observations = append(observations,
		InstallObservation{Journal: &InstallJournal{Outcome: running}, JournalOwnerUp: true},
		InstallObservation{State: &LifecycleState{State: StateFailed}},
		InstallObservation{State: &LifecycleState{State: StateStaged}},
	)
	seen := 0
	for _, o := range observations {
		r := classifyInstall(o)
		if r.Message == "" {
			continue
		}
		seen++
		for _, text := range []string{r.Title, r.Message} {
			if strings.Contains(strings.ToLower(text), "wootc") {
				t.Errorf("bazzite build recovery text says wootc: %q", text)
			}
		}
	}
	if seen < 5 {
		t.Fatalf("only %d recovery messages exercised; the observations no longer reach the classifier's branches", seen)
	}
}

// The mark, typeface and theme are compiled in and must not reach for the
// network at run time: no remote href in the SVG, no @import or remote url()
// in the CSS, and the font is a real WOFF2 file.
func TestBazziteBuild_AssetsNeverFetchAtRuntime(t *testing.T) {
	logo, err := brandFS.ReadFile("branding/bazzite/logo.svg")
	if err != nil {
		t.Fatal(err)
	}
	// xmlns declarations are names, not fetches; strip them before looking.
	stripped := regexp.MustCompile(`xmlns(:\w+)?="[^"]*"`).ReplaceAll(logo, nil)
	stripped = regexp.MustCompile(`<!DOCTYPE[^>]*>`).ReplaceAll(stripped, nil)
	if m := regexp.MustCompile(`(?i)(href\s*=\s*"(https?:)?//|<image\b|url\(\s*['"]?(https?:)?//)`).Find(stripped); m != nil {
		t.Errorf("logo.svg references a remote resource: %q", m)
	}
	css, err := brandFS.ReadFile("branding/bazzite/theme.css")
	if err != nil {
		t.Fatal(err)
	}
	if m := regexp.MustCompile(`(?i)(@import|url\(\s*['"]?(https?:)?//)`).Find(css); m != nil {
		t.Errorf("theme.css fetches at run time: %q", m)
	}
	font, err := brandFS.ReadFile("branding/bazzite/font.woff2")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(font, []byte("wOF2")) {
		t.Errorf("font.woff2 is not a WOFF2 file (magic %q)", font[:4])
	}
}

// A branded build commits to its look in BOTH Windows themes: the theme's
// token block must be unconditional, not inside a prefers-color-scheme
// query that a light-mode Windows would skip.
func TestBazziteBuild_ThemeIsNotConditionalOnColorScheme(t *testing.T) {
	css, err := brandFS.ReadFile("branding/bazzite/theme.css")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(css, []byte("prefers-color-scheme")) {
		t.Error("bazzite theme.css is conditional on the Windows colour scheme")
	}
	for _, token := range []string{"--bg:", "--bg-card:", "--text:", "--accent:"} {
		if !bytes.Contains(css, []byte(token)) {
			t.Errorf("bazzite theme.css does not set %s; style.css's light block would win in light mode", token)
		}
	}
}
