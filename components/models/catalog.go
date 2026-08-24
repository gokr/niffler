package main

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	sdk "niffler.dev/sdk"
)

const (
	defaultModelsURL   = "https://models.dev/api.json"
	defaultSourceOrder = 100
	maxCatalogBytes    = 16 << 20
)

// seedData is a small offline floor, not a replacement for the live catalog.
// It preserves Niffler's shipped DeepSeek setup on a first run without network.
//
//go:embed seed.json
var seedData []byte

type modelSource struct {
	Component string `json:"component"`
	Tool      string `json:"tool"`
	Priority  int    `json:"priority"`
	Version   int    `json:"version"`
}

func (s modelSource) key() string {
	return s.Component + "/" + s.Tool
}

type sourceStatus struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Component string `json:"component,omitempty"`
	Tool      string `json:"tool,omitempty"`
	Priority  int    `json:"priority,omitempty"`
	State     string `json:"state"`
	Origin    string `json:"origin,omitempty"`
	UpdatedAt string `json:"updatedAt,omitempty"`
	Cached    bool   `json:"cached,omitempty"`
	Error     string `json:"error,omitempty"`
}

type registration struct {
	Name  string `json:"name"`
	Tools []struct {
		Name   string         `json:"name"`
		Schema map[string]any `json:"schema"`
	} `json:"tools"`
}

type catalogState struct {
	mu        sync.RWMutex
	refreshMu sync.Mutex

	root         string
	cacheDir     string
	cachePath    string
	sourceURL    string
	sourcePath   string
	overridePath string
	offline      bool
	cacheTTL     time.Duration
	client       *http.Client

	base           map[string]any
	effective      map[string]any
	sources        map[string]modelSource
	patches        map[string]map[string]any
	statuses       map[string]sourceStatus
	baselineStatus sourceStatus
	overrideStatus *sourceStatus
	overridePatch  map[string]any
	updatedAt      time.Time
}

func newCatalogState(root string) *catalogState {
	cacheDir := os.Getenv("NIF_MODELS_CACHE_DIR")
	if cacheDir == "" {
		cacheDir = filepath.Join(root, "var", "models")
	}
	sourceURL := os.Getenv("NIF_MODELS_URL")
	if sourceURL == "" {
		sourceURL = defaultModelsURL
	} else if !strings.Contains(pathLastSegment(sourceURL), ".json") {
		// Only append api.json when the final path segment is not already a
		// JSON endpoint — full endpoints with query strings stay untouched.
		sourceURL = strings.TrimRight(sourceURL, "/") + "/api.json"
	}

	state := &catalogState{
		root:         root,
		cacheDir:     cacheDir,
		cachePath:    filepath.Join(cacheDir, "api.json"),
		sourceURL:    sourceURL,
		sourcePath:   os.Getenv("NIF_MODELS_PATH"),
		overridePath: os.Getenv("NIF_MODELS_OVERRIDE"),
		offline:      envBool("NIF_MODELS_OFFLINE"),
		cacheTTL:     envDuration("NIF_MODELS_CACHE_TTL", 5*time.Minute),
		client:       &http.Client{Timeout: 12 * time.Second},
		sources:      make(map[string]modelSource),
		patches:      make(map[string]map[string]any),
		statuses:     make(map[string]sourceStatus),
	}
	state.loadInitialCatalog()
	return state
}

