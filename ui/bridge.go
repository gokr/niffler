package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
	sdk "niffler.dev/sdk"
)

// Bridge is the Go side of the UI shell: a niffler component (bus citizen)
// exposing three bindings to the SPA. All messages are JSON strings.
type Bridge struct {
	ctx    context.Context
	comp   *sdk.Component
	stopCh chan struct{}
}

// NewBridge creates the bridge; Connect happens on startup (with retry).
func NewBridge() *Bridge {
	comp := sdk.New("ui", "0.1.0")
	comp.Client = true // interactive frontend: keeps an autostarted core alive
	b := &Bridge{
		comp:   comp,
		stopCh: make(chan struct{}),
	}

	// Forward everything interesting to the SPA as {"subject": ..., "payload": ...}
	b.comp.On(">", func(c *sdk.Component, subject string, payload json.RawMessage) {
		runtime.EventsEmit(b.ctx, "nats", map[string]any{
			"subject": subject,
			"payload": payload,
		})
	})
	return b
}

// harnessRoot is where .env, var/nats-url and var/bin/niffler live: the
// build-time baked root (icon launch) or the exe-path heuristic (in-tree).
func harnessRoot() string {
	if nifRoot != "" {
		return nifRoot
	}
	return uiRoot()
}

// uiRoot returns the Niffler root from the exe path:
// <root>/ui/build/bin/niffler-ui → 4 levels up. Only valid when running the
// in-tree binary.
func uiRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(exe))))
}

// resolveNatsUrl: NIF_NATS_URL env → <root>/var/nats-url discovery file
// (written by core) → well-known default.
func resolveNatsUrl() string {
	return sdk.ResolveNatsUrl(harnessRoot())
}

func (b *Bridge) startup(ctx context.Context) {
	b.ctx = ctx
	// .env from the harness root and cwd (existing env always wins)
	sdk.LoadDotEnv(filepath.Join(harnessRoot(), ".env"), ".env")
	// One command, everything up: attach to the running harness, or start
	// core ourselves (UI-owned: it exits when the last UI departs).
	url, err := sdk.EnsureHarness(harnessRoot())
	if err != nil {
		slog.Warn("ensure harness failed (retrying via banner)", "err", err)
	} else {
		slog.Info("harness", "url", url)
	}
	go b.connectLoop()
}

func (b *Bridge) shutdown(ctx context.Context) {
	close(b.stopCh)
	b.comp.Close()
}

// connectLoop connects (retrying until it works) and emits nats-status
// events so the SPA's banner follows the real bus state.
func (b *Bridge) connectLoop() {
	status := func(online bool) {
		runtime.EventsEmit(b.ctx, "nats-status",
			map[string]any{"online": online, "url": resolveNatsUrl()})
	}
	for {
		select {
		case <-b.stopCh:
			return
		default:
		}
		// Component.Connect() only reads NIF_NATS_URL (defaulting to the
		// well-known port); resolveNatsUrl() also discovers var/nats-url
		// (core's actual bus, which can land on a random port if the
		// well-known one wasn't free). Feed that discovery back in so the
		// real connection attempt matches what the status banner reports.
		if u := resolveNatsUrl(); u != "" {
			os.Setenv("NIF_NATS_URL", u)
		}
		if err := b.comp.Connect(); err != nil {
			slog.Warn("bus connect failed", "url", resolveNatsUrl(), "err", err)
			status(false)
			select {
			case <-b.stopCh:
				return
			case <-time.After(2 * time.Second):
			}
			continue
		}
		status(true)
		for b.comp.Connected() {
			select {
			case <-b.stopCh:
				b.comp.Close()
				return
			case <-time.After(time.Second):
			}
		}
		status(false)
	}
}

// BusUrl reports the bus address the bridge is trying (shown in the banner).
func (b *Bridge) BusUrl() string {
	return resolveNatsUrl()
}

// Send calls a tool on a component over the bus. Returns the JSON result or
// a JSON error object.
func (b *Bridge) Send(component, tool, args string, timeoutMs int) string {
	if b.comp == nil || !b.comp.Connected() {
		return errJson("bus not connected")
	}
	var raw any
	if err := json.Unmarshal([]byte(args), &raw); err != nil {
		return errJson("bad args JSON: " + err.Error())
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 120 * time.Second
	}
	res, err := b.comp.Request(component, tool, raw, timeout)
	if err != nil {
		return errJson(err.Error())
	}
	return string(res)
}

// Emit publishes a fire-and-forget event.
func (b *Bridge) Emit(subject, payload string) {
	if b.comp == nil {
		return
	}
	var raw any
	if err := json.Unmarshal([]byte(payload), &raw); err != nil {
		raw = payload
	}
	_ = b.comp.Emit(subject, raw)
}

// Online reports the bridge's bus connection state.
func (b *Bridge) Online() bool {
	return b.comp != nil && b.comp.Connected()
}

func errJson(msg string) string {
	data, _ := json.Marshal(map[string]any{"error": msg})
	return string(data)
}
