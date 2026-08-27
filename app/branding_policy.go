package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

func defaultBranding() Branding {
	return Branding{
		Name: "TunaOS", Tagline: "Bring Windows to Linux — keep everything.",
		LogoEmoji: "🐠", Version: "0.1.0",
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
	return b
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