func envBool(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// pathLastSegment returns the final path segment (query/fragment excluded).
func pathLastSegment(raw string) string {
	trimmed := strings.TrimRight(raw, "/")
	if query := strings.IndexAny(trimmed, "?#"); query >= 0 {
		trimmed = trimmed[:query]
	}
	if slash := strings.LastIndexByte(trimmed, '/'); slash >= 0 {
		return trimmed[slash+1:]
	}
	return trimmed
}

func envDuration(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	if value == "0" {
		return 0
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration < 0 {
		return fallback
	}
	return duration
}

func (c *catalogState) loadInitialCatalog() {
	seed, err := decodeCatalog(seedData)
	if err != nil {
		seed = map[string]any{}
	}
	c.base = seed
	c.baselineStatus = sourceStatus{
		ID: "models.dev", Kind: "baseline", State: "seed", Origin: "embedded seed",
	}

	if c.sourcePath != "" {
		if loaded, loadErr := loadCatalogFile(c.sourcePath); loadErr == nil {
			c.base = loaded
			c.baselineStatus = sourceStatus{
				ID: "models.dev", Kind: "baseline", State: "active", Origin: c.sourcePath,
				UpdatedAt: fileTimestamp(c.sourcePath),
			}
		} else {
			c.baselineStatus.Error = loadErr.Error()
		}
	} else {
		loaded, loadErr := loadCatalogFile(c.cachePath)
		if loadErr == nil {
			c.base = loaded
			c.baselineStatus = sourceStatus{
				ID: "models.dev", Kind: "baseline", State: "cached", Origin: c.cachePath,
				UpdatedAt: fileTimestamp(c.cachePath), Cached: true,
			}
		} else if !os.IsNotExist(loadErr) {
			c.baselineStatus.Error = "invalid cache: " + loadErr.Error()
			_ = os.Remove(c.cachePath)
		}
	}

	c.mu.Lock()
	c.rebuildLocked()
	c.mu.Unlock()
}

func fileTimestamp(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return ""
	}
	return info.ModTime().UTC().Format(time.RFC3339)
}

func loadCatalogFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return decodeCatalog(data)
}

func decodeObject(data []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value map[string]any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if value == nil {
		return nil, errors.New("expected a JSON object")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("unexpected data after JSON object")
	}
	return value, nil
}

func decodeCatalog(data []byte) (map[string]any, error) {
	catalog, err := decodeObject(data)
	if err != nil {
		return nil, err
	}
	usable := 0
	for id, raw := range catalog {
		provider, ok := raw.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("provider %q is not an object", id)
		}
		models, ok := provider["models"]
		if !ok {
			continue
		}
		modelMap, ok := models.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("provider %q models is not an object", id)
		}
		for _, rawModel := range modelMap {
			if _, modelOK := rawModel.(map[string]any); modelOK {
				usable++
			}
		}
	}
	if usable == 0 {
		// A catalog with no usable model entries would replace the
		// last-known-good cache with an effectively empty one — reject it.
		return nil, errors.New("catalog has no usable model entries")
	}
	return catalog, nil
}

func cloneValue(value any) any {
	switch value := value.(type) {
	case map[string]any:
		copy := make(map[string]any, len(value))
		for key, child := range value {
			copy[key] = cloneValue(child)
		}
		return copy
	case []any:
		copy := make([]any, len(value))
		for index, child := range value {
			copy[index] = cloneValue(child)
		}
		return copy
	default:
		return value
	}
}

func cloneObject(value map[string]any) map[string]any {
	return cloneValue(value).(map[string]any)
}

// applyMergePatch implements the object portion of RFC 7396. Objects merge,
// null deletes, and arrays or scalar values replace the previous value.
func applyMergePatch(target, patch map[string]any) map[string]any {
	for key, value := range patch {
		if value == nil {
			delete(target, key)
			continue
		}
		patchObject, isObject := value.(map[string]any)
		if !isObject {
			target[key] = cloneValue(value)
			continue
		}
		targetObject, _ := target[key].(map[string]any)
		if targetObject == nil {
			targetObject = make(map[string]any)
		} else {
			targetObject = cloneObject(targetObject)
		}
		target[key] = applyMergePatch(targetObject, patchObject)
	}
	return target
}

