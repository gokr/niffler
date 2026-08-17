// Package main is the Niffler UI shell — Wails v2 + Svelte 5.
//
// The UI is a bus citizen, not a driver: the conversation loop lives in
// core (svc.core.call "session" tool). The bridge exposes exactly three
// things to the SPA — send (request/reply), emit (fire-and-forget), and a
// forwarded event stream (ev.>, reg.>) — everything else is the SPA's
// business. nats.ts is the only transport-aware file in the frontend, so
// the same SPA can run against a WebSocket proxy later with zero changes.
package main

import (
	"context"
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewBridge()

	err := wails.Run(&options.App{
		Title:  "Niffler",
		Width:  1100,
		Height: 780,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 16, G: 16, B: 20, A: 255},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}

var _ = context.Background
