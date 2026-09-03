// Live model discovery (option B): the llm component serves as an
// x-models-source plugin. After each successful chat it probes the
// provider's own /models endpoint (authoritative ids — models.dev lags and
// can disagree on spelling, e.g. Synthetic's "hf:zai-org/GLM-5.3-Flash")
// and caches the id list per provider+endpoint. The models component calls
// the source tool on its hourly refresh cycle and applies the result as a
// JSON Merge Patch, so ids the catalog lacks become visible to every bus
// client without waiting for models.dev.
//
// The patch only ever ADDS models under the provider's catalog id — it
// never edits or deletes catalog metadata (limits/pricing stay models.dev's
// authority). A provider id is used when the endpoint does not yield one;
// probing is skipped for protocols without a compatible /models route.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	sdk "niffler.dev/sdk"
)

const (
	// modelsSourceVersion must match the x-models-source protocol version
	// the models component speaks (docs/MANUAL.md §Source plugins).
	modelsSourceVersion = 1
	// liveProbeTTL bounds how often a chat success actually hits the
	// endpoint; between probes the cached id list is re-published as-is.
	liveProbeTTL = 10 * time.Minute
	// liveProbeTimeout bounds a single probe request.
	liveProbeTimeout = 8 * time.Second
)

// liveModelCache holds the last-known-good id list per provider key.
type liveModelCache struct {
	mu        sync.Mutex
	fetchedAt map[string]time.Time
	models    map[string][]string
	endpoints map[string]string
}

var liveModels = liveModelCache{
	fetchedAt: make(map[string]time.Time),
	models:    make(map[string][]string),
	endpoints: make(map[string]string),
}

// modelsSourceHandler is the hidden tool the models component calls with
// {"version": 1}. It returns {"patch": {...}} in the x-models-source v1
// shape: adds under "<catalog-provider>".models, nulls never emitted.
func modelsSourceHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	var args struct {
		Version int `json:"version"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("bad models source args: %w", err)
		}
	}
	if args.Version != modelsSourceVersion {
		return nil, fmt.Errorf("unsupported models source version %d", args.Version)
	}
	liveModels.mu.Lock()
	patch := make(map[string]any, len(liveModels.models))
	for key, ids := range liveModels.models {
		if len(ids) == 0 {
			continue
		}
		// Key is "<catalogProvider>|<baseURL>"; the patch nests under the
		// provider id only.
		providerID := key
		if i := strings.IndexByte(key, '|'); i >= 0 {
			providerID = key[:i]
		}
		models := make(map[string]any, len(ids))
		for _, id := range ids {
			// Minimal descriptor: the models component merges the patch
			// over models.dev, which supplies everything else.
			models[id] = map[string]any{"id": id}
		}
		patch[providerID] = map[string]any{"models": models}
	}
	liveModels.mu.Unlock()
	if len(patch) == 0 {
		return nil, fmt.Errorf("no live model data yet")
	}
	return map[string]any{"patch": patch}, nil
}

// maybeProbeLiveModels records a successful chat's provider/model and, when
// the per-provider cache is stale or empty, probes the endpoint in the
// background. Called from chatHandler after resolution, before the request;
// failures are silent — the probe is best-effort enrichment, never a chat
// dependency.
func maybeProbeLiveModels(ctx context.Context, c *sdk.Component, resolved resolvedConfig) {
	if c == nil || resolved.Provider.BaseURL == "" || !liveModelsServingIDs(resolved.Provider.Protocol) {
		return
	}
	catalogID := resolved.Catalog
	if catalogID == "" {
		catalogID = strings.ToLower(resolved.ProviderName)
	}
	key := catalogID + "|" + resolved.Provider.BaseURL

	liveModels.mu.Lock()
	last := liveModels.fetchedAt[key]
	liveModels.mu.Unlock()
	if time.Since(last) < liveProbeTTL {
		return
	}
	// Record immediately (bounded retry by TTL) and probe out of band: a
	// hung endpoint must not delay the chat.
	liveModels.mu.Lock()
	liveModels.fetchedAt[key] = time.Now()
	liveModels.mu.Unlock()
	go func() {
		probeCtx, cancel := context.WithTimeout(context.Background(), liveProbeTimeout)
		defer cancel()
		ids, err := probeLiveModelIDs(probeCtx, resolved.Provider)
		if err != nil || len(ids) == 0 {
			return
		}
		liveModels.mu.Lock()
		liveModels.models[key] = ids
		liveModels.endpoints[key] = resolved.Provider.BaseURL
		liveModels.mu.Unlock()
	}()
}

// liveModelsServingIDs reports whether a protocol exposes an OpenAI-style
// GET /models route. Codex (ChatGPT backend) does not.
func liveModelsServingIDs(protocol string) bool {
	return protocol == "" || protocol == protocolOpenAI || protocol == protocolAnthropic
}

// probeLiveModelIDs fetches {base}/models and extracts the id list. Shared
// envelope handling with the provider component's probe. OAuth credentials
// arrive here already mapped into APIKey by the stored-provider registry.
func probeLiveModelIDs(ctx context.Context, p provider) ([]string, error) {
	if p.APIKey == "" {
		return nil, fmt.Errorf("no credential")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimRight(p.BaseURL, "/")+"/models", nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+p.APIKey)
	if p.Protocol == protocolAnthropic {
		request.Header.Set("anthropic-version", "2023-06-01")
		if p.AuthType != authOAuth {
			request.Header.Set("x-api-key", p.APIKey)
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
		return nil, fmt.Errorf("GET models: %s", response.Status)
	}
	var envelope struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(envelope.Data))
	for _, entry := range envelope.Data {
		if entry.ID != "" {
			ids = append(ids, entry.ID)
		}
	}
	return ids, nil
}