func normalizeCatalog(catalog map[string]any) {
	for providerID, rawProvider := range catalog {
		provider, ok := rawProvider.(map[string]any)
		if !ok {
			delete(catalog, providerID)
			continue
		}
		if stringValue(provider["id"]) == "" {
			provider["id"] = providerID
		}
		if stringValue(provider["name"]) == "" {
			provider["name"] = providerID
		}
		models, ok := provider["models"].(map[string]any)
		if !ok {
			provider["models"] = map[string]any{}
			continue
		}
		for modelID, rawModel := range models {
			model, ok := rawModel.(map[string]any)
			if !ok {
				delete(models, modelID)
				continue
			}
			if stringValue(model["id"]) == "" {
				model["id"] = modelID
			}
			if stringValue(model["name"]) == "" {
				model["name"] = modelID
			}
		}
	}
}

func (c *catalogState) rebuildLocked() {
	next := cloneObject(c.base)
	sources := make([]modelSource, 0, len(c.sources))
	for _, source := range c.sources {
		sources = append(sources, source)
	}
	sort.Slice(sources, func(i, j int) bool {
		if sources[i].Priority != sources[j].Priority {
			return sources[i].Priority < sources[j].Priority
		}
		return sources[i].key() < sources[j].key()
	})
	for _, source := range sources {
		if patch := c.patches[source.key()]; patch != nil {
			next = applyMergePatch(next, patch)
		}
	}

	c.overrideStatus = nil
	if c.overridePath != "" {
		status := sourceStatus{
			ID: "local-override", Kind: "override", State: "active", Origin: c.overridePath,
			Priority: int(^uint(0) >> 1), UpdatedAt: fileTimestamp(c.overridePath),
		}
		patch, err := loadCatalogFileAsPatch(c.overridePath)
		if err != nil {
			// Last-known-good override: a file being rewritten mid-refresh
			// must not silently discard all user corrections.
			if c.overridePatch != nil {
				status.State = "stale"
				status.Cached = true
				status.Error = err.Error()
				next = applyMergePatch(next, c.overridePatch)
			} else {
				status.State = "error"
				status.Error = err.Error()
			}
		} else {
			c.overridePatch = patch
			next = applyMergePatch(next, patch)
		}
		c.overrideStatus = &status
	}

	normalizeCatalog(next)
	c.effective = next
	c.updatedAt = time.Now().UTC()
}

func loadCatalogFileAsPatch(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return decodeObject(data)
}

func numberValue(value any) (int, bool) {
	switch value := value.(type) {
	case json.Number:
		number, err := strconv.Atoi(value.String())
		return number, err == nil
	case float64:
		return int(value), value == float64(int(value))
	case int:
		return value, true
	default:
		return 0, false
	}
}

func sourcesFromRegistration(reg registration) []modelSource {
	var sources []modelSource
	for _, tool := range reg.Tools {
		extension, ok := tool.Schema["x-models-source"].(map[string]any)
		if !ok {
			continue
		}
		version, ok := numberValue(extension["version"])
		if !ok || version != 1 {
			continue
		}
		priority := defaultSourceOrder
		if value, ok := numberValue(extension["priority"]); ok {
			priority = value
		}
		sources = append(sources, modelSource{
			Component: reg.Name, Tool: tool.Name, Priority: priority, Version: version,
		})
	}
	return sources
}

func (c *catalogState) register(data []byte) bool {
	var reg registration
	if err := json.Unmarshal(data, &reg); err != nil || reg.Name == "" {
		return false
	}
	return c.replaceComponentSources(reg.Name, sourcesFromRegistration(reg))
}

func (c *catalogState) depart(data []byte) bool {
	var reg registration
	if err := json.Unmarshal(data, &reg); err != nil || reg.Name == "" {
		return false
	}
	return c.replaceComponentSources(reg.Name, nil)
}

func (c *catalogState) replaceComponentSources(component string, next []modelSource) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	changed := false
	for key, source := range c.sources {
		if source.Component == component {
			delete(c.sources, key)
			delete(c.statuses, key)
			changed = true
		}
	}
	for _, source := range next {
		key := source.key()
		c.sources[key] = source
		if _, exists := c.statuses[key]; !exists {
			c.statuses[key] = sourceStatus{
				ID: key, Kind: "plugin", Component: source.Component, Tool: source.Tool,
				Priority: source.Priority, State: "registered",
			}
		}
		changed = true
	}
	if changed {
		c.rebuildLocked()
	}
	return changed
}

