package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()

	err := wails.Run(&options.App{
		Title:            "wootc — Windows bootc Installer",
		Width:            820,
		Height:           620,
		MinWidth:         820,
		MinHeight:        620,
		MaxWidth:         820,
		MaxHeight:        620,
		DisableResize:    true,
		Frameless:        false,
		BackgroundColour: &options.RGBA{R: 10, G: 10, B: 15, A: 255},
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
			WebviewIsTransparent:              false,
			WindowIsTranslucent:               false,
			DisablePinchZoom:                  true,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
