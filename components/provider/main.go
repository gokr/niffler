// provider component: a store-backed registry of configured LLM providers.
//
// Unlike config-file driven harnesses, Niffler keeps provider config in the
// store (kind "provider") and exposes add/remove/list/switch/export/import
// tools. The llm component resolves its active provider from here (falling
// back to NIF_OPENAI_* env and NIF_LLM_PROVIDERS when this component is
// absent). Switching provider live-updates the LLM backend.
//
// Data model
//
//	provider:<nickname>  {nickname, apiKey, baseUrl, model, catalog, context, plugin}
//	provider:active      {nickname, updatedAt}   -> the currently selected provider
//
// On switch the component emits ev.provider.switch {nickname, previous, ...} so
// provider plugin components (e.g. provider-deepseek exposing deepseek_balance)
// can enable or hide their provider-specific tools.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	sdk "niffler.dev/sdk"
)

const (
	kindProvider = "provider"
	activeID     = "active"
	defaultModel = "deepseek-chat"
)

// Provider is one configured LLM backend.
type Provider struct {
	Nickname string `json:"nickname"`
	APIKey   string `json:"apiKey"`
	BaseURL  string `json:"baseUrl"`
	Model    string `json:"model"`
	Catalog  string `json:"catalog"` // models.dev provider id for context lookup
	Context  int    `json:"context"` // explicit context window override (0 = auto)
	Plugin   string `json:"plugin"`  // component that hooks provider-specific tools (optional)
}

// providerSummary is the only provider shape intended for interactive clients.
// It deliberately contains no credential value.
type providerSummary struct {
	Nickname string `json:"nickname"`
	BaseURL  string `json:"baseUrl"`
	Model    string `json:"model"`
	Catalog  string `json:"catalog"`
	Context  int    `json:"context"`
	Plugin   string `json:"plugin"`
	Active   bool   `json:"active"`
	HasKey   bool   `json:"hasKey"`
}

func summarizeProvider(p Provider, active bool) providerSummary {
	return providerSummary{
		Nickname: p.Nickname,
		BaseURL:  p.BaseURL,
		Model:    p.Model,
		Catalog:  p.Catalog,
		Context:  p.Context,
		Plugin:   p.Plugin,
		Active:   active,
		HasKey:   p.APIKey != "",
	}
}

func environmentProvider() Provider {
	baseURL := os.Getenv("NIF_OPENAI_BASE_URL")
	if baseURL == "" {
		baseURL = "https://api.openai.com/v1"
	}
	model := os.Getenv("NIF_OPENAI_MODEL")
	if model == "" {
		model = defaultModel
	}
	return Provider{
		Nickname: "default",
		APIKey:   os.Getenv("NIF_OPENAI_API_KEY"),
		BaseURL:  baseURL,
		Model:    model,
		Catalog:  os.Getenv("NIF_OPENAI_PROVIDER"),
	}
}

func (p Provider) withDefaults() Provider {
	if p.BaseURL == "" {
		switch p.Nickname {
		case "deepseek":
			p.BaseURL = "https://api.deepseek.com"
		case "openai":
			p.BaseURL = "https://api.openai.com/v1"
		default:
			p.BaseURL = ""
		}
	}
	if p.Model == "" {
		p.Model = defaultModel
	}
	return p
}