func (c *catalogState) discover(ctx context.Context, comp *sdk.Component) error {
	requestCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	raw, err := comp.RequestContext(requestCtx, "core", "catalog", map[string]any{"op": "snapshot"})
	if err != nil {
		return err
	}
	var snapshot struct {
		Components []registration `json:"components"`
	}
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		return fmt.Errorf("decode core catalog snapshot: %w", err)
	}

	next := make(map[string]modelSource)
	for _, reg := range snapshot.Components {
		for _, source := range sourcesFromRegistration(reg) {
			next[source.key()] = source
		}
	}

	c.mu.Lock()
	c.sources = next
	for key, status := range c.statuses {
		if _, exists := next[key]; !exists {
			delete(c.statuses, key)
			continue
		}
		status.Priority = next[key].Priority
		c.statuses[key] = status
	}
	for key, source := range next {
		if _, exists := c.statuses[key]; !exists {
			c.statuses[key] = sourceStatus{
				ID: key, Kind: "plugin", Component: source.Component, Tool: source.Tool,
				Priority: source.Priority, State: "registered",
			}
		}
	}
	c.rebuildLocked()
	c.mu.Unlock()
	return nil
}

func (c *catalogState) refresh(ctx context.Context, comp *sdk.Component, force bool) map[string]any {
	c.refreshMu.Lock()
	defer c.refreshMu.Unlock()

	var refreshErrors []string
	if err := c.discover(ctx, comp); err != nil {
		refreshErrors = append(refreshErrors, "source discovery: "+err.Error())
	}
	if err := c.refreshBaseline(ctx, force); err != nil {
		refreshErrors = append(refreshErrors, "models.dev: "+err.Error())
	}

	c.mu.RLock()
	sources := make([]modelSource, 0, len(c.sources))
	for _, source := range c.sources {
		sources = append(sources, source)
	}
	c.mu.RUnlock()
	sort.Slice(sources, func(i, j int) bool {
		if sources[i].Priority != sources[j].Priority {
			return sources[i].Priority < sources[j].Priority
		}
		return sources[i].key() < sources[j].key()
	})
	for _, source := range sources {
		if ctx.Err() != nil {
			break
		}
		if err := c.refreshSource(ctx, comp, source); err != nil {
			refreshErrors = append(refreshErrors, source.key()+": "+truncate(err.Error(), 2000))
		}
	}

	c.mu.Lock()
	c.rebuildLocked()
	if c.overrideStatus != nil && (c.overrideStatus.State == "error" || c.overrideStatus.State == "stale") {
		refreshErrors = append(refreshErrors, "local override: "+c.overrideStatus.Error)
	}
	c.mu.Unlock()
	report := c.report()
	report["ok"] = len(refreshErrors) == 0
	if len(refreshErrors) > 0 {
		report["errors"] = refreshErrors
	}
	if ctx.Err() == nil {
		_ = comp.Emit("ev.models.updated", map[string]any{
			"providers": report["providers"], "models": report["models"],
			"sources": report["sourceCount"], "updatedAt": report["updatedAt"],
		})
	}
	return report
}

func (c *catalogState) refreshBaseline(ctx context.Context, force bool) error {
	if c.sourcePath != "" {
		loaded, err := loadCatalogFile(c.sourcePath)
		if err != nil {
			c.setBaselineError(err)
			return err
		}
		c.mu.Lock()
		c.base = loaded
		c.baselineStatus = sourceStatus{
			ID: "models.dev", Kind: "baseline", State: "active", Origin: c.sourcePath,
			UpdatedAt: fileTimestamp(c.sourcePath),
		}
		c.mu.Unlock()
		return nil
	}
	if c.offline {
		return nil
	}
	if !force && c.cacheFresh() {
		return nil
	}

	loaded, err := c.fetchCatalog(ctx)
	if err != nil {
		c.setBaselineError(err)
		return err
	}
	if err := writeJSONAtomic(c.cachePath, loaded); err != nil {
		c.setBaselineError(err)
		return err
	}
	c.mu.Lock()
	c.base = loaded
	c.baselineStatus = sourceStatus{
		ID: "models.dev", Kind: "baseline", State: "active", Origin: displayURL(c.sourceURL),
		UpdatedAt: time.Now().UTC().Format(time.RFC3339), Cached: true,
	}
	c.mu.Unlock()
	return nil
}

