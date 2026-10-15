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
	if !brandMayNameOwner(brandID) {
		// Until the mark's owner has said yes, the exe and its Add/Remove
		// entry name who actually built and distributes it, not them.
		b.Publisher = brandDistributor()
		b.Copyright = ""
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

// brandMayNameOwner reports whether a brand's own publisher and copyright
// (brand.json) may appear on the exe and its Add/Remove entry. A branded
// build names its mark's owner as publisher only once that owner has said
// yes — blessing.json status "blessed" — or when the mark is this project's
// own (selfOwned, and listed in ownership.json). Anything else, including a
// missing or unreadable record, fails closed: claiming another project's
// authorship before they agree is the presumption #227 exists to prevent.
// packaging/brand.py effective_identity applies the same rule to the
// exe's version resource and the winget manifests.
func brandMayNameOwner(id string) bool {
	record, err := brandFS.ReadFile("branding/" + id + "/blessing.json")
	if err != nil {
		return false
	}
	policy, ok := brandOwnership()
	return ok && ownerMayBeNamed(id, record, policy)
}

// ownerMayBeNamed is brandMayNameOwner without the I/O, so a test can drive
// a blessed record the checkout does not (yet) hold.
func ownerMayBeNamed(id string, blessing []byte, policy brandOwnershipPolicyFile) bool {
	var record struct {
		Brand     string `json:"brand"`
		SelfOwned bool   `json:"selfOwned"`
		Status    string `json:"status"`
	}
	if json.Unmarshal(blessing, &record) != nil || record.Brand != id {
		return false
	}
	if record.SelfOwned {
		for _, own := range policy.SelfOwnedBrands {
			if own == id {
				return true
			}
		}
		return false
	}
	return record.Status == "blessed"
}

type brandOwnershipPolicyFile struct {
	SelfOwnedBrands  []string `json:"selfOwnedBrands"`
	WingetNamespaces []string `json:"wingetNamespaces"`
	// Distributor is who builds and ships every exe in this checkout — the
	// publisher an unblessed brand's exe carries instead of the mark owner.
	Distributor string `json:"distributor"`
}

func brandOwnership() (brandOwnershipPolicyFile, bool) {
	var policy brandOwnershipPolicyFile
	data, err := brandFS.ReadFile("branding/ownership.json")
	if err != nil || json.Unmarshal(data, &policy) != nil {
		return policy, false
	}
	return policy, true
}

// brandDistributor is ownership.json's distributor. Never empty: an empty
// publisher would fall back to the brand's own name in effectiveBranding,
// which is the very claim this replaces.
func brandDistributor() string {
	if policy, ok := brandOwnership(); ok && policy.Distributor != "" {
		return policy.Distributor
	}
	return defaultBranding().Name
}

// releaseTag is the release this binary was cut from, set at build time with
// -ldflags "-X main.releaseTag=v0.2.0". It pins where the boot artifacts are
// fetched from (#335): the exe and the deployer kernel/initramfs/shim ship
// together and are gated together by one E2E run, so an installer must never
// pull a boot chain from a release it was not tested with. Empty in a local
// build, which falls back to `latest` — the only thing an unstamped build
// can do.
var releaseTag = ""