type activeDoc struct {
	Nickname  string    `json:"nickname"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// storeClient is a tiny wrapper over the store component tools.
type storeClient struct {
	c *sdk.Component
}

func (s *storeClient) put(kind, id string, value any, expectRev int) (int, error) {
	raw, err := s.c.Request("store", "put", map[string]any{
		"kind": kind, "id": id, "value": value, "expectRev": expectRev,
	}, 10*time.Second)
	if err != nil {
		return 0, err
	}
	var resp struct {
		Ok    bool
		Rev   int
		Error string
		Code  string
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0, err
	}
	if !resp.Ok {
		return 0, errors.New(resp.Error + " (" + resp.Code + ")")
	}
	return resp.Rev, nil
}

func (s *storeClient) get(kind, id string) (json.RawMessage, *int, error) {
	// returns (value, revPointer, err); value is nil when not found
	raw, err := s.c.Request("store", "get", map[string]any{"kind": kind, "id": id}, 10*time.Second)
	if err != nil {
		return nil, nil, err
	}
	var resp struct {
		Ok    bool            `json:"ok"`
		Rev   int             `json:"rev"`
		Error string          `json:"error"`
		Code  string          `json:"code"`
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, nil, err
	}
	if !resp.Ok {
		if resp.Code == "not-found" {
			return nil, nil, nil // not found: nil value, nil rev
		}
		return nil, nil, errors.New(resp.Error)
	}
	return resp.Value, &resp.Rev, nil
}

func (s *storeClient) list(kind, idPrefix string) ([]struct {
	ID    string          `json:"id"`
	Rev   int             `json:"rev"`
	Value json.RawMessage `json:"value"`
}, error) {
	raw, err := s.c.Request("store", "list", map[string]any{
		"kind": kind, "idPrefix": idPrefix, "limit": 1000,
	}, 10*time.Second)
	if err != nil {
		return nil, err
	}
	var resp struct {
		Ok    bool `json:"ok"`
		Items []struct {
			ID    string          `json:"id"`
			Rev   int             `json:"rev"`
			Value json.RawMessage `json:"value"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if !resp.Ok {
		return nil, errors.New("store list failed")
	}
	return resp.Items, nil
}

func (s *storeClient) del(kind, id string) (bool, error) {
	raw, err := s.c.Request("store", "del", map[string]any{"kind": kind, "id": id}, 10*time.Second)
	if err != nil {
		return false, err
	}
	var resp struct {
		Ok    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false, err
	}
	if !resp.Ok {
		return false, errors.New(resp.Error)
	}
	return resp.Ok, nil
}

func decodeArgs(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return fmt.Errorf("bad arguments: %w", err)
	}
	return nil
}