func (c *catalogState) setBaselineError(err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	status := c.baselineStatus
	if status.State == "seed" {
		status.State = "error"
	} else {
		status.State = "stale"
		status.Cached = true
	}
	status.Error = err.Error()
	c.baselineStatus = status
}

func (c *catalogState) cacheFresh() bool {
	if c.cacheTTL <= 0 {
		return false
	}
	info, err := os.Stat(c.cachePath)
	return err == nil && time.Since(info.ModTime()) < c.cacheTTL
}

func (c *catalogState) fetchCatalog(ctx context.Context) (map[string]any, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.sourceURL, nil)
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", "niffler-models/0.1")
		request.Header.Set("Accept", "application/json")
		response, err := c.client.Do(request)
		if err == nil {
			body, readErr := io.ReadAll(io.LimitReader(response.Body, maxCatalogBytes+1))
			response.Body.Close()
			if readErr != nil {
				lastErr = readErr
			} else if len(body) > maxCatalogBytes {
				return nil, fmt.Errorf("catalog exceeds %d bytes", maxCatalogBytes)
			} else if response.StatusCode >= 200 && response.StatusCode < 300 {
				catalog, decodeErr := decodeCatalog(body)
				if decodeErr != nil {
					return nil, fmt.Errorf("invalid catalog: %w", decodeErr)
				}
				return catalog, nil
			} else {
				lastErr = fmt.Errorf("HTTP %d: %s", response.StatusCode,
					truncate(strings.TrimSpace(string(body)), 2000))
				if response.StatusCode < 500 && response.StatusCode != http.StatusTooManyRequests {
					return nil, lastErr
				}
			}
		} else {
			lastErr = err
		}
		if attempt < 2 {
			delay := time.NewTimer(time.Duration(200*(1<<attempt)) * time.Millisecond)
			select {
			case <-ctx.Done():
				delay.Stop()
				return nil, ctx.Err()
			case <-delay.C:
			}
		}
	}
	return nil, lastErr
}

func (c *catalogState) refreshSource(ctx context.Context, comp *sdk.Component, source modelSource) error {
	requestCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	raw, err := comp.RequestContext(requestCtx, source.Component, source.Tool, map[string]any{"version": 1})
	if err == nil {
		var result struct {
			Patch json.RawMessage `json:"patch"`
		}
		if decodeErr := json.Unmarshal(raw, &result); decodeErr != nil {
			err = fmt.Errorf("decode result: %w", decodeErr)
		} else if len(result.Patch) == 0 || bytes.Equal(result.Patch, []byte("null")) {
			err = errors.New("result has no patch object")
		} else {
			patch, patchErr := decodeObject(result.Patch)
			if patchErr != nil {
				err = fmt.Errorf("decode patch: %w", patchErr)
			} else if writeErr := writeJSONAtomic(c.sourceCachePath(source), patch); writeErr != nil {
				err = fmt.Errorf("cache patch: %w", writeErr)
			} else {
				c.mu.Lock()
				c.patches[source.key()] = patch
				c.statuses[source.key()] = sourceStatus{
					ID: source.key(), Kind: "plugin", Component: source.Component, Tool: source.Tool,
					Priority: source.Priority, State: "active",
					UpdatedAt: time.Now().UTC().Format(time.RFC3339), Cached: true,
				}
				c.mu.Unlock()
				return nil
			}
		}
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	patch := c.patches[source.key()]
	cachedErr := ""
	if patch == nil {
		if cached, cacheErr := loadCatalogFileAsPatch(c.sourceCachePath(source)); cacheErr == nil {
			patch = cached
			c.patches[source.key()] = cached
		} else if !os.IsNotExist(cacheErr) {
			cachedErr = "; cached patch unreadable: " + truncate(cacheErr.Error(), 300)
		}
	}
	state := "error"
	if patch != nil {
		state = "stale"
	}
	previous := c.statuses[source.key()]
	c.statuses[source.key()] = sourceStatus{
		ID: source.key(), Kind: "plugin", Component: source.Component, Tool: source.Tool,
		Priority: source.Priority, State: state,
		Error:     truncate(err.Error(), 2000) + cachedErr,
		UpdatedAt: previous.UpdatedAt, Cached: patch != nil,
	}
	return err
}

func safeName(value string) string {
	return strings.Map(func(char rune) rune {
		if char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' ||
			char >= '0' && char <= '9' || char == '-' || char == '_' || char == '.' {
			return char
		}
		return '_'
	}, value)
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "…"
}

// displayURL strips credentials, query parameters and fragments so a
// configured source URL can be shown in status output without leaking
// signed-URL tokens.
func displayURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return truncate(raw, 300)
	}
	parsed.User = nil
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String()
}

