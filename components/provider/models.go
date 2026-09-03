package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Live /models probing (option A): a provider's own endpoint is the
// authority on which model ids it currently serves — models.dev metadata
// (limits, pricing) lags and can disagree on id spelling (Synthetic serves
// "hf:zai-org/GLM-5.3-Flash"). Results are cached on disk per endpoint so
// the connect form's prefill and the agent's checks stay cheap and work
// across component restarts; a TTL well below the catalog's hourly cadence
// keeps availability fresh without hammering the endpoint.

const (
	modelsProbeTimeout = 10 * time.Second
	modelsCacheTTL     = 5 * time.Minute
)

// modelsCacheEntry is one on-disk snapshot of an endpoint's model list.
type modelsCacheEntry struct {
	FetchedAt time.Time     `json:"fetchedAt"`
	Endpoint  string        `json:"endpoint"`
	Models    []servedModel `json:"models"`
}

// servedModel is one id the provider currently serves. Extra endpoint
// fields (owned_by, created, …) are preserved for callers that want them.
type servedModel struct {
	ID    string         `json:"id"`
	Extra map[string]any `json:"extra,omitempty"`
}

// modelsCacheMu guards the on-disk cache; probes may run concurrently from
// the agent (tool call) and the TUI (connect form) for the same provider.
var modelsCacheMu sync.Mutex

// modelsCachePath returns var/models-served/<hash of endpoint>.json under
// the Niffler root, mirroring the models component's var/models cache dir.
func modelsCachePath(baseURL string) (string, error) {
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	dir := filepath.Join(root, "var", "models-served")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(baseURL))
	name := hex.EncodeToString(sum[:]) + ".json"
	return filepath.Join(dir, name), nil
}

// listProviderModels returns the model ids served by p's endpoint. Fresh
// probes replace the cache; on probe failure the last-known-good cache is
// returned (marked cached) unless it is missing entirely.
func listProviderModels(p Provider, refresh bool) ([]servedModel, string, bool, error) {
	if p.BaseURL == "" {
		return nil, "", false, fmt.Errorf("provider %q: no base URL", p.Nickname)
	}
	endpoint := modelsListURL(p.BaseURL)

	if !refresh {
		if entry, ok := readModelsCache(endpoint); ok {
			return entry.Models, entry.Endpoint, true, nil
		}
	}

	models, err := probeModelsList(p, endpoint)
	if err != nil {
		// Serve stale cache rather than failing outright — the caller
		// (connect form) degrades to the models.dev catalog on error.
		if entry, ok := readModelsCache(endpoint); ok {
			return entry.Models, entry.Endpoint, true, nil
		}
		return nil, endpoint, false, err
	}
	writeModelsCache(endpoint, models)
	return models, endpoint, false, nil
}

// modelsListURL joins the chat base URL with the models path the same way
// OpenAI-compatible clients do: <base>/models (base may or may not end in
// /v1; go-openai treats the configured BaseURL as the full prefix).
func modelsListURL(baseURL string) string {
	return strings.TrimRight(baseURL, "/") + "/models"
}

// probeModelsList performs the live GET. Both OpenAI-compatible endpoints
// ({"data":[{"id":...}]}) and Anthropic ({"data":[{"id":...}]}) share the
// same envelope shape; the key is the bearer token for either protocol.
func probeModelsList(p Provider, endpoint string) ([]servedModel, error) {
	key := p.APIKey
	if p.AuthType == authOAuth && p.OAuth != nil {
		key = p.OAuth.Access
	}
	if key == "" {
		return nil, fmt.Errorf("no credential for %q", p.Nickname)
	}
	ctx, cancel := context.WithTimeout(context.Background(), modelsProbeTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	// Match the chat request identity: Bearer for OpenAI-compatible and
	// Anthropic protocol alike (anthropic.go uses Authorization for OAuth
	// Claude, x-api-key otherwise; the /models endpoint accepts Bearer).
	request.Header.Set("Authorization", "Bearer "+key)
	if p.Protocol == protocolAnthropic {
		request.Header.Set("anthropic-version", "2023-06-01")
		if p.AuthType != authOAuth {
			request.Header.Set("x-api-key", key)
		}
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK {
		trimmed := strings.TrimSpace(string(body))
		if len(trimmed) > 300 {
			trimmed = trimmed[:300]
		}
		return nil, fmt.Errorf("GET %s: %s %s", endpoint, response.Status, trimmed)
	}
	return decodeModelsEnvelope(body)
}

// decodeModelsEnvelope extracts ids from the standard {"data":[...]}
// envelope, tolerating bare arrays and skipping entries without ids.
func decodeModelsEnvelope(body []byte) ([]servedModel, error) {
	var envelope struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		// Some gateways return a bare array.
		var bare []map[string]any
		if err2 := json.Unmarshal(body, &bare); err2 != nil {
			return nil, fmt.Errorf("decode models response: %w", err)
		}
		envelope.Data = bare
	}
	models := make([]servedModel, 0, len(envelope.Data))
	seen := make(map[string]bool, len(envelope.Data))
	for _, entry := range envelope.Data {
		id, _ := entry["id"].(string)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		model := servedModel{ID: id, Extra: make(map[string]any)}
		for k, v := range entry {
			if k != "id" {
				model.Extra[k] = v
			}
		}
		models = append(models, model)
	}
	if len(models) == 0 {
		return nil, fmt.Errorf("models response has no usable entries")
	}
	return models, nil
}

func readModelsCache(endpoint string) (modelsCacheEntry, bool) {
	modelsCacheMu.Lock()
	defer modelsCacheMu.Unlock()
	path, err := modelsCachePath(endpoint)
	if err != nil {
		return modelsCacheEntry{}, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return modelsCacheEntry{}, false
	}
	var entry modelsCacheEntry
	if json.Unmarshal(raw, &entry) != nil || len(entry.Models) == 0 {
		return modelsCacheEntry{}, false
	}
	if time.Since(entry.FetchedAt) > modelsCacheTTL {
		return modelsCacheEntry{}, false
	}
	return entry, true
}

func writeModelsCache(endpoint string, models []servedModel) {
	modelsCacheMu.Lock()
	defer modelsCacheMu.Unlock()
	path, err := modelsCachePath(endpoint)
	if err != nil {
		return
	}
	entry := modelsCacheEntry{FetchedAt: time.Now().UTC(), Endpoint: endpoint, Models: models}
	raw, err := json.Marshal(entry)
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, raw, 0o644) == nil {
		_ = os.Rename(tmp, path)
	}
}
