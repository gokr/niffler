// models component: provider and model catalog with pluggable correction sources.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	sdk "niffler.dev/sdk"
)

func decodeArgs(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("bad arguments: %w", err)
	}
	return nil
}

// maxResultBytes keeps results under the default NATS maximum payload so
// callers get a bounded error instead of a wire-level timeout.
const maxResultBytes = 900 * 1024

// fitListResult trims the trailing entries of a list-style result until the
// envelope fits the bus payload limit.
func fitListResult(key string, items []map[string]any, total int) map[string]any {
	result := map[string]any{key: items, "count": len(items), "total": total}
	for len(items) > 0 {
		raw, err := json.Marshal(result)
		if err == nil && len(raw) <= maxResultBytes {
			return result
		}
		items = items[:len(items)/2]
		result[key] = items
		result["count"] = len(items)
		result["truncated"] = true
	}
	return result
}

func main() {
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	catalog := newCatalogState(root)
	refreshRequests := make(chan struct{}, 1)
	var forceRefresh atomic.Bool
	requestRefresh := func(force bool) {
		if force {
			forceRefresh.Store(true)
		}
		select {
		case refreshRequests <- struct{}{}:
		default:
		}
	}

	// Cancellation context: OS signals plus the bus-wide ev.sys.drain event.
	signalCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	ctx, shutdownCancel := context.WithCancel(signalCtx)

	comp := sdk.New("models", "0.1.0")
	comp.Tap("reg.publish", func(_ *sdk.Component, _ string, data []byte) {
		if catalog.register(data) {
			requestRefresh(false)
		}
	})
	comp.Tap("reg.depart", func(_ *sdk.Component, _ string, data []byte) {
		if catalog.depart(data) {
			requestRefresh(false)
		}
	})
	comp.On("ev.catalog.updated", func(_ *sdk.Component, _ string, _ json.RawMessage) {
		// A snapshot also catches components that died before publishing reg.depart.
		requestRefresh(false)
	})
	comp.On("ev.sys.drain", func(_ *sdk.Component, _ string, _ json.RawMessage) {
		// Bus-wide shutdown: cancel refresh work and exit (mirrors the SDK's
		// own drain handling, which our bespoke main loop does not use).
		shutdownCancel()
	})

	comp.Tool("models_providers", map[string]any{
		"type":        "object",
		"description": "List known LLM providers and their connection metadata without exposing credentials. Use this before choosing a provider or checking which providers are configured.",
		"properties": map[string]any{
			"query":      map[string]any{"type": "string", "description": "Case-insensitive provider id/name filter"},
			"configured": map[string]any{"type": "boolean", "description": "Only configured (true) or unconfigured (false) providers"},
		},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Query      string `json:"query"`
			Configured *bool  `json:"configured"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		providers := catalog.providers(args.Query, args.Configured)
		return fitListResult("providers", providers, len(providers)), nil
	})

	comp.Tool("models_list", map[string]any{
		"type":        "object",
		"description": "Search the effective model catalog after models.dev, plugin corrections, and local overrides are merged. Use this to compare model capabilities, limits, modalities, and prices before selection.",
		"properties": map[string]any{
			"provider":   map[string]any{"type": "string", "description": "Exact provider id"},
			"query":      map[string]any{"type": "string", "description": "Case-insensitive id, name, family, or description substring"},
			"status":     map[string]any{"type": "string", "description": "Exact model status such as active, beta, alpha, or deprecated"},
			"input":      map[string]any{"type": "string", "enum": []string{"text", "image", "audio", "video", "pdf"}},
			"reasoning":  map[string]any{"type": "boolean"},
			"toolCall":   map[string]any{"type": "boolean"},
			"configured": map[string]any{"type": "boolean", "description": "Filter by whether a provider credential environment variable is set"},
			"limit":      map[string]any{"type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum returned models (default 50)"},
		},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args listModelsArgs
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		models, total := catalog.models(args)
		return fitListResult("models", models, total), nil
	})

	comp.Tool("models_get", map[string]any{
		"type":        "object",
		"description": "Get one exact provider/model descriptor, including connection metadata, capabilities, limits, and pricing. Use this for runtime model configuration; use models_resolve first when the provider is unknown.",
		"properties": map[string]any{
			"provider": map[string]any{"type": "string", "description": "Exact provider id"},
			"model":    map[string]any{"type": "string", "description": "Exact provider-specific model id"},
		},
		"required": []string{"provider", "model"},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Provider string `json:"provider"`
			Model    string `json:"model"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		result, found := catalog.get(args.Provider, args.Model)
		if !found {
			return nil, fmt.Errorf("model not found: %s/%s", args.Provider, args.Model)
		}
		if raw, err := json.Marshal(result); err == nil && len(raw) > maxResultBytes {
			return nil, fmt.Errorf("model descriptor exceeds the result size limit; narrow with models_list")
		}
		return result, nil
	})

	comp.Tool("models_resolve", map[string]any{
		"type":        "object",
		"description": "Resolve an exact provider/model reference without silently choosing among ambiguous providers. Use this for user-supplied model names; a bare id is accepted only when it is globally unique.",
		"properties": map[string]any{
			"reference": map[string]any{"type": "string", "description": "provider/model or a globally unique bare model id"},
			"provider":  map[string]any{"type": "string", "description": "Optional provider when reference is a model id"},
		},
		"required": []string{"reference"},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Reference string `json:"reference"`
			Provider  string `json:"provider"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		return catalog.resolve(args.Reference, args.Provider), nil
	})

	comp.Tool("models_refresh", map[string]any{
		"type":        "object",
		"description": "Queue a refresh of models.dev and every registered model-source plugin, retaining each last-known-good result on failure. Use when the user asks for newly released models or after installing a catalog extension.",
		"properties": map[string]any{
			"force": map[string]any{"type": "boolean", "description": "Bypass the models.dev cache freshness check"},
		},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Force bool `json:"force"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		requestRefresh(args.Force)
		report := catalog.report()
		report["queued"] = true
		report["force"] = args.Force
		return report, nil
	})

	comp.Tool("models_sources", map[string]any{
		"type":        "object",
		"description": "Show catalog provenance and health: models.dev baseline, registered plugin patches, stale fallbacks, and the optional local override. Use this to diagnose questionable model metadata.",
		"properties":  map[string]any{},
	}, func(_ *sdk.Component, _ json.RawMessage) (any, error) {
		return catalog.report(), nil
	})

	if err := comp.Connect(); err != nil {
		fmt.Fprintln(os.Stderr, "models:", err)
		os.Exit(1)
	}
	interval := envDuration("NIF_MODELS_REFRESH_INTERVAL", time.Hour)
	var worker sync.WaitGroup
	worker.Add(1)
	go func() {
		defer worker.Done()
		var ticker *time.Ticker
		var ticks <-chan time.Time
		if interval > 0 {
			ticker = time.NewTicker(interval)
			ticks = ticker.C
			defer ticker.Stop()
		}
		var retryTimer *time.Timer
		var retry <-chan time.Time
		runRefresh := func() map[string]any {
			report := catalog.refresh(ctx, comp, forceRefresh.Swap(false))
			if ok, _ := report["ok"].(bool); !ok {
				_ = comp.Log("warn", "catalog refresh retained stale data", report["errors"])
			}
			return report
		}
		scheduleRetry := func() {
			if retryTimer != nil {
				retryTimer.Stop()
			}
			delay := 30 * time.Second
			if interval > 0 && interval < delay {
				delay = interval
			}
			retryTimer = time.NewTimer(delay)
			retry = retryTimer.C
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-refreshRequests:
				// Coalesce the registration burst at startup and plugin install.
				timer := time.NewTimer(150 * time.Millisecond)
				select {
				case <-ctx.Done():
					timer.Stop()
					return
				case <-timer.C:
				}
				for len(refreshRequests) > 0 {
					<-refreshRequests
				}
				if report := runRefresh(); report["ok"] != true {
					scheduleRetry()
				}
			case <-ticks:
				if report := runRefresh(); report["ok"] != true {
					scheduleRetry()
				}
			case <-retry:
				// A failed crash-reconciliation must not wait for the next
				// hourly tick — retry soon until discovery succeeds.
				retry = nil
				requestRefresh(false)
			}
		}
	}()

	requestRefresh(false)
	<-ctx.Done()
	worker.Wait()
	comp.Close()
}
