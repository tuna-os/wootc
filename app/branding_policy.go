package main

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

func defaultBranding() Branding {
	return Branding{
		Name: "TunaOS", Tagline: "Bring Windows to Linux — keep everything.",
		LogoEmoji: "🐠", Version: buildVersion(),
		Accent: "#5b6ee1", AccentText: "#ffffff",
		Background: "#0a0a0f", Card: "#13131e", Text: "#e8e8f0",
		InstallVerb: "Install", ProductName: "wootc", ExeName: "wootc",
	}
}

// effectiveBranding applies defaults, compiled branding, and runtime overlays.
func effectiveBranding() Branding {
	b := defaultBranding()
	if emb, ok := embeddedBranding(); ok {
		mergeBranding(&b, emb)
	}
	if data, err := os.ReadFile(filepath.Join(wootcDir(), "brand.json")); err == nil {
		var over Branding
		if json.Unmarshal(data, &over) == nil {
			mergeBranding(&b, over)
		}
	}
	if css, err := os.ReadFile(filepath.Join(wootcDir(), "brand.css")); err == nil && len(css) > 0 {
		b.ThemeCSS += "\n" + string(css)
	}
	if b.Publisher == "" {
		b.Publisher = b.Name
	}
	if b.FileDescription == "" {
		b.FileDescription = b.ProductName
	}
	// The title bar shows the build, not a number from a config file: an
	// embedded brand or a runtime overlay cannot report a version this
	// binary is not.
	b.Version = buildVersion()
	b.WebsiteURL = safeBrandURL(b.WebsiteURL)
	b.SupportURL = safeBrandURL(b.SupportURL)
	return b
}

// buildVersion is the version this binary was cut as: the release tag
// stamped with -ldflags "-X main.releaseTag=…" (packaging/build-windows.py
// --version, RELEASE_TAG in release.yml), or "dev" for an unstamped local
// build. It used to be a hard-coded "0.1.0" in every build, which the title
// bar showed whatever the release.
func buildVersion() string {
	if tag := strings.TrimSpace(releaseTag); tag != "" {
		return tag
	}
	return "dev"
}

func safeBrandURL(value string) string {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return ""
	}
	return value
}

// mergeBranding overlays non-empty fields and only tightens boolean policy.
func mergeBranding(base *Branding, over Branding) {
	set := func(dst *string, v string) {
		if v != "" {
			*dst = v
		}
	}
	set(&base.Name, over.Name)
	set(&base.Tagline, over.Tagline)
	set(&base.LogoEmoji, over.LogoEmoji)
	set(&base.Version, over.Version)
	set(&base.Accent, over.Accent)
	set(&base.AccentText, over.AccentText)
	set(&base.Background, over.Background)
	set(&base.Card, over.Card)
	set(&base.Text, over.Text)
	set(&base.InstallVerb, over.InstallVerb)
	set(&base.ProductName, over.ProductName)
	set(&base.ExeName, over.ExeName)
	set(&base.Publisher, over.Publisher)
	set(&base.Copyright, over.Copyright)
	set(&base.FileDescription, over.FileDescription)
	set(&base.WebsiteURL, over.WebsiteURL)
	set(&base.SupportURL, over.SupportURL)
	set(&base.DefaultImage, over.DefaultImage)
	if len(over.Catalog) > 0 {
		base.Catalog = over.Catalog
	}
	set(&base.FontFamily, over.FontFamily)
	set(&base.LogoDataURI, over.LogoDataURI)
	set(&base.FontDataURI, over.FontDataURI)
	set(&base.ThemeCSS, over.ThemeCSS)
	base.HideCustomImage = base.HideCustomImage || over.HideCustomImage
	base.PreloadImage = base.PreloadImage || over.PreloadImage
}

// productName is the installer's own name as the user knows it: "wootc" for
// the generic build, "Bazzite Installer" for -X main.brandID=bazzite. Every
// sentence the app shows a person goes through it, because a branded build
// must never say a word its user was never told (docs/branding-and-
// distribution.md §2). Internal paths (C:\wootc, EFI\wootc) are not names
// and stay as they are.
func productName() string {
	if n := effectiveBranding().ProductName; n != "" {
		return n
	}
	return "wootc"
}

// uninstallDisplayName is the Apps & features / Add/Remove Programs entry.
// The generic build keeps its documented "TunaOS (wootc)" listing; a branded
// build lists under the distribution's own name — a Bazzite user searching
// Apps for "wootc" would find nothing, because nothing ever told them that
// word.
func uninstallDisplayName(b Branding) string {
	if strings.EqualFold(b.ProductName, "wootc") {
		return b.Name + " (wootc)"
	}
	return b.Name
}

// rebootMessage is the text Windows shows in its own restart notice.
func rebootMessage(b Branding) string {
	return b.ProductName + " is rebooting to start the installer"
}

// shouldPreloadImage decides whether the image is fetched on Windows before
// the reboot (offline-first, §3): every branded build sets preloadImage,
// because the deployer initramfs has no Wi-Fi. WOOTC_PRELOAD=1 opts the
// generic build in; WOOTC_PRELOAD=0 force-disables it even for a branded
// build — the E2E harness's switch while the offline axis (#217) is unproven.
func shouldPreloadImage(b Branding) bool {
	switch os.Getenv("WOOTC_PRELOAD") {
	case "0":
		return false
	case "":
		return b.PreloadImage
	default:
		return true
	}
}