func main() {
	comp := sdk.New("provider", "0.2.0")
	sc := &storeClient{c: comp}

	// ---------------------------------------------------------------- add
	comp.Tool("provider_add", map[string]any{
		"type":        "object",
		"description": "Add or update a configured LLM provider in the store. Requires an API key. Optionally set active.",
		"properties": map[string]any{
			"nickname": map[string]any{"type": "string", "description": "Provider nickname (e.g. deepseek, openrouter, local)"},
			"apiKey":   map[string]any{"type": "string", "description": "API key / secret"},
			"baseUrl":  map[string]any{"type": "string", "description": "Optional base URL (defaults by nickname for deepseek/openai)"},
			"model":    map[string]any{"type": "string", "description": "Default model id"},
			"catalog":  map[string]any{"type": "string", "description": "models.dev provider id for context lookup (optional)"},
			"context":  map[string]any{"type": "integer", "description": "Explicit context window in tokens (0 = auto)"},
			"plugin":   map[string]any{"type": "string", "description": "Component name of an optional provider plugin (e.g. provider-deepseek)"},
			"active":   map[string]any{"type": "boolean", "description": "Make this the active provider now (default true if none active)"},
		},
		"required":  []string{"nickname", "apiKey"},
		"x-harness": map[string]any{"approval": "always", "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Nickname string `json:"nickname"`
			APIKey   string `json:"apiKey"`
			BaseURL  string `json:"baseUrl"`
			Model    string `json:"model"`
			Catalog  string `json:"catalog"`
			Context  int    `json:"context"`
			Plugin   string `json:"plugin"`
			Active   *bool  `json:"active"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		args.Nickname = strings.TrimSpace(args.Nickname)
		if args.Nickname == "" {
			return nil, errors.New("nickname required")
		}
		if args.Nickname == activeID {
			return nil, errors.New("reserved nickname")
		}
		if strings.TrimSpace(args.APIKey) == "" {
			return nil, errors.New("apiKey required")
		}
		if args.Context < 0 {
			return nil, errors.New("context must be non-negative")
		}
		p := Provider{
			Nickname: args.Nickname,
			APIKey:   args.APIKey,
			BaseURL:  args.BaseURL,
			Model:    args.Model,
			Catalog:  args.Catalog,
			Context:  args.Context,
			Plugin:   args.Plugin,
		}.withDefaults()

		// existing rev for upsert
		_, revPtr, err := sc.get(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		expectRev := 0
		existed := revPtr != nil
		if existed {
			expectRev = *revPtr
		}
		newRev, err := sc.put(kindProvider, args.Nickname, p, expectRev)
		if err != nil {
			return nil, err
		}

		wasActive := false
		if activeVal, _, e := sc.get(kindProvider, activeID); e == nil && activeVal != nil {
			var a activeDoc
			if json.Unmarshal(activeVal, &a) == nil && a.Nickname == args.Nickname {
				wasActive = true
			}
		}

		activate := args.Active != nil && *args.Active
		if !activate && !wasActive && !providerActiveExists(sc) {
			activate = true // first provider becomes active by default
		}
		if activate {
			if err := activateProvider(comp, sc, args.Nickname); err != nil {
				return nil, err
			}
		}
		isActive := activate || wasActive
		op := "add"
		if existed {
			op = "update"
		}
		emitProviderChanged(comp, sc, op, args.Nickname)

		return map[string]any{
			"ok": true, "rev": newRev,
			"provider": summarizeProvider(p, isActive), "active": isActive,
		}, nil
	})

	// ------------------------------------------------------------ update
	comp.Tool("provider_update", map[string]any{
		"type":        "object",
		"description": "Update non-secret provider settings while preserving its stored API key. A non-empty apiKey rotates the credential.",
		"properties": map[string]any{
			"nickname": map[string]any{"type": "string"},
			"apiKey":   map[string]any{"type": "string", "description": "Optional replacement credential; omitted preserves the current key"},
			"baseUrl":  map[string]any{"type": "string"},
			"model":    map[string]any{"type": "string"},
			"catalog":  map[string]any{"type": "string"},
			"context":  map[string]any{"type": "integer", "minimum": 0},
			"plugin":   map[string]any{"type": "string"},
		},
		"required":  []string{"nickname"},
		"x-harness": map[string]any{"hidden": true, "approval": "always", "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Nickname string  `json:"nickname"`
			APIKey   *string `json:"apiKey"`
			BaseURL  *string `json:"baseUrl"`
			Model    *string `json:"model"`
			Catalog  *string `json:"catalog"`
			Context  *int    `json:"context"`
			Plugin   *string `json:"plugin"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		args.Nickname = strings.TrimSpace(args.Nickname)
		if args.Nickname == "" || args.Nickname == activeID {
			return nil, errors.New("valid nickname required")
		}
		rawProvider, rev, err := sc.get(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		if rawProvider == nil || rev == nil {
			return nil, fmt.Errorf("provider %q not found", args.Nickname)
		}
		var p Provider
		if err := json.Unmarshal(rawProvider, &p); err != nil {
			return nil, fmt.Errorf("corrupt provider %q: %w", args.Nickname, err)
		}
		if args.APIKey != nil {
			if strings.TrimSpace(*args.APIKey) == "" {
				return nil, errors.New("apiKey cannot be empty")
			}
			p.APIKey = *args.APIKey
		}
		if args.BaseURL != nil {
			p.BaseURL = strings.TrimSpace(*args.BaseURL)
		}
		if args.Model != nil {
			p.Model = strings.TrimSpace(*args.Model)
		}
		if args.Catalog != nil {
			p.Catalog = strings.TrimSpace(*args.Catalog)
		}
		if args.Context != nil {
			if *args.Context < 0 {
				return nil, errors.New("context must be non-negative")
			}
			p.Context = *args.Context
		}
		if args.Plugin != nil {
			p.Plugin = strings.TrimSpace(*args.Plugin)
		}
		p = p.withDefaults()
		newRev, err := sc.put(kindProvider, args.Nickname, p, *rev)
		if err != nil {
			return nil, err
		}
		active := providerActiveIs(sc, args.Nickname)
		emitProviderChanged(comp, sc, "update", args.Nickname)
		return map[string]any{
			"ok": true, "rev": newRev,
			"provider": summarizeProvider(p, active), "active": active,
		}, nil
	})

	// ------------------------------------------------------------- remove
	comp.Tool("provider_remove", map[string]any{
		"type":        "object",
		"description": "Remove a configured provider from the store.",
		"properties": map[string]any{
			"nickname": map[string]any{"type": "string"},
		},
		"required": []string{"nickname"},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Nickname string `json:"nickname"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		if args.Nickname == "" {
			return nil, errors.New("nickname required")
		}
		rev, _, err := sc.get(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		if rev == nil {
			return nil, fmt.Errorf("provider %q not found", args.Nickname)
		}
		ok, err := sc.del(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, errors.New("delete failed")
		}
		// If it was active, fall back to another provider (or none).
		if providerActiveIs(sc, args.Nickname) {
			if err := activateNext(comp, sc, args.Nickname); err != nil {
				return nil, err
			}
		}
		emitProviderChanged(comp, sc, "remove", args.Nickname)
		return map[string]any{"ok": true, "removed": args.Nickname}, nil
	})

	// --------------------------------------------------------------- list
	comp.Tool("provider_list", map[string]any{
		"type":        "object",
		"description": "List all configured providers and which one is active. API keys are redacted.",
		"properties":  map[string]any{},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		items, err := sc.list(kindProvider, "")
		if err != nil {
			return nil, err
		}
		activeName := activeProviderName(sc)
		providers := []providerSummary{}
		for _, it := range items {
			if it.ID == activeID {
				continue // the active marker doc is not a provider
			}
			var p Provider
			if err := json.Unmarshal(it.Value, &p); err != nil {
				continue
			}
			providers = append(providers, summarizeProvider(p, p.Nickname == activeName))
		}
		sort.Slice(providers, func(i, j int) bool { return providers[i].Nickname < providers[j].Nickname })
		return map[string]any{"providers": providers, "active": activeName, "count": len(providers)}, nil
	})

	// ------------------------------------------------------------- status
	comp.Tool("provider_status", map[string]any{
		"type":        "object",
		"description": "Return the effective active provider without exposing its API key.",
		"properties":  map[string]any{},
		"x-harness":   map[string]any{"hidden": true},
	}, func(_ *sdk.Component, _ json.RawMessage) (any, error) {
		p, source, ok, err := effectiveProvider(sc)
		if err != nil {
			return nil, err
		}
		result := map[string]any{
			"ok": ok, "source": source,
			"provider": summarizeProvider(p, source == "store"),
		}
		if !ok {
			result["error"] = "no active provider configured"
		}
		return result, nil
	})

	// ---------------------------------------------------- use environment
	comp.Tool("provider_use_environment", map[string]any{
		"type":        "object",
		"description": "Clear the stored active marker so the LLM uses NIF_OPENAI_* again.",
		"properties":  map[string]any{},
		"x-harness":   map[string]any{"hidden": true, "approval": "always", "timeoutMs": 30000},
	}, func(_ *sdk.Component, _ json.RawMessage) (any, error) {
		if err := activateEnvironment(comp, sc); err != nil {
			return nil, err
		}
		p, source, ok, err := effectiveProvider(sc)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"ok": ok, "source": source,
			"provider": summarizeProvider(p, false),
		}, nil
	})

	// ------------------------------------------------------------- switch
	comp.Tool("provider_switch", map[string]any{
		"type":        "object",
		"description": "Set the active provider. Live-updates the LLM backend and notifies provider plugins.",
		"properties": map[string]any{
			"nickname": map[string]any{"type": "string"},
		},
		"required": []string{"nickname"},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Nickname string `json:"nickname"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		if args.Nickname == "" {
			return nil, errors.New("nickname required")
		}
		rev, _, err := sc.get(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		if rev == nil {
			return nil, fmt.Errorf("provider %q not found", args.Nickname)
		}
		if err := activateProvider(comp, sc, args.Nickname); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "active": args.Nickname}, nil
	})

	// ------------------------------------------------------------- active
	comp.Tool("provider_active", map[string]any{
		"type":        "object",
		"description": "Return the currently active provider config (API key included for programmatic use).",
		"properties":  map[string]any{},
		"x-harness":   map[string]any{"hidden": true},
	}, func(_ *sdk.Component, _ json.RawMessage) (any, error) {
		p, source, ok, err := effectiveProvider(sc)
		if err != nil {
			return nil, err
		}
		if !ok {
			return map[string]any{
				"ok": false, "source": source,
				"error": "no active provider configured",
			}, nil
		}
		return map[string]any{"ok": true, "source": source, "provider": p}, nil
	})

	// --------------------------------------------------------------- get
	comp.Tool("provider_get", map[string]any{
		"type":        "object",
		"description": "Return one stored provider config by nickname, including its API key, for internal routing.",
		"properties": map[string]any{
			"nickname": map[string]any{"type": "string"},
		},
		"required":  []string{"nickname"},
		"x-harness": map[string]any{"hidden": true},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			Nickname string `json:"nickname"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		args.Nickname = strings.TrimSpace(args.Nickname)
		if args.Nickname == "" || args.Nickname == activeID {
			return nil, errors.New("valid nickname required")
		}
		rawProvider, _, err := sc.get(kindProvider, args.Nickname)
		if err != nil {
			return nil, err
		}
		if rawProvider == nil {
			return nil, fmt.Errorf("provider %q not found", args.Nickname)
		}
		var p Provider
		if err := json.Unmarshal(rawProvider, &p); err != nil {
			return nil, fmt.Errorf("corrupt provider %q: %w", args.Nickname, err)
		}
		return map[string]any{"ok": true, "source": "store", "provider": p.withDefaults()}, nil
	})

	// ------------------------------------------------------------- export
	comp.Tool("provider_export", map[string]any{
		"type":        "object",
		"description": "Export all configured providers as JSON (including API keys). Use to back up or migrate.",
		"properties":  map[string]any{},
		"x-harness":   map[string]any{"approval": "always", "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		items, err := sc.list(kindProvider, "")
		if err != nil {
			return nil, err
		}
		var activeName string
		if a, _, e := sc.get(kindProvider, activeID); e == nil && a != nil {
			var ad activeDoc
			if json.Unmarshal(a, &ad) == nil {
				activeName = ad.Nickname
			}
		}
		providers := []Provider{}
		for _, it := range items {
			if it.ID == activeID {
				continue // the active marker doc is not a provider
			}
			var p Provider
			if json.Unmarshal(it.Value, &p) == nil {
				providers = append(providers, p)
			}
		}
		sort.Slice(providers, func(i, j int) bool { return providers[i].Nickname < providers[j].Nickname })
		return map[string]any{"active": activeName, "providers": providers, "count": len(providers)}, nil
	})

	// ------------------------------------------------------------- import
	comp.Tool("provider_import", map[string]any{
		"type":        "object",
		"description": "Import providers from JSON (the form produced by provider_export). Merges; existing providers are updated.",
		"properties": map[string]any{
			"json": map[string]any{"type": "string", "description": "The exported JSON document"},
		},
		"required":  []string{"json"},
		"x-harness": map[string]any{"approval": "always", "timeoutMs": 30000},
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			JSON string `json:"json"`
		}
		if err := decodeArgs(raw, &args); err != nil {
			return nil, err
		}
		if strings.TrimSpace(args.JSON) == "" {
			return nil, errors.New("json required")
		}
		var p struct {
			Active    string     `json:"active"`
			Providers []Provider `json:"providers"`
		}
		if err := json.Unmarshal([]byte(args.JSON), &p); err != nil {
			return nil, fmt.Errorf("provider_import: bad json: %w", err)
		}
		var imported []string
		for _, pr := range p.Providers {
			pr.Nickname = strings.TrimSpace(pr.Nickname)
			if pr.Nickname == "" || pr.Nickname == activeID {
				continue
			}
			if strings.TrimSpace(pr.APIKey) == "" {
				continue
			}
			final := pr.withDefaults()
			_, rev, err := sc.get(kindProvider, pr.Nickname)
			if err != nil {
				return nil, err
			}
			expect := 0
			if rev != nil {
				expect = *rev
			}
			if _, err := sc.put(kindProvider, pr.Nickname, final, expect); err != nil {
				return nil, fmt.Errorf("import %s: %w", pr.Nickname, err)
			}
			imported = append(imported, pr.Nickname)
		}
		// Restore active if it still exists after import.
		if p.Active != "" {
			if _, rev, err := sc.get(kindProvider, p.Active); err == nil && rev != nil {
				if err := activateProvider(comp, sc, p.Active); err != nil {
					return nil, err
				}
			}
		}
		emitProviderChanged(comp, sc, "import", p.Active)
		return map[string]any{"ok": true, "imported": imported, "count": len(imported)}, nil
	})

	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "provider:", err)
		os.Exit(1)
	}
}

// ---- helpers ----

func activeProviderName(sc *storeClient) string {
	raw, _, err := sc.get(kindProvider, activeID)
	if err != nil || raw == nil {
		return ""
	}
	var active activeDoc
	if json.Unmarshal(raw, &active) != nil {
		return ""
	}
	return strings.TrimSpace(active.Nickname)
}

func providerActiveExists(sc *storeClient) bool {
	name := activeProviderName(sc)
	if name == "" {
		return false
	}
	raw, _, err := sc.get(kindProvider, name)
	return err == nil && raw != nil
}

func providerActiveIs(sc *storeClient, nickname string) bool {
	return activeProviderName(sc) == nickname
}

// effectiveProvider resolves the stored active provider, then the environment
// fallback. It is shared by provider_active (internal/full secret) and
// provider_status (interactive/redacted) so both report identical routing.
func effectiveProvider(sc *storeClient) (Provider, string, bool, error) {
	activeRaw, _, err := sc.get(kindProvider, activeID)
	if err != nil {
		return Provider{}, "", false, err
	}
	if activeRaw != nil {
		var active activeDoc
		if err := json.Unmarshal(activeRaw, &active); err != nil {
			return Provider{}, "", false, fmt.Errorf("corrupt active doc: %w", err)
		}
		if active.Nickname != "" {
			providerRaw, _, err := sc.get(kindProvider, active.Nickname)
			if err != nil {
				return Provider{}, "", false, err
			}
			if providerRaw != nil {
				var p Provider
				if err := json.Unmarshal(providerRaw, &p); err != nil {
					return Provider{}, "", false, fmt.Errorf("corrupt provider doc: %w", err)
				}
				return p.withDefaults(), "store", p.APIKey != "", nil
			}
		}
		// Empty/stale markers must not prevent the next added provider from
		// becoming active.
		_, _ = sc.del(kindProvider, activeID)
	}
	p := environmentProvider()
	return p, "environment", p.APIKey != "", nil
}

func emitProviderChanged(comp *sdk.Component, sc *storeClient, op, nickname string) {
	active := ""
	source := "environment"
	if p, resolvedSource, ok, err := effectiveProvider(sc); err == nil {
		source = resolvedSource
		if ok {
			active = p.Nickname
		}
	}
	_ = comp.Emit("ev.provider.changed", map[string]any{
		"op": op, "nickname": nickname, "active": active,
		"source": source, "at": time.Now(),
	})
}

func activateProvider(comp *sdk.Component, sc *storeClient, nickname string) error {
	previous := activeProviderName(sc)
	doc := activeDoc{Nickname: nickname, UpdatedAt: time.Now()}
	if _, err := sc.put(kindProvider, activeID, doc, 0); err != nil {
		return err
	}
	// Notify plugins so they can enable their provider-specific tools.
	_ = comp.Emit("ev.provider.switch", map[string]any{
		"nickname": nickname, "previous": previous, "source": "store", "at": time.Now(),
	})
	emitProviderChanged(comp, sc, "switch", nickname)
	return nil
}

func activateEnvironment(comp *sdk.Component, sc *storeClient) error {
	previous := activeProviderName(sc)
	if previous != "" {
		if ok, err := sc.del(kindProvider, activeID); err != nil || !ok {
			if err != nil {
				return err
			}
			return errors.New("clear active provider failed")
		}
	}
	_ = comp.Emit("ev.provider.switch", map[string]any{
		"nickname": "default", "previous": previous,
		"source": "environment", "at": time.Now(),
	})
	emitProviderChanged(comp, sc, "switch", "default")
	return nil
}

func activateNext(comp *sdk.Component, sc *storeClient, removed string) error {
	items, err := sc.list(kindProvider, "")
	if err != nil {
		return err
	}
	names := []string{}
	for _, it := range items {
		if it.ID != removed && it.ID != activeID {
			names = append(names, it.ID)
		}
	}
	if len(names) == 0 {
		return activateEnvironment(comp, sc)
	}
	sort.Strings(names)
	return activateProvider(comp, sc, names[0])
}