func (c *catalogState) sourceCachePath(source modelSource) string {
	return filepath.Join(c.cacheDir, "sources", safeName(source.Component)+"--"+safeName(source.Tool)+".json")
}

func writeJSONAtomic(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func stringValue(value any) string {
	valueString, _ := value.(string)
	return valueString
}

func boolValue(value any) (bool, bool) {
	valueBool, ok := value.(bool)
	return valueBool, ok
}

func objectValue(value any) map[string]any {
	object, _ := value.(map[string]any)
	return object
}

func arrayContains(value any, wanted string) bool {
	items, _ := value.([]any)
	for _, item := range items {
		if stringValue(item) == wanted {
			return true
		}
	}
	return false
}

func providerConfigured(providerID string, provider map[string]any) bool {
	envNames, _ := provider["env"].([]any)
	for _, rawName := range envNames {
		if name := stringValue(rawName); name != "" && os.Getenv(name) != "" {
			return true
		}
	}
	// The shipped harness setup: DeepSeek runs on NIF_OPENAI_API_KEY even
	// though the catalog names the provider-native variable.
	if providerID == "deepseek" && os.Getenv("NIF_OPENAI_API_KEY") != "" {
		return true
	}
	// Named providers configured through NIF_LLM_PROVIDERS.
	if raw := os.Getenv("NIF_LLM_PROVIDERS"); raw != "" {
		var extra map[string]any
		if json.Unmarshal([]byte(raw), &extra) == nil {
			if _, exists := extra[providerID]; exists {
				return true
			}
		}
	}
	return false
}

func secretMetadataKey(key string) bool {
	normalized := strings.Map(func(char rune) rune {
		if char >= 'a' && char <= 'z' || char >= '0' && char <= '9' {
			return char
		}
		if char >= 'A' && char <= 'Z' {
			return char + ('a' - 'A')
		}
		return -1
	}, key)
	if normalized == "auth" || normalized == "bearer" || normalized == "cookie" ||
		normalized == "credentials" {
		return true
	}
	for _, suffix := range []string{
		"apikey", "password", "secret", "token", "credential", "credentials",
		"authorization", "privatekey", "cookie",
	} {
		if strings.HasSuffix(normalized, suffix) {
			return true
		}
	}
	return false
}

func redactMetadata(value any) any {
	switch value := value.(type) {
	case map[string]any:
		redacted := make(map[string]any, len(value))
		for key, child := range value {
			if !secretMetadataKey(key) {
				redacted[key] = redactMetadata(child)
			}
		}
		return redacted
	case []any:
		redacted := make([]any, len(value))
		for index, child := range value {
			redacted[index] = redactMetadata(child)
		}
		return redacted
	default:
		return value
	}
}

func providerMetadata(provider map[string]any) map[string]any {
	metadata := make(map[string]any, len(provider)-1)
	for key, value := range provider {
		if key != "models" && !secretMetadataKey(key) {
			metadata[key] = redactMetadata(value)
		}
	}
	return metadata
}

func (c *catalogState) providers(query string, configured *bool) []map[string]any {
	c.mu.RLock()
	defer c.mu.RUnlock()
	query = strings.ToLower(strings.TrimSpace(query))
	ids := make([]string, 0, len(c.effective))
	for id := range c.effective {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	result := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		provider := objectValue(c.effective[id])
		if provider == nil {
			continue
		}
		isConfigured := providerConfigured(id, provider)
		if configured != nil && isConfigured != *configured {
			continue
		}
		name := stringValue(provider["name"])
		if query != "" && !strings.Contains(strings.ToLower(id+" "+name), query) {
			continue
		}
		entry := providerMetadata(provider)
		entry["id"] = id
		entry["configured"] = isConfigured
		entry["modelCount"] = len(objectValue(provider["models"]))
		result = append(result, entry)
	}
	return result
}

type listModelsArgs struct {
	Provider   string `json:"provider"`
	Query      string `json:"query"`
	Status     string `json:"status"`
	Input      string `json:"input"`
	Reasoning  *bool  `json:"reasoning"`
	ToolCall   *bool  `json:"toolCall"`
	Configured *bool  `json:"configured"`
	Limit      int    `json:"limit"`
}

func (c *catalogState) models(args listModelsArgs) ([]map[string]any, int) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	limit := args.Limit
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	query := strings.ToLower(strings.TrimSpace(args.Query))
	providerIDs := make([]string, 0, len(c.effective))
	for id := range c.effective {
		providerIDs = append(providerIDs, id)
	}
	sort.Strings(providerIDs)
	result := make([]map[string]any, 0, limit)
	total := 0
	for _, providerID := range providerIDs {
		if args.Provider != "" && args.Provider != providerID {
			continue
		}
		provider := objectValue(c.effective[providerID])
		if provider == nil {
			continue
		}
		isConfigured := providerConfigured(providerID, provider)
		if args.Configured != nil && isConfigured != *args.Configured {
			continue
		}
		models := objectValue(provider["models"])
		modelIDs := make([]string, 0, len(models))
		for id := range models {
			modelIDs = append(modelIDs, id)
		}
		sort.Strings(modelIDs)
		for _, modelID := range modelIDs {
			model := objectValue(models[modelID])
			if model == nil || !modelMatches(modelID, model, query, args) {
				continue
			}
			total++
			if len(result) >= limit {
				continue
			}
			entry := redactMetadata(model).(map[string]any)
			entry["provider"] = providerID
			entry["reference"] = providerID + "/" + modelID
			entry["configured"] = isConfigured
			result = append(result, entry)
		}
	}
	return result, total
}

