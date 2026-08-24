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
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed appicon.png
var appIcon []byte

func main() {
	app := NewBridge()

	err := wails.Run(&options.App{
		Title:  "Niffler",
		Menu:   buildMenu(app),
		Width:  1100,
		Height: 780,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 16, G: 16, B: 20, A: 255},
		Linux: &linux.Options{
			// Window icon (minimized/iconified state). The launcher/taskbar
			// icon comes from the desktop entry — `make ui-install` wires
			// that up (see ui/niffler.desktop).
			Icon: appIcon,
			// Matches StartupWMClass in ui/niffler.desktop so the window
			// manager groups the window with its launcher entry.
			ProgramName: "niffler-ui",
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}

var _ = context.Background

// buildCommit is injected at build time (make ui passes
// -ldflags "-X main.buildCommit=$(git rev-parse --short HEAD)") and shown
// in the About dialog. "unknown" when built without the Makefile.
var buildCommit = "unknown"

// nifRoot is the harness root, baked at build time (make ui passes
// -X main.nifRoot=$(ROOT)). It lets an icon-launched binary — where the
// exe-path heuristic cannot find the repo — load .env, resolve
// var/nats-url and autostart the harness (EnsureHarness). Empty when built
// without the Makefile; the exe-path fallback in uiRoot() covers in-tree runs.
var nifRoot = ""

// buildMenu assembles the application menu: About and Quit. Both callbacks
// read app.ctx (set in startup) so they work once the window is live.
func buildMenu(app *Bridge) *menu.Menu {
	about := "Niffler — self-extending agent harness.\n\nA bus citizen shell: all tool calls, approvals and events\nride a NATS bus; the Wails window just hosts the SPA."
	if buildCommit != "" && buildCommit != "unknown" {
		about += "\n\nUI built from commit " + buildCommit
	}
	appMenu := menu.NewMenu()
	appMenu.AddText("About Niffler", nil, func(*menu.CallbackData) {
		if app.ctx == nil {
			return
		}
		runtime.MessageDialog(app.ctx, runtime.MessageDialogOptions{
			Type:    runtime.InfoDialog,
			Title:   "About Niffler",
			Message: about,
			Buttons: []string{"OK"},
		})
	})
	appMenu.AddSeparator()
	appMenu.AddText("Quit Niffler", nil, func(*menu.CallbackData) {
		if app.ctx != nil {
			runtime.Quit(app.ctx)
		}
	})
	return menu.NewMenuFromItems(
		menu.SubMenu("Niffler", appMenu),
	)
}
