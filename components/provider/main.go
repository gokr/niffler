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
	comp := sdk.New("provider", "0.1.0")
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
		if revPtr != nil {
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

		return map[string]any{"ok": true, "rev": newRev, "provider": p, "active": activate}, nil
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
		active, _, _ := sc.get(kindProvider, activeID)
		var activeName string
		if active != nil {
			if raw, _, err2 := sc.get(kindProvider, activeID); err2 == nil && raw != nil {
				var a activeDoc
				if json.Unmarshal(raw, &a) == nil {
					activeName = a.Nickname
				}
			}
		}
		type out struct {
			Nickname string `json:"nickname"`
			BaseURL  string `json:"baseUrl"`
			Model    string `json:"model"`
			Catalog  string `json:"catalog"`
			Context  int    `json:"context"`
			Plugin   string `json:"plugin"`
			Active   bool   `json:"active"`
			HasKey   bool   `json:"hasKey"`
		}
		providers := []out{}
		for _, it := range items {
			if it.ID == activeID {
				continue // the active marker doc is not a provider
			}
			var p Provider
			if err := json.Unmarshal(it.Value, &p); err != nil {
				continue
			}
			providers = append(providers, out{
				Nickname: p.Nickname,
				BaseURL:  p.BaseURL,
				Model:    p.Model,
				Catalog:  p.Catalog,
				Context:  p.Context,
				Plugin:   p.Plugin,
				Active:   p.Nickname == activeName,
				HasKey:   p.APIKey != "",
			})
		}
		sort.Slice(providers, func(i, j int) bool { return providers[i].Nickname < providers[j].Nickname })
		return map[string]any{"providers": providers, "active": activeName, "count": len(providers)}, nil
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
	}, func(_ *sdk.Component, raw json.RawMessage) (any, error) {
		active, _, err := sc.get(kindProvider, activeID)
		if err != nil {
			return nil, err
		}
		if active == nil {
			// Fall back to env (standalone without stored providers).
			p := Provider{
				Nickname: "default",
				APIKey:   os.Getenv("NIF_OPENAI_API_KEY"),
				BaseURL:  os.Getenv("NIF_OPENAI_BASE_URL"),
				Model:    os.Getenv("NIF_OPENAI_MODEL"),
				Catalog:  os.Getenv("NIF_OPENAI_PROVIDER"),
			}.withDefaults()
			if p.APIKey == "" {
				return map[string]any{"ok": false, "error": "no active provider configured"}, nil
			}
			return map[string]any{"ok": true, "provider": p}, nil
		}
		var a activeDoc
		if err := json.Unmarshal(active, &a); err != nil {
			return nil, fmt.Errorf("corrupt active doc: %w", err)
		}
		pVal, _, err := sc.get(kindProvider, a.Nickname)
		if err != nil {
			return nil, err
		}
		if pVal == nil {
			// Active points to a deleted provider; clear it.
			_, _ = sc.del(kindProvider, activeID)
			return map[string]any{"ok": false, "error": "active provider removed"}, nil
		}
		var p Provider
		if err := json.Unmarshal(pVal, &p); err != nil {
			return nil, fmt.Errorf("corrupt provider doc: %w", err)
		}
		return map[string]any{"ok": true, "provider": p}, nil
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
		return map[string]any{"ok": true, "imported": imported, "count": len(imported)}, nil
	})

	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "provider:", err)
		os.Exit(1)
	}
}

// ---- helpers ----

func providerActiveExists(sc *storeClient) bool {
	_, rev, err := sc.get(kindProvider, activeID)
	return err == nil && rev != nil
}

func providerActiveIs(sc *storeClient, nickname string) bool {
	raw, _, err := sc.get(kindProvider, activeID)
	if err != nil || raw == nil {
		return false
	}
	var a activeDoc
	if json.Unmarshal(raw, &a) != nil {
		return false
	}
	return a.Nickname == nickname
}

func activateProvider(comp *sdk.Component, sc *storeClient, nickname string) error {
	previous := ""
	if raw, _, err := sc.get(kindProvider, activeID); err == nil && raw != nil {
		var a activeDoc
		if json.Unmarshal(raw, &a) == nil {
			previous = a.Nickname
		}
	}
	doc := activeDoc{Nickname: nickname, UpdatedAt: time.Now()}
	if _, err := sc.put(kindProvider, activeID, doc, 0); err != nil {
		return err
	}
	// Notify plugins so they can enable their provider-specific tools.
	_ = comp.Emit("ev.provider.switch", map[string]any{
		"nickname": nickname, "previous": previous, "at": time.Now(),
	})
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
		_, _ = sc.put(kindProvider, activeID, activeDoc{}, 0) // clear
		return nil
	}
	sort.Strings(names)
	return activateProvider(comp, sc, names[0])
}