func modelMatches(modelID string, model map[string]any, query string, args listModelsArgs) bool {
	if args.Status != "" {
		// models.dev omits the status field for normal active models;
		// a missing status means active.
		status := stringValue(model["status"])
		if status == "" {
			status = "active"
		}
		if status != args.Status {
			return false
		}
	}
	if args.Reasoning != nil {
		value, _ := boolValue(model["reasoning"])
		if value != *args.Reasoning {
			return false
		}
	}
	if args.ToolCall != nil {
		value, present := boolValue(model["tool_call"])
		if !present {
			value = true
		}
		if value != *args.ToolCall {
			return false
		}
	}
	if args.Input != "" {
		modalities := objectValue(model["modalities"])
		if modalities == nil || !arrayContains(modalities["input"], args.Input) {
			return false
		}
	}
	if query != "" {
		haystack := strings.ToLower(strings.Join([]string{
			modelID, stringValue(model["name"]), stringValue(model["family"]), stringValue(model["description"]),
		}, " "))
		if !strings.Contains(haystack, query) {
			return false
		}
	}
	return true
}

func (c *catalogState) get(providerID, modelID string) (map[string]any, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	provider := objectValue(c.effective[providerID])
	if provider == nil {
		return nil, false
	}
	model := objectValue(objectValue(provider["models"])[modelID])
	if model == nil {
		return nil, false
	}
	return map[string]any{
		"provider":   providerMetadata(provider),
		"model":      redactMetadata(model).(map[string]any),
		"reference":  providerID + "/" + modelID,
		"configured": providerConfigured(providerID, provider),
		"updatedAt":  c.updatedAt.Format(time.RFC3339),
	}, true
}

