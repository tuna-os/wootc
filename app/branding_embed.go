package main

import (
	"embed"
	"encoding/base64"
	"encoding/json"
)

// One binary per brand, chosen at build time (docs/branding-and-distribution.md).
// Every brand config ships inside every binary; brandID picks which one this
// build wears. The runtime overlay (C:\wootc\brand.json) still wins over the
// embedded brand — that path is the enterprise re-skin contract and predates
// brands.
//
//go:embed branding
var brandFS embed.FS

// brandID selects the embedded brand config. Overridden at build time:
//
//	go build -ldflags "-X main.brandID=bazzite"
//
// The default is the un-branded generic build. Branded builds never show the
// word "wootc" in user-facing surfaces — the brand.json carries their entire
// identity — while internal paths (C:\wootc, EFI\wootc) stay: they are the
// on-disk contract shared with the deployer and are invisible in normal use.
var brandID = "wootc"

// embeddedBranding returns the brand config compiled into this binary. A
// missing or malformed config falls back to zero (defaults then apply): a
// bad ldflag must degrade to the generic installer, not a crash at startup.
//
// Beyond brand.json, a brand directory may carry real assets — the deep
// branding the emoji placeholders were not (a branded installer wears the
// distribution's actual mark, type and look):
//
//	logo.svg   → LogoDataURI  (replaces the emoji everywhere it renders)
//	font.woff2 → FontDataURI  (the brand's typeface, embedded — the app must
//	                           never fetch a webfont at run time)
//	theme.css  → ThemeCSS     (token + component overrides injected after
//	                           style.css: buttons, radii, palette, type)
func embeddedBranding() (Branding, bool) {
	data, err := brandFS.ReadFile("branding/" + brandID + "/brand.json")
	if err != nil {
		return Branding{}, false
	}
	var b Branding
	if json.Unmarshal(data, &b) != nil {
		return Branding{}, false
	}
	if logo, err := brandFS.ReadFile("branding/" + brandID + "/logo.svg"); err == nil {
		b.LogoDataURI = "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString(logo)
	}
	if font, err := brandFS.ReadFile("branding/" + brandID + "/font.woff2"); err == nil {
		b.FontDataURI = "data:font/woff2;base64," + base64.StdEncoding.EncodeToString(font)
	}
	if css, err := brandFS.ReadFile("branding/" + brandID + "/theme.css"); err == nil {
		b.ThemeCSS = string(css)
	}
	return b, true
}

// releaseTag is the release this binary was cut from, set at build time with
// -ldflags "-X main.releaseTag=v0.2.0". It pins where the boot artifacts are
// fetched from (#335): the exe and the deployer kernel/initramfs/shim ship
// together and are gated together by one E2E run, so an installer must never
// pull a boot chain from a release it was not tested with. Empty in a local
// build, which falls back to `latest` — the only thing an unstamped build
// can do.
var releaseTag = ""
