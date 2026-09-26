package main

import (
	"embed"
	"fmt"
	"os"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	if err := initializeStateTrust(); err != nil {
		reportStateTrustFailure(err)
		os.Exit(1)
	}

	// Headless subcommands (install/status/uninstall) run the production
	// pipeline without a webview — used by E2E and unattended installs.
	if isHeadlessInvocation(os.Args) {
		os.Exit(runHeadless(os.Args))
	}

	app := NewApp()

	// Wails paints this before WebView2 renders, so it must agree with the
	// theme the page is about to choose or the window flashes the wrong colour
	// on launch (#173). Values mirror the --bg tokens in style.css. A branded
	// build commits to its brand's ground colour in both Windows themes (the
	// injected theme.css overrides the light block), so it pre-paints that.
	background := &options.RGBA{R: 0x0a, G: 0x0a, B: 0x0f, A: 255} // dark  #0a0a0f
	if !systemPrefersDark() {
		background = &options.RGBA{R: 0xf6, G: 0xf6, B: 0xfa, A: 255} // light #f6f6fa
	}
	if bg, ok := parseHexRGB(app.GetBranding().Background); ok && brandID != "wootc" {
		background = bg
	}

	// The generic build keeps its historical title; a branded build's window
	// is named for the product alone — "wootc" never appears there.
	brand := app.GetBranding()
	title := brand.ProductName
	if brand.ProductName == "wootc" {
		title = "wootc — Windows bootc Installer"
	}

	err := wails.Run(&options.App{
		Title:            title,
		Width:            820,
		Height:           620,
		MinWidth:         820,
		MinHeight:        620,
		MaxWidth:         820,
		MaxHeight:        620,
		DisableResize: true,
		// Frameless: the app draws its own title bar (.titlebar, which already
		// carries --wails-draggable). With the native chrome ALSO on, the
		// window showed two stacked bars — a generic Windows one above wootc's
		// own — which is the "unstyled window decoration" of #175.
		//
		// Frameless removes the system minimise/close buttons, so the title bar
		// MUST supply its own or the window cannot be closed. See the controls
		// in renderTitleBar().
		Frameless: true,
		BackgroundColour: background,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
		Windows: &windows.Options{
			// Single-instance enforcement
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			DisablePinchZoom:     true,
			// Follow the Windows app-theme setting for the window chrome, and
			// let WebView2 report it to the page as prefers-color-scheme so the
			// content can match (#173 — the UI used to be dark on a light-mode
			// machine). This is windows.Theme's zero value, but state it: the
			// whole point is that it tracks the OS, which is not obvious from
			// an absent field.
			Theme: windows.SystemDefault,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}

// parseHexRGB turns "#rrggbb" into the Wails background colour.
func parseHexRGB(s string) (*options.RGBA, bool) {
	if len(s) != 7 || s[0] != '#' {
		return nil, false
	}
	var r, g, b uint8
	if _, err := fmt.Sscanf(s[1:], "%02x%02x%02x", &r, &g, &b); err != nil {
		return nil, false
	}
	return &options.RGBA{R: r, G: g, B: b, A: 255}, true
}