func (c *catalogState) resolve(reference, providerID string) map[string]any {
	reference = strings.TrimSpace(reference)
	providerID = strings.TrimSpace(providerID)
	if reference == "" {
		return map[string]any{"found": false, "error": "reference is required"}
	}

	c.mu.RLock()
	if providerID == "" {
		if slash := strings.IndexByte(reference, '/'); slash > 0 {
			candidate := reference[:slash]
			if _, exists := c.effective[candidate]; exists {
				providerID = candidate
				reference = reference[slash+1:]
			}
		}
	}
	if providerID != "" {
		provider := objectValue(c.effective[providerID])
		model := objectValue(objectValue(provider["models"])[reference])
		c.mu.RUnlock()
		if model == nil {
			return c.notFound(reference, providerID)
		}
		// get() re-checks under its own lock: a refresh may have replaced
		// the catalog between RUnlock and here, and a removed model must
		// degrade to not-found instead of panicking on a nil result.
		result, found := c.get(providerID, reference)
		if !found {
			return c.notFound(reference, providerID)
		}
		result["found"] = true
		return result
	}

	type match struct{ provider, model string }
	var exact []match
	for candidateProvider, rawProvider := range c.effective {
		models := objectValue(objectValue(rawProvider)["models"])
		if objectValue(models[reference]) != nil {
			exact = append(exact, match{candidateProvider, reference})
		}
	}
	c.mu.RUnlock()
	if len(exact) == 1 {
		result, found := c.get(exact[0].provider, exact[0].model)
		if !found {
			return c.notFound(reference, "")
		}
		result["found"] = true
		return result
	}
	if len(exact) > 1 {
		matches := make([]string, 0, len(exact))
		for _, item := range exact {
			matches = append(matches, item.provider+"/"+item.model)
		}
		sort.Strings(matches)
		return map[string]any{
			"found": false, "error": "model id is ambiguous; use provider/model", "matches": matches,
		}
	}
	return c.notFound(reference, "")
}

func (c *catalogState) notFound(query, providerID string) map[string]any {
	items, _ := c.models(listModelsArgs{Provider: providerID, Query: query, Limit: 10})
	suggestions := make([]string, 0, len(items))
	for _, item := range items {
		suggestions = append(suggestions, stringValue(item["reference"]))
	}
	return map[string]any{"found": false, "error": "model not found", "suggestions": suggestions}
}

func (c *catalogState) report() map[string]any {
	c.mu.RLock()
	defer c.mu.RUnlock()
	providers, models := catalogCounts(c.effective)
	statuses := make([]sourceStatus, 0, len(c.statuses)+2)
	statuses = append(statuses, c.baselineStatus)
	for _, status := range c.statuses {
		statuses = append(statuses, status)
	}
	if c.overrideStatus != nil {
		statuses = append(statuses, *c.overrideStatus)
	}
	sort.Slice(statuses, func(i, j int) bool {
		if statuses[i].Priority != statuses[j].Priority {
			return statuses[i].Priority < statuses[j].Priority
		}
		return statuses[i].ID < statuses[j].ID
	})
	return map[string]any{
		"providers": providers, "models": models, "sourceCount": len(c.sources),
		"updatedAt": c.updatedAt.Format(time.RFC3339), "sources": statuses,
	}
}

func catalogCounts(catalog map[string]any) (int, int) {
	providers := 0
	models := 0
	for _, rawProvider := range catalog {
		provider := objectValue(rawProvider)
		if provider == nil {
			continue
		}
		providers++
		models += len(objectValue(provider["models"]))
	}
	return providers, models
}
