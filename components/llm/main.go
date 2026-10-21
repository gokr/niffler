// llm component — streaming OpenAI-compatible chat completions adapter.
//
// The full adapter: streaming with reasoning tokens (deepseek-reasoner's
// reasoning_content), streamed tool-call aggregation, per-call model
// override and a provider nickname table. The tiny `llm-openai` component
// stays as the minimal example implementation.
//
// Provider resolution: an explicit `provider` arg picks a named provider
// from NIF_LLM_PROVIDERS; the default resolves through the provider
// component's active provider (live-updates on provider_switch), falling
// back to NIF_OPENAI_* when the component is absent or has no active
// provider.
//
// Protocol (evolved from llm-openai, same result shape):
//   chat {messages, tools?, model?, provider?, sessionId?, stream?,
//         cancelId?, emitTokens?, purpose?}
//   → result {content, reasoning?, tool_calls?, model, context, usage?}
//   stream: true additionally emits ev.llm.token {sessionId, content,
//   reasoning} frames unless emitTokens is false.
//   Cancellation: publish an envelope to llm.cancel.<cancelId> (or the
//   session id when cancelId is omitted) to abort the in-flight call.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	openai "github.com/sashabaranov/go-openai"
	sdk "niffler.dev/sdk"
)

// ---------------------------------------------------------------------------
// Providers
//
// The default provider comes from NIF_OPENAI_* (base url, key, model).
// Named providers come from NIF_LLM_PROVIDERS: a JSON object mapping a
// nickname to {baseUrl, apiKey, model, context, catalog}, e.g. OpenRouter, a local
// vLLM or a second DeepSeek workspace. A chat call picks one with the
// `provider` arg; `model` still overrides the provider's default.

const (
	protocolOpenAI    = "openai-chat"
	protocolCodex     = "openai-codex"
	protocolAnthropic = "anthropic"
	authAPIKey        = "api_key"
	authOAuth         = "oauth"
)

type provider struct {
	BaseURL string `json:"baseUrl"`
	APIKey  string `json:"apiKey"`
	Model   string `json:"model"`
	// EmbedModel is the provider's embedding model (empty = the provider
	// serves no embeddings). EmbedBaseURL overrides BaseURL for embeddings
	// only; both mirror the provider component's records.
	EmbedModel   string `json:"embedModel"`
	EmbedBaseURL string `json:"embedBaseUrl"`
	Context      int    `json:"context"`
	Catalog      string `json:"catalog"`
	Protocol     string `json:"protocol"`
	AuthType     string `json:"authType"`
	AccountID    string `json:"accountId"`
	// StripPrefix models a gateway that routes on the canonical id and
	// rejects vendor-prefixed ids ("alibaba/glm-5.2"); send "glm-5.2".
	StripPrefix bool `json:"stripPrefix"`
}

const defaultProvider = "default"

const defaultContext = 128000 // conservative fallback for unknown models

// defaultOutput is the max output tokens requested when the catalog does not
// say. Generous on purpose: without an explicit max the provider applies its
// own server-side cap (often 4K–16K), which truncates long answers mid-stream
// and makes the TUI appear to "stop" until nudged with continue.
const defaultOutput = 32768

// knownContext: model id (lowercase) -> context window (tokens).
// syn:large:text: the models.dev catalog has no Synthetic entry, so the
// catalog lookup falls through — without this the 128k conservative
// fallback applies to a 512k model (bench: full27-syn-large-* ran with
// context 128000; the model serves 524288 per Synthetic's catalog).
var knownContext = map[string]int{
	"deepseek-chat":         1000000,
	"deepseek-reasoner":     1000000,
	"syn:large:text":        524288,
	"zai-org/glm-5.3-flash": 524288,
}

type resolvedConfig struct {
	Provider       provider
	ProviderName   string
	ProviderSource string
	Model          string
	Catalog        string
	Context        int
	ContextSource  string
	Output         int
	OutputSource   string
	// Vision: may this model be SENT image parts? Resolved from the catalog's
	// modalities.input; unknown means true (see resolveModelTraits).
	Vision       bool
	VisionSource string
	StripPrefix  bool
}

// resolveContextWindow returns the effective context size and its provenance:
// explicit provider override, environment override, models catalog, local
// built-in knowledge, then the conservative fallback.
func resolveContextWindow(ctx context.Context, c *sdk.Component, p provider, providerName, model string) (int, string, string) {
	catalogProvider := p.Catalog
	if catalogProvider == "" {
		catalogProvider = inferCatalogProvider(providerName, p.BaseURL, model)
	}
	if p.Context > 0 {
		return p.Context, catalogProvider, "provider"
	}
	if v := os.Getenv("NIF_OPENAI_CONTEXT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n, catalogProvider, "environment"
		}
	}
	if c != nil && catalogProvider != "" {
		lookupCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
		defer cancel()
		raw, err := c.RequestContext(lookupCtx, "models", "models_get", map[string]any{
			"provider": catalogProvider, "model": model,
		})
		if err == nil {
			var descriptor struct {
				Model struct {
					Limit struct {
						Context int `json:"context"`
					} `json:"limit"`
				} `json:"model"`
			}
			if json.Unmarshal(raw, &descriptor) == nil && descriptor.Model.Limit.Context > 0 {
				return descriptor.Model.Limit.Context, catalogProvider, "catalog"
			}
		}
	}
	if size, ok := knownContext[strings.ToLower(model)]; ok {
		return size, catalogProvider, "builtin"
	}
	return defaultContext, catalogProvider, "fallback"
}

// modelTraits is what one catalog lookup answers about a model: its output cap
// and whether it accepts image parts. One request, because resolveRuntimeConfig
// runs on every turn and each lookup is a bus round trip.
type modelTraits struct {
	Output       int
	OutputSource string
	Vision       bool
	VisionSource string
}

// resolveModelTraits resolves the model's max output tokens and its vision
// capability. The catalog's limit.output is authoritative when present;
// otherwise a generous default so the provider's server-side cap (which would
// otherwise truncate answers mid-stream) is not hit.
//
// Vision comes from the catalog's modalities.input. Absence of evidence means
// TRUE, never false: an unknown model (self-hosted, a gateway, a model newer
// than the catalog) must not have its images silently discarded, and an
// unavailable models component is not an answer at all. Only a POSITIVE
// catalog answer that omits "image" turns it off — the same "fire only on a
// positive answer" rule crossCatalogMismatch follows.
func resolveModelTraits(ctx context.Context, c *sdk.Component, catalogProvider, model string) modelTraits {
	result := modelTraits{Output: defaultOutput, OutputSource: "fallback", Vision: true}
	if c == nil || catalogProvider == "" {
		return result
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	raw, err := c.RequestContext(lookupCtx, "models", "models_get", map[string]any{
		"provider": catalogProvider, "model": model,
	})
	if err != nil {
		return result
	}
	var descriptor struct {
		Model struct {
			Limit struct {
				Output int `json:"output"`
			} `json:"limit"`
			Modalities struct {
				Input []string `json:"input"`
			} `json:"modalities"`
		} `json:"model"`
	}
	if json.Unmarshal(raw, &descriptor) != nil {
		return result
	}
	if descriptor.Model.Limit.Output > 0 {
		result.Output = descriptor.Model.Limit.Output
		result.OutputSource = "catalog"
	}
	// An empty list is not a claim either: models.dev entries without a
	// modalities block must not read as "no images".
	if len(descriptor.Model.Modalities.Input) > 0 {
		result.VisionSource = "catalog"
		result.Vision = false
		for _, input := range descriptor.Model.Modalities.Input {
			if input == "image" {
				result.Vision = true
				break
			}
		}
	}
	return result
}

func resolveRuntimeConfig(ctx context.Context, c *sdk.Component, providerOverride, modelOverride string) (resolvedConfig, error) {
	p, providerName, providerSource, err := resolveProvider(c, providerOverride)
	if err != nil {
		// Resolution failures used to be silent: the caller returned the error
		// to the session and nothing reached var/logs, which made a reported
		// mismatch ("unknown provider … (have: default)") undiagnosable after
		// the fact. Name the request and the path that failed.
		log.Printf("ERROR chat status=resolve-failed requestedProvider=%q resolved=%q error=%v",
			providerOverride, providerName, err)
		return resolvedConfig{}, err
	}
	model := strings.TrimSpace(modelOverride)
	if model == "" {
		model = p.Model
	}
	if model == "" {
		model = "deepseek-chat"
	}
	if modelOverride != "" {
		catalogProvider := p.Catalog
		if catalogProvider == "" {
			catalogProvider = inferCatalogProvider(providerName, p.BaseURL, model)
		}
		if msg, mismatch := crossCatalogMismatch(ctx, c, model, catalogProvider, providerName, p.Model); mismatch {
			log.Printf("ERROR chat status=model-provider-mismatch provider=%s model=%s error=%s",
				providerName, model, msg)
			return resolvedConfig{}, fmt.Errorf("%s", msg)
		}
	}
	contextSize, catalogProvider, contextSource := resolveContextWindow(ctx, c, p, providerName, model)
	traits := resolveModelTraits(ctx, c, catalogProvider, model)
	return resolvedConfig{
		Provider: p, ProviderName: providerName, ProviderSource: providerSource,
		Model: model, Catalog: catalogProvider, Context: contextSize,
		ContextSource: contextSource, Output: traits.Output,
		OutputSource: traits.OutputSource,
		Vision:       traits.Vision, VisionSource: traits.VisionSource,
		StripPrefix: p.StripPrefix,
	}, nil
}

func inferCatalogProvider(providerName, baseURL, model string) string {
	if parsed, err := url.Parse(baseURL); err == nil {
		host := strings.ToLower(parsed.Hostname())
		switch {
		case host == "api.deepseek.com" || strings.HasSuffix(host, ".deepseek.com"):
			return "deepseek"
		case host == "openrouter.ai" || strings.HasSuffix(host, ".openrouter.ai"):
			return "openrouter"
		case host == "api.openai.com" || strings.HasSuffix(host, ".openai.com"):
			return "openai"
		}
	}
	if strings.HasPrefix(strings.ToLower(model), "deepseek-") {
		return "deepseek"
	}
	if providerName != defaultProvider {
		return providerName
	}
	return ""
}

// crossCatalogMismatch refuses a model the catalog places under a different
// provider than the one this call resolved to. That pairing is what a UI can
// create by pinning a model without its provider: the model id then rides to
// whatever provider the environment defaults to, and the provider answers with
// a raw 400 naming its own models ("The supported API model names are …").
//
// It fires only on a positive answer — the catalog places that exact model id
// somewhere and no owner is the resolved provider (by catalog id or by provider
// nickname). An unknown model (self-hosted, or newer than the catalog), an
// unavailable models component and the provider's own configured model all pass
// through untouched.
func crossCatalogMismatch(ctx context.Context, c *sdk.Component, model, catalogProvider, providerName, providerModel string) (string, bool) {
	if c == nil || model == "" || catalogProvider == "" {
		return "", false
	}
	// The provider's own configured model needs no catalog answer: refusing it
	// would refuse the pin-less conversation shape, so skip the lookup too.
	if sameModel(model, providerModel) {
		return "", false
	}
	return decideCatalogMismatch(catalogOwners(ctx, c, model), model, catalogProvider, providerName, providerModel)
}

// catalogOwners is every provider the catalog places this exact model id under.
//
// models_resolve answers it; models_list cannot. models_list filters on a
// substring over id/name/family/description, so a popular id buries the entry
// that matters under near-misses — 245 catalog entries mention
// "deepseek-flash", and deepseek/deepseek-flash sorted 56th — and a page that
// clips the real owner reads as "no provider serves this". That clipped answer
// refused a model the resolved provider does serve, on every turn of every
// pin-less conversation (core sends the resolved model explicitly, so the guard
// never saw it as implicit).
//
// A nil result means the catalog had no answer (unknown model, or no models
// component): absence of evidence, never a mismatch.
func catalogOwners(ctx context.Context, c *sdk.Component, model string) []string {
	rpcCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	raw, err := c.RequestContext(rpcCtx, "models", "models_resolve",
		map[string]any{"reference": model})
	if err != nil {
		return nil
	}
	var answer modelsResolveAnswer
	if err := json.Unmarshal(raw, &answer); err != nil {
		return nil
	}
	return ownersFromAnswer(answer)
}

// modelsResolveAnswer is the models_resolve result the guard reads: a unique
// owner arrives as the resolved descriptor, an ambiguous bare id as its matches.
type modelsResolveAnswer struct {
	Found    bool     `json:"found"`
	Matches  []string `json:"matches"`
	Provider struct {
		ID string `json:"id"`
	} `json:"provider"`
}

// ownersFromAnswer reads the provider ids out of either shape of a positive
// answer. Both spell providers as catalog ids; an ambiguous match is a
// provider/model reference, so only the first path segment is the provider (the
// model id itself may contain slashes).
func ownersFromAnswer(answer modelsResolveAnswer) []string {
	if answer.Found {
		if id := strings.TrimSpace(answer.Provider.ID); id != "" {
			return []string{id}
		}
		return nil
	}
	owners := make([]string, 0, len(answer.Matches))
	for _, match := range answer.Matches {
		if slash := strings.IndexByte(match, '/'); slash > 0 {
			owners = append(owners, match[:slash])
		}
	}
	return owners
}

func sameModel(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}

// decideCatalogMismatch is the pure decision behind crossCatalogMismatch:
// owners is the exact provider set for this model id (nil when the catalog has
// no answer at all), and providerModel is the resolved provider's own
// configured model.
func decideCatalogMismatch(owners []string, model, catalogProvider, providerName, providerModel string) (string, bool) {
	// Nothing to judge when the provider names no catalog (an unknown provider
	// must not block its own models) or when the catalog places the model
	// nowhere (unknown, or newer than the catalog).
	if strings.TrimSpace(model) == "" || strings.TrimSpace(catalogProvider) == "" || len(owners) == 0 {
		return "", false
	}
	// The provider's own configured model is right by construction — it is what
	// a pin-less conversation resolves to, and core then sends it as an explicit
	// model override.
	if sameModel(model, providerModel) {
		return "", false
	}
	named := make([]string, 0, len(owners))
	for _, owner := range owners {
		if sameModel(owner, catalogProvider) || sameModel(owner, providerName) {
			return "", false
		}
		named = append(named, owner)
	}
	sort.Strings(named)
	return fmt.Sprintf("model %q is served by provider %s, but this call resolved provider %q (catalog %q): pin the provider together with the model, or choose a model that provider serves",
		model, strings.Join(named, ", "), providerName, catalogProvider), true
}

func loadProviders() (map[string]provider, error) {
	base := os.Getenv("NIF_OPENAI_BASE_URL")
	if base == "" {
		base = "https://api.openai.com/v1"
	}
	model := os.Getenv("NIF_OPENAI_MODEL")
	if model == "" {
		model = "deepseek-chat"
	}
	ps := map[string]provider{
		defaultProvider: {
			BaseURL:      base,
			APIKey:       os.Getenv("NIF_OPENAI_API_KEY"),
			Model:        model,
			EmbedModel:   os.Getenv("NIF_OPENAI_EMBED_MODEL"),
			EmbedBaseURL: os.Getenv("NIF_OPENAI_EMBED_BASE_URL"),
			Catalog:      os.Getenv("NIF_OPENAI_PROVIDER"),
			Protocol:     protocolOpenAI,
			AuthType:     authAPIKey,
		},
	}
	if v := os.Getenv("NIF_LLM_PROVIDERS"); v != "" {
		var extra map[string]provider
		if err := json.Unmarshal([]byte(v), &extra); err != nil {
			return nil, fmt.Errorf("NIF_LLM_PROVIDERS: %w", err)
		}
		for k, p := range extra {
			ps[k] = p
		}
	}
	return ps, nil
}

func providerNames(ps map[string]provider) string {
	names := make([]string, 0, len(ps))
	for k := range ps {
		names = append(names, k)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// resolveProvider picks the connection for a chat call. An explicit
// `provider` arg first resolves a stored nickname, then NIF_LLM_PROVIDERS;
// the default resolves through the provider component's active provider when
// one is active, else the NIF_OPENAI_* environment default.
//
// A PINNED name (the explicit arg, which is what core sends for a
// conversation's provider pin) is only ever answered by that name: the store
// record first, then the environment table's entry of the SAME name. When
// neither can answer, the failure is reported as what it is — a registry
// failure or an unknown nickname — never as a silent fallback to some other
// provider, and never as the misleading `unknown provider … (have: default)`
// that a transient lookup failure used to produce.
func resolveProvider(c *sdk.Component, name string) (provider, string, string, error) {
	if name != "" {
		lookup := namedStoredProvider(c, name)
		if lookup.Found {
			return lookup.Provider, lookup.Nickname, lookup.Source, nil
		}
		// The environment table answers for the SAME name — the `default`
		// nickname (NIF_OPENAI_*) and a NIF_LLM_PROVIDERS entry — so using it is
		// not a reroute. Only a name the table does not have falls through, and
		// then the reason matters: an unreachable registry must not be reported
		// as a verdict on the name.
		p, nickname, envErr := envProvider(name)
		if envErr == nil {
			return p, nickname, "environment", nil
		}
		if lookup.Unreachable != nil {
			return provider{}, "", "", fmt.Errorf(
				"cannot resolve provider %q: the provider registry did not answer (%v) — retry the turn (or check that the provider component is running); this is not a verdict on the provider name",
				name, lookup.Unreachable)
		}
		return provider{}, "", "", fmt.Errorf("%w%s", envErr, storedProviderNote(c))
	}
	lookup := activeStoredProvider(c)
	if lookup.Found {
		return lookup.Provider, lookup.Nickname, lookup.Source, nil
	}
	// An unreachable registry and "no active provider" both fall back to the
	// environment here, because a harness without the provider component (a
	// --minimal boot) is a supported shape. A harness WITH one is not silently
	// rerouted, so say it once — a per-call WARN would fill the log of every
	// --minimal harness, where the component is simply not running.
	if lookup.Unreachable != nil {
		warnRegistryUnreachableOnce(lookup.Unreachable)
	}
	p, nickname, err := envProvider(defaultProvider)
	return p, nickname, "environment", err
}

// warnRegistryUnreachableOnce logs the unpinned fallback a single time: the
// condition is usually permanent (a --minimal boot has no provider component),
// and each chat call re-runs resolution.
var registryWarned atomic.Bool

func warnRegistryUnreachableOnce(reason error) {
	if !registryWarned.CompareAndSwap(false, true) {
		return
	}
	log.Printf("WARN provider registry unreachable (%v) — using the environment default %q for unpinned conversations",
		reason, defaultProvider)
}

// storedProviderNote names the providers this harness actually has, for the
// error a pinned-but-missing nickname produces. A conversation pins a STORED
// nickname; a catalog id ("synthetic") or a nickname from another root reads
// as unknown here, and the fix is choosing one of these — so say which.
func storedProviderNote(c *sdk.Component) string {
	names := storedProviderNames(c)
	if len(names) == 0 {
		return ""
	}
	return fmt.Sprintf("; this harness stores providers %s", strings.Join(names, ", "))
}

// storedProviderNames lists the configured provider nicknames (best effort:
// an unreachable registry yields nothing). Error-message material only.
func storedProviderNames(c *sdk.Component) []string {
	if c == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), providerLookupRetryTimeout)
	defer cancel()
	raw, err := c.RequestContext(ctx, "provider", "provider_list", map[string]any{})
	if err != nil {
		return nil
	}
	var listed struct {
		Providers []struct {
			Nickname string `json:"nickname"`
		} `json:"providers"`
	}
	if json.Unmarshal(raw, &listed) != nil {
		return nil
	}
	names := make([]string, 0, len(listed.Providers))
	for _, p := range listed.Providers {
		if p.Nickname != "" {
			names = append(names, p.Nickname)
		}
	}
	sort.Strings(names)
	return names
}

// envProvider looks up a named provider in the environment tables.
func envProvider(name string) (provider, string, error) {
	providers, err := loadProviders()
	if err != nil {
		return provider{}, "", err
	}
	p, ok := providers[name]
	if !ok {
		// Say WHICH table this is: the store is searched first, and reading
		// "(have: default)" as "your provider is gone" cost debugging time on
		// a stored provider whose registry lookup had failed. resolveProvider
		// appends the stored nicknames when it reaches here for a pinned name.
		return provider{}, "", fmt.Errorf("unknown provider %q (environment providers: %s)",
			name, providerNames(providers))
	}
	if p.Protocol == "" {
		p.Protocol = protocolOpenAI
	}
	if p.AuthType == "" {
		p.AuthType = authAPIKey
	}
	if p.APIKey == "" {
		return provider{}, "", fmt.Errorf("provider %q: no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)", name)
	}
	return p, name, nil
}

type registryResponse struct {
	Ok       bool   `json:"ok"`
	Source   string `json:"source"`
	Provider *struct {
		Nickname string `json:"nickname"`
		AuthType string `json:"authType"`
		Protocol string `json:"protocol"`
		APIKey   string `json:"apiKey"`
		OAuth    *struct {
			Access    string `json:"access"`
			AccountID string `json:"accountId"`
		} `json:"oauth"`
		BaseURL      string `json:"baseUrl"`
		Model        string `json:"model"`
		EmbedModel   string `json:"embedModel"`
		EmbedBaseURL string `json:"embedBaseUrl"`
		Catalog      string `json:"catalog"`
		Context      int    `json:"context"`
		StripPrefix  bool   `json:"stripPrefix"`
	} `json:"provider"`
}

// providerLookupTimeout bounds one provider registry request; a failure is
// retried once with providerLookupRetryTimeout. Resolution runs on every turn,
// so the first attempt stays short, and the second is patient enough for a
// store busy writing a transcript.
const (
	providerLookupTimeout      = 2 * time.Second
	providerLookupRetryTimeout = 5 * time.Second
)

// providerLookup is the outcome of asking the provider component for a record.
//
// The distinction between "the registry answered and this nickname is not
// usable" and "the registry never answered" is load-bearing, not cosmetic: only
// the first may fall back to the NIF_LLM_PROVIDERS nickname table. Collapsing
// both into one false flag reported a transient bus/store blip as
// `unknown provider … (have: default)` — a message that sends the reader
// hunting for a missing provider record — and, worse, let a pinned
// conversation continue against the harness-global provider (core/conversation
// .nim runTurn).
type providerLookup struct {
	Provider provider
	Nickname string
	Source   string
	Found    bool
	// Unreachable is set when the provider component could not answer at all:
	// a transport error, a timeout, or a handler failure. Nil means the answer
	// is definitive — either Found, or "this harness has no usable record for
	// that nickname".
	Unreachable error
}

func requestStoredProvider(c *sdk.Component, tool string, args map[string]any) providerLookup {
	if c == nil {
		return providerLookup{}
	}
	raw, err := providerRegistryRequest(c, tool, args, providerLookupTimeout)
	if err != nil {
		// One retry: the blip this replaces broke a whole turn of every
		// conversation pinned to that provider. The retry costs nothing on the
		// happy path — it runs only after a failure.
		raw, err = providerRegistryRequest(c, tool, args, providerLookupRetryTimeout)
	}
	lookup := classifyProviderReply(raw, err)
	// A record without its own nickname (a legacy doc) must still answer as the
	// provider that was asked for: core compares the resolved name against the
	// conversation's pin, and an empty answer would read as a reroute.
	if lookup.Found && strings.TrimSpace(lookup.Nickname) == "" {
		if asked, ok := args["nickname"].(string); ok {
			lookup.Nickname = asked
		}
	}
	return lookup
}

func providerRegistryRequest(c *sdk.Component, tool string, args map[string]any, timeout time.Duration) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return c.RequestContext(ctx, "provider", tool, args)
}

// classifyProviderReply turns one registry answer into a lookup outcome. The
// provider component reports "no such nickname" (and "no active provider") as
// a RESULT with ok:false, its not-found convention, so an ok:false payload is
// a definitive verdict while a transport error is not. Pure, so the split is
// testable without a bus.
func classifyProviderReply(raw json.RawMessage, err error) providerLookup {
	if err != nil {
		return providerLookup{Unreachable: err}
	}
	var resp registryResponse
	if json.Unmarshal(raw, &resp) != nil || !resp.Ok || resp.Provider == nil {
		return providerLookup{}
	}
	credential := resp.Provider.APIKey
	accountID := ""
	if resp.Provider.OAuth != nil {
		credential = resp.Provider.OAuth.Access
		accountID = resp.Provider.OAuth.AccountID
	}
	if credential == "" {
		return providerLookup{}
	}
	source := resp.Source
	if source == "" {
		source = "store"
		if resp.Provider.Nickname == defaultProvider {
			source = "environment"
		}
	}
	protocol := resp.Provider.Protocol
	if protocol == "" {
		protocol = protocolOpenAI
	}
	authType := resp.Provider.AuthType
	if authType == "" {
		authType = authAPIKey
	}
	return providerLookup{
		Found: true, Nickname: resp.Provider.Nickname, Source: source,
		Provider: provider{
			BaseURL:      resp.Provider.BaseURL,
			APIKey:       credential,
			Model:        resp.Provider.Model,
			EmbedModel:   resp.Provider.EmbedModel,
			EmbedBaseURL: resp.Provider.EmbedBaseURL,
			Catalog:      resp.Provider.Catalog,
			Context:      resp.Provider.Context,
			Protocol:     protocol,
			AuthType:     authType,
			AccountID:    accountID,
			StripPrefix:  resp.Provider.StripPrefix,
		},
	}
}

// activeStoredProvider asks the provider component for its active provider.
// Found=false means the registry answered and there is no usable active
// provider; Unreachable means it did not answer at all. Because the answer is
// re-read per chat call, provider_switch live-updates the backend with no
// further coordination.
func activeStoredProvider(c *sdk.Component) providerLookup {
	return requestStoredProvider(c, "provider_active", map[string]any{})
}

func namedStoredProvider(c *sdk.Component, name string) providerLookup {
	return requestStoredProvider(c, "provider_get", map[string]any{"nickname": name})
}

// ---------------------------------------------------------------------------
// chat tool

type chatMessage openai.ChatCompletionMessage

func (m *chatMessage) UnmarshalJSON(data []byte) error {
	var decoded openai.ChatCompletionMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	if decoded.ReasoningContent == "" {
		var internal struct {
			Reasoning string `json:"reasoning"`
		}
		if err := json.Unmarshal(data, &internal); err != nil {
			return err
		}
		decoded.ReasoningContent = internal.Reasoning
	}
	*m = chatMessage(decoded)
	return nil
}

func openAIMessages(messages []chatMessage) []openai.ChatCompletionMessage {
	result := make([]openai.ChatCompletionMessage, len(messages))
	for i := range messages {
		result[i] = openai.ChatCompletionMessage(messages[i])
		ensureContentKey(&result[i], messages[i])
	}
	return result
}

// ensureContentKey keeps empty messages valid at the provider boundary without
// changing stored history. go-openai omits both an empty Content string and
// an empty ChatMessagePart.Text: an empty text part becomes {"type":"text"},
// which strict providers reject (conv-d8e18e9fa617). Use an explicit, non-empty
// marker instead. Assistant tool-call turns may still omit content.
func ensureContentKey(out *openai.ChatCompletionMessage, in chatMessage) {
	if out.Content != "" || len(out.MultiContent) > 0 {
		return
	}
	if out.Role == openai.ChatMessageRoleAssistant && len(out.ToolCalls) > 0 {
		// An assistant tool-call turn: omitting content (null) is the
		// canonical spelling and what both providers accept.
		return
	}
	if len(in.MultiContent) > 0 {
		return
	}
	out.Content = "[empty message]"
}

type chatArgs struct {
	Messages  []chatMessage `json:"messages"`
	Tools     []openai.Tool `json:"tools"`
	Model     string        `json:"model"`
	Provider  string        `json:"provider"`
	SessionID string        `json:"sessionId"`
	// CancelID is the cancellation correlation id. It is deliberately separate
	// from SessionID so an auxiliary compaction request cannot be cancelled by
	// the user's turn stop (or cancel that turn itself).
	CancelID string `json:"cancelId"`
	Stream   bool   `json:"stream"`
	// EmitTokens controls publication of ev.llm.token frames. Auxiliary calls
	// stream internally for cancellation but set this false so their partial
	// output never appears as assistant text in the live conversation.
	EmitTokens *bool `json:"emitTokens"`
	// Purpose is telemetry/accounting metadata only; it never changes provider
	// behavior or tool exposure.
	Purpose string `json:"purpose"`
	// ReasoningEffort forwards a per-turn thinking-effort selection
	// ("low"|"medium"|"high"|"max"); empty = provider default. Only sent to the
	// API when set — providers that do not support reasoning_effort
	// (deepseek-reasoner, most open gateways) never see the field.
	ReasoningEffort string `json:"reasoning_effort"`
	// MaxTokens is a per-call output cap (e.g. the expert judge's tiny
	// JSON verdicts). It only ever lowers the provider/catalog default,
	// never raises it; 0 = no cap.
	MaxTokens int `json:"maxTokens"`
}

func (a chatArgs) emitTokens() bool {
	return a.EmitTokens == nil || *a.EmitTokens
}

// logTiming emits one per-call line on the debug timing lane. The lane is on
// when NIF_LOG_LEVEL=debug (what `niffler --log=debug` sets for every
// component), and the line goes through the SDK's log so it lands in
// var/logs/llm.jsonl with rotation like any other debug log — no separate
// mechanism, no output the logfile component cannot see. Budget and method:
// bench/README.md, "Model-call overhead".
func logTiming(c *sdk.Component, format string, args ...any) {
	if os.Getenv("NIF_LOG_LEVEL") != "debug" {
		return
	}
	_ = c.Log("debug", fmt.Sprintf(format, args...), nil)
}

// ---------------------------------------------------------------------------
// Embeddings
//
// One HTTP shape covers the providers this component already speaks through
// OpenAI-compatible chat: POST {base}/embeddings with {model, input}. It is
// deliberately a raw vector producer — ranking a candidate set the caller
// already holds, or persisting the vectors itself, is the caller's business
// (a store-backed semantic recall is a separate work item). The model comes
// from the provider's embedModel, never from a guess: an endpoint handed a
// chat model answers 400, so a missing embedModel is reported with the fix.

type embedArgs struct {
	Input      []string `json:"input"`
	Model      string   `json:"model"`
	Provider   string   `json:"provider"`
	Dimensions int      `json:"dimensions"`
}

// maxEmbedInputs bounds one call: providers enforce their own batch limits,
// but a runaway array must fail here with a readable message instead of as a
// transport megabyte-limit timeout.
const maxEmbedInputs = 256

// embedEndpoint is the resolved destination of one embedding call.
type embedEndpoint struct {
	Model     string
	BaseURL   string
	APIKey    string
	Protocol  string
	Provider  string
	AccountID string
}

// resolveEmbedEndpoint applies the precedence embedModel → call override and
// EmbedBaseURL → BaseURL, and refuses (naming the fix) when the provider has
// no embedding model configured.
func resolveEmbedEndpoint(c *sdk.Component, providerName, modelOverride string) (embedEndpoint, error) {
	p, name, _, err := resolveProvider(c, providerName)
	if err != nil {
		return embedEndpoint{}, err
	}
	model := strings.TrimSpace(modelOverride)
	if model == "" {
		model = strings.TrimSpace(p.EmbedModel)
	}
	if model == "" {
		return embedEndpoint{}, fmt.Errorf(
			"provider %q has no embedding model — set it with provider_add {embedModel: \"...\"} (or NIF_OPENAI_EMBED_MODEL for the environment default)", name)
	}
	baseURL := strings.TrimSpace(p.EmbedBaseURL)
	if baseURL == "" {
		baseURL = p.BaseURL
	}
	if baseURL == "" {
		return embedEndpoint{}, fmt.Errorf("provider %q has no base URL for embeddings", name)
	}
	return embedEndpoint{
		Model: model, BaseURL: baseURL, APIKey: p.APIKey,
		Protocol: p.Protocol, Provider: name, AccountID: p.AccountID,
	}, nil
}

func embedHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	var args embedArgs
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad embed args: %w", err)
	}
	if len(args.Input) == 0 {
		return nil, fmt.Errorf("input required: a non-empty array of strings")
	}
	if len(args.Input) > maxEmbedInputs {
		return nil, fmt.Errorf("input has %d entries; at most %d per call", len(args.Input), maxEmbedInputs)
	}
	for index, text := range args.Input {
		if strings.TrimSpace(text) == "" {
			return nil, fmt.Errorf("input[%d] is empty; omit it instead of embedding a blank string", index)
		}
	}
	if args.Dimensions < 0 {
		return nil, fmt.Errorf("dimensions must be positive (0 = the model's default)")
	}
	endpoint, err := resolveEmbedEndpoint(c, args.Provider, args.Model)
	if err != nil {
		return nil, err
	}
	if endpoint.Protocol != "" && endpoint.Protocol != protocolOpenAI {
		// Ollama's native /api/embed and the Anthropic/Codex lanes are
		// different request shapes; refusing beats sending a chat-shaped
		// request the endpoint cannot answer. Ollama is reachable through
		// its OpenAI shim (baseUrl http://localhost:11434/v1).
		return nil, fmt.Errorf("provider %q speaks %s, which has no OpenAI-compatible /embeddings route; point embedBaseUrl at an OpenAI-compatible endpoint (Ollama: http://localhost:11434/v1)",
			endpoint.Provider, endpoint.Protocol)
	}
	ctx, cancel := context.WithTimeout(context.Background(), embedTimeoutMs())
	defer cancel()
	cfg := openai.DefaultConfig(endpoint.APIKey)
	cfg.BaseURL = endpoint.BaseURL
	cfg.HTTPClient = &retryAfterHTTPClient{base: cfg.HTTPClient}
	client := openai.NewClientWithConfig(cfg)
	response, err := client.CreateEmbeddings(ctx, openai.EmbeddingRequestStrings{
		Input: args.Input, Model: openai.EmbeddingModel(endpoint.Model), Dimensions: args.Dimensions,
	})
	if err != nil {
		// No context-window classification here: /embeddings has no chat
		// window to blame, and a wrong model id must surface verbatim.
		return nil, err
	}
	// The response order is not contractual; index each vector so a caller
	// can align vectors with inputs without assuming order.
	vectors := make([][]float32, len(response.Data))
	for _, item := range response.Data {
		if item.Index < 0 || item.Index >= len(vectors) {
			return nil, fmt.Errorf("provider %q returned embedding index %d for %d inputs",
				endpoint.Provider, item.Index, len(vectors))
		}
		vectors[item.Index] = item.Embedding
	}
	for index, vector := range vectors {
		if len(vector) == 0 {
			return nil, fmt.Errorf("provider %q returned no vector for input[%d]", endpoint.Provider, index)
		}
	}
	result := map[string]any{
		"ok": true, "provider": endpoint.Provider, "model": endpoint.Model,
		"dimensions": len(vectors[0]), "embeddings": vectors,
	}
	// Missing fields are omitted, never invented as zero.
	if response.Usage.TotalTokens > 0 || response.Usage.PromptTokens > 0 {
		result["usage"] = map[string]any{
			"prompt_tokens": response.Usage.PromptTokens,
			"total_tokens":  response.Usage.TotalTokens,
		}
	}
	return result, nil
}

// embedTimeoutMs mirrors chatTimeoutMs: embeddings are short, but a batch of
// long inputs against a cold local model is not instant.
func embedTimeoutMs() time.Duration {
	if v := os.Getenv("NIF_LLM_EMBED_TIMEOUT_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Millisecond
		}
	}
	return 120 * time.Second
}

func chatHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	// The handler's total, across every return path: `pre` (entry → provider
	// resolved), `setup` (request → response headers), `dur` (the stream) and
	// `post` (result build) are its parts, so a gap here is unaccounted work.
	entryAt := time.Now()
	defer func() {
		logTiming(c, "chat timing total=%s",
			time.Since(entryAt).Truncate(time.Millisecond))
	}()
	var args chatArgs
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad chat args: %w", err)
	}
	if len(args.Messages) == 0 {
		return nil, fmt.Errorf("messages required")
	}
	// Core replays stored history verbatim; a session poisoned by an
	// earlier truncated tool-call stream would make strict backends 400 the
	// whole request ("Assistant tool call function.arguments must be valid
	// JSON"). Repair before sending — this is what unsticks such sessions.
	sanitizeMessages(args.Messages)

	// The cancellation side-channel is subscribed before provider/model/context
	// resolution: a cancel published during that window must still abort the
	// stream (NATS events are not durable). cancelId keeps auxiliary calls
	// independent from the live conversation turn.
	streamCtx, streamCancel := context.WithCancel(context.Background())
	defer streamCancel()
	var unsub func()
	cancelID := args.CancelID
	if cancelID == "" {
		cancelID = args.SessionID
	}
	if args.Stream && cancelID != "" {
		var err error
		unsub, err = c.Subscribe("llm.cancel."+cancelID, func(subject string, payload json.RawMessage) {
			streamCancel()
		})
		if err != nil {
			return nil, err
		}
		defer unsub()
	}

	resolved, err := resolveRuntimeConfig(streamCtx, c, args.Provider, args.Model)
	// `pre`: unmarshal, sanitizeMessages, the per-call cancel subscription and
	// resolveRuntimeConfig (which may cross the bus for credentials).
	logTiming(c, "chat timing pre=%s", time.Since(entryAt).Truncate(time.Millisecond))
	if err != nil {
		return nil, err
	}
	// Gateways that route on the canonical id (devpass, LLMgateway) reject
	// vendor-prefixed ids like "alibaba/glm-5.2"; the provider's
	// stripPrefix option sends the bare model id instead.
	model := resolved.Model
	if resolved.StripPrefix {
		model = stripModelPrefix(model)
	}
	// Per-call output cap: only ever lowers the resolved default.
	output := resolved.Output
	if args.MaxTokens > 0 && (output <= 0 || args.MaxTokens < output) {
		output = args.MaxTokens
	}
	// Providers count the requested output budget against the context window
	// when validating the request: prompt 664659 + max_tokens 384000 =
	// 1048659 > 1048576 refuses even though the prompt alone fits the harness
	// window. Clamp the cap to the headroom the estimated prompt leaves so a
	// full catalog output budget can never push a fitting prompt over the
	// provider limit.
	output = fitOutput(output, resolved.Context, args)
	// Best-effort live model discovery (option B): remember this provider's
	// endpoint and, when its id cache is stale, probe /models in the
	// background so the models component can publish served ids catalog-wide.
	maybeProbeLiveModels(streamCtx, c, resolved)
	return chatDispatchRetrying(streamCtx, c, resolved, model, args, output)
}

// chatDispatchRetrying runs the protocol dispatch and, when the provider
// refuses the requested reasoning_effort VALUE, drops that field and tries
// once more.
//
// A model's declared effort ladder cannot be trusted as a constraint:
// measured against Synthetic's own /models metadata, one alias declared
// none/low/medium/high yet rejected `max`, while three others accepted values
// they never declared. So the effort is treated as a preference — an answer
// without it beats a failed turn over a sampling knob. The log line keeps a
// silently degraded turn diagnosable.
func chatDispatchRetrying(streamCtx context.Context, c *sdk.Component, resolved resolvedConfig,
	model string, args chatArgs, output int) (any, error) {
	v, err := chatDispatch(streamCtx, c, resolved, model, args, output)
	if err == nil || args.ReasoningEffort == "" || !isEffortRejection(err) {
		return v, err
	}
	log.Printf("WARN chat status=effort-rejected provider=%s model=%s effort=%s: %v - retrying without reasoning_effort",
		resolved.ProviderName, model, args.ReasoningEffort, err)
	retryArgs := args
	retryArgs.ReasoningEffort = ""
	return chatDispatch(streamCtx, c, resolved, model, retryArgs, output)
}

// isEffortRejection reports whether an error is the provider refusing the
// reasoning_effort value, rather than anything else about the request.
func isEffortRejection(err error) bool {
	if err == nil {
		return false
	}
	var apiErr *openai.APIError
	if !errors.As(err, &apiErr) || apiErr.HTTPStatusCode != http.StatusBadRequest {
		return false
	}
	body := strings.ToLower(apiErr.Message)
	// Azure Content-filter wrappers carry their real reason in InnerError;
	// it is a struct with its own code, not a message body.
	// An unknown enum member comes back as a literal/enum validation error
	// naming the field; require both the field and a validation word so an
	// unrelated 400 that happens to mention effort is not swallowed.
	mentionsEffort := strings.Contains(body, "reasoning_effort") ||
		strings.Contains(body, "reasoning effort")
	mentionsRejection := strings.Contains(body, "literal_error") ||
		strings.Contains(body, "validation") ||
		strings.Contains(body, "not a valid") ||
		strings.Contains(body, "invalid") ||
		strings.Contains(body, "unsupported")
	return mentionsEffort && mentionsRejection
}

func chatDispatch(streamCtx context.Context, c *sdk.Component, resolved resolvedConfig,
	model string, args chatArgs, output int) (any, error) {
	switch resolved.Provider.Protocol {
	case protocolCodex:
		v, err := chatCodex(streamCtx, c, resolved.Provider, model, resolved.ProviderName, args,
			resolved.Context)
		return v, classifyProviderError(err, resolved.Context)
	case protocolAnthropic:
		v, err := chatAnthropic(streamCtx, c, resolved.Provider, model, resolved.ProviderName, args,
			resolved.Context, output)
		return v, classifyProviderError(err, resolved.Context)
	case "", protocolOpenAI:
		cfg := openai.DefaultConfig(resolved.Provider.APIKey)
		cfg.BaseURL = resolved.Provider.BaseURL
		cfg.HTTPClient = &retryAfterHTTPClient{base: cfg.HTTPClient}
		client := openai.NewClientWithConfig(cfg)
		if args.Stream {
			v, err := chatStream(streamCtx, c, client, model, resolved.ProviderName, args, resolved.Context, output)
			return v, classifyProviderError(err, resolved.Context)
		}
		v, err := chatOnce(client, model, resolved.ProviderName, args, resolved.Context, output)
		return v, classifyProviderError(err, resolved.Context)
	default:
		return nil, fmt.Errorf("provider %q: unsupported protocol %q", resolved.ProviderName, resolved.Provider.Protocol)
	}
}

// retryAfterHTTPClient preserves the HTTP Retry-After header through
// go-openai's APIError, whose public shape intentionally drops response
// headers. The core retry policy can then honor the provider's wait without
// making each adapter depend on the same client library details.
type retryAfterHTTPClient struct {
	base openai.HTTPDoer
}

func (c *retryAfterHTTPClient) Do(req *http.Request) (*http.Response, error) {
	resp, err := c.base.Do(req)
	if err != nil || resp == nil || resp.StatusCode < 400 {
		return resp, err
	}
	body, readErr := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if readErr != nil {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp, err
	}
	body = normalizeSSEErrorBody(body)
	raw := resp.Header.Get("Retry-After")
	if raw != "" {
		if ms := retryAfterMillis(raw); ms > 0 {
			body = annotateRetryAfter(body, ms)
		}
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return resp, err
}

// normalizeSSEErrorBody unwraps an SSE-framed error response. Some gateways
// answer a failed request with a stream frame (`data: {"error": …}`) even
// though nothing is streaming; the client library then fails to parse the
// body ("invalid character 'd' looking for beginning of value") and the
// provider's actual refusal never reaches the caller. Rewrite the body to
// the first data line's JSON payload when it parses, so the error carries
// the provider's own message and code.
func normalizeSSEErrorBody(body []byte) []byte {
	trimmed := bytes.TrimSpace(body)
	if !bytes.HasPrefix(trimmed, []byte("data:")) {
		return body
	}
	for _, line := range strings.Split(string(trimmed), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(line[len("data:"):])
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if json.Valid([]byte(payload)) {
			return []byte(payload)
		}
		return body // not JSON: leave the raw frame — still readable evidence
	}
	return body
}

// annotateRetryAfter appends the parsed wait hint to the error message the
// way the previous inline path did (core's retry policy reads it).
func annotateRetryAfter(body []byte, ms int) []byte {
	var envelope map[string]any
	if json.Unmarshal(body, &envelope) != nil {
		return body
	}
	if apiErr, ok := envelope["error"].(map[string]any); ok {
		if message, ok := apiErr["message"].(string); ok {
			apiErr["message"] = message + "; retry-after-ms: " + strconv.Itoa(ms)
		}
	} else if message, ok := envelope["message"].(string); ok {
		envelope["message"] = message + "; retry-after-ms: " + strconv.Itoa(ms)
	}
	if updated, marshalErr := json.Marshal(envelope); marshalErr == nil {
		return updated
	}
	return body
}

func retryAfterMillis(raw string) int {
	if seconds, parseErr := strconv.ParseFloat(strings.TrimSpace(raw), 64); parseErr == nil {
		if seconds <= 0 {
			return 1
		}
		return int(seconds * 1000)
	}
	when, parseErr := http.ParseTime(raw)
	if parseErr != nil {
		return 0
	}
	ms := time.Until(when).Milliseconds()
	if ms < 1 {
		return 1
	}
	return int(ms)
}

// classifyProviderError normalizes the provider failures the harness
// reasons about (docs/research/COMPACTION.md §6.5). A context overflow is a
// 400-family failure: retrying it as transient is wasted latency against a
// deterministic refusal, and failing it as permanent strands the turn even
// though pruning/trimming could make it fit. The stable "context-overflow"
// prefix plus the resolved window are the contract core matches on — the
// adapter knows the window (resolved.Context), so core never parses
// provider phrasing. Detection is structured where the protocol exposes
// status codes (openai.APIError) and falls back to the known refusal
// phrases for protocols that surface plain error text.
func classifyProviderError(err error, contextSize int) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	var apiErr *openai.APIError
	if errors.As(err, &apiErr) && apiErr.HTTPStatusCode == 400 {
		msg = apiErr.Message
	}
	lower := strings.ToLower(msg)
	for _, pattern := range []string{
		"context_length_exceeded", "context limit exceeded",
		"maximum context length",
		"prompt is too long", "input length exceeds",
		"too many input tokens",
	} {
		if strings.Contains(lower, pattern) {
			return fmt.Errorf("context-overflow: %s; window %d tokens", msg, contextSize)
		}
	}
	return err
}

// fitOutput clamps an output cap to the window headroom the estimated prompt
// leaves. OpenAI-compatible providers sum prompt + max_tokens against their
// context limit at admission, so a large catalog output budget (e.g. deepseek
// limit.output 384000) overflows even when the prompt alone fits the harness
// window. The estimate is the same chars/4 proxy core uses, over messages AND
// tool schemas (the frozen direct toolset is part of every prompt); the margin
// absorbs estimation error. A small floor keeps a short-but-possible answer
// instead of a 0-token cap (the provider's refusal error names the true limit
// if the estimate is ever badly wrong — core's recovery handles that path).
func fitOutput(output, contextSize int, args chatArgs) int {
	if output <= 0 || contextSize <= 0 {
		return output
	}
	// Count the prompt the way a provider bills it. Marshaling the request
	// would count an attached image's base64 data URL as ~1 token per 4
	// characters, so one screenshot would read as ~1M prompt tokens against
	// a 200k window and clamp every image turn's completion to the floor.
	// Text is still chars/4; each image part costs by pixel area.
	promptEst := 0
	for _, message := range args.Messages {
		promptEst += messagePromptTokens(message)
	}
	if serialized, err := json.Marshal(args.Tools); err == nil {
		promptEst += len(serialized) / 4
	}
	margin := contextSize/128 + 512 // ~0.8% + flat safety, scales with window
	budget := contextSize - promptEst - margin
	const floor = 512
	if budget < floor {
		budget = floor
	}
	if budget < output {
		return budget
	}
	return output
}

// messagePromptTokens estimates one message's prompt cost the way providers
// bill it: text and tool-call payloads at chars/4, image parts by pixel area
// (not by the base64 payload they are carried in). Falls back to the text
// length when a part carries no dimensions.
func messagePromptTokens(message chatMessage) int {
	total := 8 // role/formatting overhead, mirroring core's proxy
	if message.Content != "" {
		total += len(message.Content) / 4
	}
	for _, part := range message.MultiContent {
		switch part.Type {
		case openai.ChatMessagePartTypeText:
			total += len(part.Text) / 4
		case openai.ChatMessagePartTypeImageURL:
			total += imageTokens(part.ImageURL)
		}
	}
	for _, call := range message.ToolCalls {
		total += len(call.Function.Name)/4 + len(call.Function.Arguments)/4 + 4
	}
	return total
}

// imageTokens approximates one image's prompt cost from the dimensions
// carried in its data URL when known (the harness embeds none, so the
// caller's size cap bounds it): the same (w*h)/750 rule core uses, floored
// and capped so a small image still costs something and a huge one cannot
// dominate the estimate.
func imageTokens(url *openai.ChatMessageImageURL) int {
	if url == nil || url.Detail == "" && len(url.URL) == 0 {
		return 0
	}
	// The provider's own usage re-calibrates every response (core carries
	// the measured offset), so a flat conservative estimate is enough here.
	return 1100
}

// stripModelPrefix returns the model id after the last "/" — the canonical
// id for gateways that route on it (devpass: "alibaba/glm-5.2" → "glm-5.2").
func stripModelPrefix(model string) string {
	if i := strings.LastIndexByte(model, '/'); i >= 0 {
		return model[i+1:]
	}
	return model
}

// repairToolArgs returns raw when it is valid JSON, otherwise the best
// repair: complete any unterminated string/containers (truncated streams
// are the common failure), falling back to "{}" when the content cannot
// be salvaged. Repaired history keeps strict backends happy without ever
// executing anything — this runs on text, not on tool dispatch.
func repairToolArgs(raw string) string {
	if json.Valid([]byte(raw)) {
		return raw
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "{}"
	}
	var out strings.Builder
	out.WriteString(trimmed)
	var stack []byte // open containers, outermost last
	inString := false
	escaped := false
	for i := 0; i < len(trimmed); i++ {
		ch := trimmed[i]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			if ch == '\\' {
				escaped = true
				continue
			}
			if ch == '"' {
				inString = false
			}
			continue
		}
		switch ch {
		case '"':
			inString = true
		case '{', '[':
			stack = append(stack, ch)
		case '}':
			if len(stack) > 0 && stack[len(stack)-1] == '{' {
				stack = stack[:len(stack)-1]
			} else {
				return "{}" // mismatched closer: unrecoverable
			}
		case ']':
			if len(stack) > 0 && stack[len(stack)-1] == '[' {
				stack = stack[:len(stack)-1]
			} else {
				return "{}"
			}
		}
	}
	if inString {
		out.WriteByte('"')
	}
	for i := len(stack) - 1; i >= 0; i-- {
		if stack[i] == '{' {
			out.WriteByte('}')
		} else {
			out.WriteByte(']')
		}
	}
	repaired := out.String()
	if !json.Valid([]byte(repaired)) {
		return "{}"
	}
	return repaired
}

// sanitizeMessages repairs tool-call arguments in assistant messages so a
// strict backend never rejects replayed history, and strips prior turns'
// reasoning from the request. The strip is API semantics, not projection:
// providers discard replayed reasoning anyway (measured on the DeepSeek
// lane — identical prompt_tokens with a 62-token reasoning block replayed;
// Anthropic keeps only the live turn's blocks for tool loops and strips
// prior turns' server-side), so carrying it is dead wire bytes — core's
// §5.2 tombstone keeps the METER honest, this keeps the REQUEST honest.
// Only assistant messages are touched; everything else round-trips
// unchanged.
func sanitizeMessages(msgs []chatMessage) {
	last, lastUser := -1, -1
	for i := range msgs {
		switch msgs[i].Role {
		case openai.ChatMessageRoleAssistant:
			last = i
		case openai.ChatMessageRoleUser:
			lastUser = i
		}
	}
	for i := range msgs {
		if msgs[i].Role != openai.ChatMessageRoleAssistant {
			continue
		}
		// The live turn keeps its reasoning — the trailing assistant turn
		// (one a tool loop is continuing: nothing user-shaped after it).
		// Once a user message follows, that turn is complete and its
		// reasoning is dead weight.
		if i != last || i < lastUser {
			msgs[i].ReasoningContent = ""
		}
		for j := range msgs[i].ToolCalls {
			msgs[i].ToolCalls[j].Function.Arguments =
				repairToolArgs(msgs[i].ToolCalls[j].Function.Arguments)
		}
	}
}

// finish_reason values beyond stop/tool_calls that change what a client must
// do. DeepSeek documents all three: `length` means the reply was cut at the
// output cap, while `aborted` and `insufficient_system_resource` arrive as an
// HTTP 200 whose generation the provider interrupted — a caller that keys its
// retry policy on HTTP status alone records those as successful turns.
const (
	finishLength          = "length"
	finishAborted         = "aborted"
	finishInsufficientSys = "insufficient_system_resource"
)

// interruptedFinish reports whether a finish_reason means the provider ended
// the generation early rather than the model finishing its answer.
func interruptedFinish(reason string) bool {
	return reason == finishAborted || reason == finishInsufficientSys
}

// interruptErr hands an interrupted generation to the retry policy as a
// transient failure: core looks for the "stream error" marker, and it treats
// every "insufficient" as a permanent billing condition (core/retry.nim), so
// the raw reason is logged rather than embedded in the message.
func interruptErr(reason string) error {
	log.Printf("WARN chat interrupted finish_reason=%s", reason)
	return errors.New("stream error: the provider ended the generation early (provider resource pressure)")
}

// streamTruncErr classifies a stream that died mid-frame as transient, the
// same lane interruptErr uses: core/retry.nim matches the "stream error"
// marker and retries, which is the only sane response to a payload the network
// cut in half. The byte count rides along for the log and must never look like
// a status code ("400"/"401" would classify as permanent).
func streamTruncErr(size int) error {
	return fmt.Errorf("stream error: provider stream ended mid-frame (truncated payload, %d bytes)", size)
}

// canonicalFinish maps a provider's stop/terminal reason onto the
// finish_reason vocabulary the conversation loop understands (OpenAI's names),
// so truncation surfaces the same way on every lane. Unknown reasons pass
// through unchanged for logging.
func canonicalFinish(provider, reason string) string {
	switch provider {
	case "anthropic":
		switch reason {
		case "max_tokens":
			return finishLength
		case "end_turn", "stop_sequence":
			return "stop"
		case "tool_use":
			return "tool_calls"
		}
	case "openai-codex", "codex":
		if reason == "max_output_tokens" {
			return finishLength
		}
	}
	return reason
}

// lengthCap returns the output cap in the request field the provider actually
// honors. Niffler sends the OpenAI spelling (max_completion_tokens) by default,
// but DeepSeek's Chat Completions reference documents only max_tokens — a cap
// sent as max_completion_tokens is ignored there, so the server default applies
// (8K non-thinking, 64K thinking, 128K at reasoning_effort max) and a long
// agent turn ends truncated with finish_reason "length".
func lengthCap(providerName string, output int) (maxTokens, maxCompletionTokens int) {
	if output <= 0 {
		return 0, 0
	}
	if providerName == "deepseek" {
		return output, 0
	}
	return 0, output
}

func chatOnce(client *openai.Client, model, providerName string, args chatArgs, contextSize, outputSize int) (any, error) {
	startedAt := time.Now()
	maxTokens, maxCompletion := lengthCap(providerName, outputSize)
	resp, err := client.CreateChatCompletion(context.Background(), openai.ChatCompletionRequest{
		Model:               model,
		Messages:            openAIMessages(args.Messages),
		Tools:               args.Tools,
		ParallelToolCalls:   true,
		MaxTokens:           maxTokens,
		MaxCompletionTokens: maxCompletion,
		ReasoningEffort:     args.ReasoningEffort,
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Choices) == 0 {
		return nil, errors.New("no choices in llm response")
	}
	finish := string(resp.Choices[0].FinishReason)
	if interruptedFinish(finish) {
		return nil, interruptErr(finish)
	}
	msg := resp.Choices[0].Message
	usedModel := resp.Model
	if usedModel == "" {
		usedModel = model
	}
	effort := args.ReasoningEffort
	if effort == "" {
		effort = "default"
	}
	total := time.Since(startedAt)
	tps := 0.0
	if resp.Usage.CompletionTokens > 0 && total > 0 {
		tps = float64(resp.Usage.CompletionTokens) / total.Seconds()
	}
	log.Printf("INFO chat purpose=%s provider=%s model=%s effort=%s ttft=n/a dur=%s prompt=%d completion=%d tok/s=%.1f status=ok",
		args.Purpose, providerName, usedModel, effort, total.Truncate(time.Millisecond),
		resp.Usage.PromptTokens, resp.Usage.CompletionTokens, tps)
	return resultJSON(providerName, usedModel, contextSize, msg.Content,
		msg.ReasoningContent, msg.ToolCalls, resp.Usage, 0, true, finish)
}

// llmChunk mirrors go-openai's ChatCompletionStreamResponse, but keeps the
// gateway's `reasoning` delta field: zai/glm-family models stream thinking
// as "reasoning" while deepseek-reasoner uses "reasoning_content" — the
// library only knows the latter, which silently dropped all thinking for
// zai models. The stream loop below therefore reads RecvRaw and unmarshals
// into these local types instead of stream.Recv().
type llmChunk struct {
	Model   string        `json:"model"`
	Usage   *openai.Usage `json:"usage"`
	Choices []llmChoice   `json:"choices"`
}

type llmChoice struct {
	Delta        llmDelta            `json:"delta"`
	FinishReason openai.FinishReason `json:"finish_reason"`
}

type llmDelta struct {
	Content          string            `json:"content"`
	ReasoningContent string            `json:"reasoning_content"`
	Reasoning        string            `json:"reasoning"`
	ToolCalls        []openai.ToolCall `json:"tool_calls"`
}

// reasoning returns the delta's thinking text under whichever field name
// the provider uses.
func (d llmDelta) reasoning() string {
	if d.Reasoning != "" {
		return d.Reasoning
	}
	return d.ReasoningContent
}

func chatStream(ctx context.Context, c *sdk.Component, client *openai.Client, model, providerName string, args chatArgs, contextSize, outputSize int) (any, error) {
	// chatHandler owns the llm.cancel.<sessionId> side-channel subscription;
	// this derivation just bounds this call to that shared context.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	maxTokens, maxCompletion := lengthCap(providerName, outputSize)
	csAt := time.Now()
	stream, err := client.CreateChatCompletionStream(ctx, openai.ChatCompletionRequest{
		Model:               model,
		Messages:            openAIMessages(args.Messages),
		Tools:               args.Tools,
		ParallelToolCalls:   true,
		MaxTokens:           maxTokens,
		MaxCompletionTokens: maxCompletion,
		ReasoningEffort:     args.ReasoningEffort,
		StreamOptions:       &openai.StreamOptions{IncludeUsage: true},
	})
	if err != nil {
		return nil, err
	}
	// `setup`: client construction, request marshal, DNS/TCP/TLS and the
	// provider's own queue before it starts responding. Sits outside both `pre`
	// and `dur`, so without this line it reads as harness overhead — the easy
	// mistake this lane exists to prevent.
	logTiming(c, "chat timing setup=%s", time.Since(csAt).Truncate(time.Millisecond))
	defer stream.Close()

	// Per-request timing telemetry: TTFT (time to first visible delta) and
	// total wall time against the provider's reported usage — this is what
	// attributes a turn's wallclock to the provider (decode throughput,
	// thinking bursts) instead of the harness. One stderr line per request;
	// the supervisor captures it into var/logs/llm.log.
	startedAt := time.Now()
	var ttft time.Duration
	logStreamStats := func(usage openai.Usage, reasoningChars int, errdone bool) {
		total := time.Since(startedAt)
		tps := 0.0
		if usage.CompletionTokens > 0 && total > 0 {
			tps = float64(usage.CompletionTokens) / total.Seconds()
		}
		status := "ok"
		if errdone {
			status = "aborted"
		}
		effort := args.ReasoningEffort
		if effort == "" {
			effort = "default"
		}
		log.Printf("INFO chat purpose=%s provider=%s model=%s effort=%s ttft=%s dur=%s prompt=%d completion=%d tok/s=%.1f reasoning_chars=%d status=%s",
			args.Purpose, providerName, model, effort, ttft.Truncate(time.Millisecond), total.Truncate(time.Millisecond),
			usage.PromptTokens, usage.CompletionTokens, tps, reasoningChars, status)
	}

	var content, reasoning strings.Builder
	var calls []openai.ToolCall // aggregated by index, in stream order
	var usedModel string
	var finish string
	var usage openai.Usage
	var usageSeen bool

	for {
		// RecvRaw + local unmarshal: the library's delta type drops the
		// "reasoning" field zai/glm-family gateways stream (see llmChunk).
		raw, err := stream.RecvRaw()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			logStreamStats(usage, reasoning.Len(), true)
			return nil, err
		}
		if len(bytes.TrimSpace(raw)) == 0 || bytes.HasPrefix(bytes.TrimSpace(raw), []byte(":")) {
			// SSE keepalive/comment line, not a frame. Failing the turn on one
			// would be a harness-caused loss.
			continue
		}
		var resp llmChunk
		if err := json.Unmarshal(raw, &resp); err != nil {
			// A truncated frame is a transport event, not a protocol error:
			// providers and proxies cut long streams mid-payload. Observed on
			// the direct DeepSeek API, where two DeepSWE cells died at ~908s (a
			// ~15-minute stream cap) with go-openai handing us the partial
			// bytes. Classify it as a transient stream error so core's retry
			// policy (core/retry.nim matches "stream error") re-issues the
			// request, instead of throwing away a turn that had already produced
			// fifteen minutes of work.
			logStreamStats(usage, reasoning.Len(), true)
			log.Printf("WARN chat truncated stream chunk bytes=%d after=%s err=%v",
				len(raw), time.Since(startedAt).Truncate(time.Millisecond), err)
			return nil, streamTruncErr(len(raw))
		}
		if resp.Model != "" {
			usedModel = resp.Model
		}
		if resp.Usage != nil {
			usage = *resp.Usage
			usageSeen = true
		}
		if len(resp.Choices) == 0 {
			continue
		}
		if resp.Choices[0].FinishReason != "" {
			finish = string(resp.Choices[0].FinishReason)
		}
		delta := resp.Choices[0].Delta
		if delta.Content != "" {
			content.WriteString(delta.Content)
		}
		if delta.reasoning() != "" {
			reasoning.WriteString(delta.reasoning())
		}
		if ttft == 0 && (delta.Content != "" || delta.reasoning() != "" || len(delta.ToolCalls) > 0) {
			ttft = time.Since(startedAt)
		}
		// one token frame per chunk with anything to show
		if args.emitTokens() && args.SessionID != "" &&
			(delta.Content != "" || delta.reasoning() != "") {
			_ = c.Emit("ev.llm.token", map[string]any{
				"sessionId": args.SessionID,
				"content":   delta.Content,
				"reasoning": delta.reasoning(),
			})
		}
		// streamed tool calls: id/name arrive in the first delta of a call,
		// arguments arrive fragmented across frames — aggregate by index.
		for _, tc := range delta.ToolCalls {
			idx := len(calls)
			if tc.Index != nil && *tc.Index >= 0 {
				idx = *tc.Index
			}
			for len(calls) <= idx {
				calls = append(calls, openai.ToolCall{})
			}
			if tc.ID != "" {
				calls[idx].ID = tc.ID
			}
			if tc.Function.Name != "" {
				calls[idx].Function.Name = tc.Function.Name
			}
			calls[idx].Function.Arguments += tc.Function.Arguments
		}
	}
	if usedModel == "" {
		usedModel = model
	}
	if interruptedFinish(finish) {
		logStreamStats(usage, reasoning.Len(), true)
		return nil, interruptErr(finish)
	}
	logStreamStats(usage, reasoning.Len(), false)
	// `post`: result build and stream teardown, after the last streamed byte.
	buildAt := time.Now()
	res, resErr := resultJSON(providerName, usedModel, contextSize,
		content.String(), reasoning.String(), calls, usage, 0, usageSeen, finish)
	buildMs := time.Since(buildAt)
	closeAt := time.Now()
	stream.Close()
	logTiming(c, "chat timing post build=%s close=%s",
		buildMs.Truncate(time.Millisecond),
		time.Since(closeAt).Truncate(time.Millisecond))
	return res, resErr
}

// resultJSON builds the wire result — the same shape llm-openai returns,
// so core's conversation loop consumes it unchanged — plus `reasoning`.
func resultJSON(providerName, model string, ctx int, content, reasoning string,
	calls []openai.ToolCall, usage openai.Usage, cacheWriteTokens int, usageSeen bool, finish string) (any, error) {
	r := map[string]any{"content": content, "reasoning": reasoning}
	finish = canonicalFinish(providerName, finish)
	// finish_reason is additive: core ignores fields it does not know, and a
	// "length" turn is the one case worth logging loudly (the reply was cut at
	// the output cap). aborted/insufficient_system_resource never reach here —
	// they return as errors so the retry policy sees them
	// (docs/research/DEEPSEEK.md).
	if finish != "" {
		r["finish_reason"] = finish
		if finish == finishLength {
			log.Printf("WARN chat truncated at the output cap finish_reason=%s provider=%s model=%s", finish, providerName, model)
		}
	}
	if providerName != "" {
		r["provider"] = providerName
	}
	if model != "" {
		r["model"] = model
		r["context"] = ctx
	}
	if len(calls) > 0 {
		tcs := make([]map[string]any, 0, len(calls))
		for _, tc := range calls {
			// skip empty slots (e.g. an interrupted parallel call)
			if tc.ID == "" && tc.Function.Name == "" {
				continue
			}
			tcs = append(tcs, map[string]any{
				"id": tc.ID, "type": "function",
				"function": map[string]any{"name": tc.Function.Name, "arguments": tc.Function.Arguments},
			})
		}
		if len(tcs) > 0 {
			r["tool_calls"] = tcs
		}
	}
	if usageSeen && (usage.PromptTokens > 0 || usage.CompletionTokens > 0 || usage.TotalTokens > 0) {
		u := map[string]any{
			"prompt_tokens":     usage.PromptTokens,
			"completion_tokens": usage.CompletionTokens,
			"total_tokens":      usage.TotalTokens,
		}
		// Cache economics (docs/research/EXPERT.md §8): forward the provider's
		// cached-input breakdown when reported, so callers can measure
		// prompt-cache hits and (since #123) writes. cache_write_tokens is the
		// provider's cache-CREATION count (Anthropic bills it at write rates) —
		// it is not part of prompt_tokens_details' OpenAI shape, so only the
		// Anthropic adapter supplies it.
		details := map[string]any{}
		if usage.PromptTokensDetails != nil && usage.PromptTokensDetails.CachedTokens > 0 {
			details["cached_tokens"] = usage.PromptTokensDetails.CachedTokens
		}
		if cacheWriteTokens > 0 {
			details["cache_write_tokens"] = cacheWriteTokens
		}
		if len(details) > 0 {
			u["prompt_tokens_details"] = details
		}
		// Reasoning tokens (#123): only some providers report thinking spend;
		// omit the field rather than inventing a zero.
		if usage.CompletionTokensDetails != nil && usage.CompletionTokensDetails.ReasoningTokens > 0 {
			u["completion_tokens_details"] = map[string]any{
				"reasoning_tokens": usage.CompletionTokensDetails.ReasoningTokens,
			}
		}
		r["usage"] = u
	}
	return r, nil
}

func resolveHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	var args struct {
		Provider string `json:"provider"`
		Model    string `json:"model"`
	}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &args); err != nil {
			return nil, fmt.Errorf("bad resolve args: %w", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := resolveRuntimeConfig(ctx, c, args.Provider, args.Model)
	if err != nil {
		return nil, err
	}
	resp := map[string]any{
		"ok":       true,
		"provider": resolved.ProviderName, "providerSource": resolved.ProviderSource,
		"model": resolved.Model, "catalog": resolved.Catalog,
		"context": resolved.Context, "contextSource": resolved.ContextSource,
		"output": resolved.Output, "outputSource": resolved.OutputSource,
		"vision": resolved.Vision, "visionSource": resolved.VisionSource,
		"protocol": resolved.Provider.Protocol, "authType": resolved.Provider.AuthType,
		"hasKey": resolved.Provider.APIKey != "",
		// Embedding capability, resolved here for the same reason hasKey is:
		// resolution is where a caller learns what is configured, without
		// paying for a failing embed call to find out. Empty = no embeddings.
		"embedModel": resolved.Provider.EmbedModel,
	}
	// A fallback window is a guess, and the context guard measures against it:
	// the common cause is a drifted pin — a model chosen under one provider
	// carried over to another (observed as provider=synthetic + a xiaomi model,
	// resolving to a 128000-token window for a model whose catalog window is
	// far larger). Surface it where the pins are set instead of silently
	// admission-controlling against the wrong window.
	if resolved.ContextSource == "fallback" {
		resp["warning"] = fmt.Sprintf(
			"no catalog match for provider %q + model %q — using the %d-token fallback window; check the conversation's provider/model pins",
			resolved.ProviderName, resolved.Model, resolved.Context)
	}
	return resp, nil
}

// Chat tool timeout. Slow reasoning models (e.g. GLM with thinking=max via
// llmgateway) can exceed the 5-minute default on a single completion; bench
// runs raise it with NIF_LLM_TIMEOUT_MS.
func chatTimeoutMs() int {
	if v := os.Getenv("NIF_LLM_TIMEOUT_MS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 300000
}

func main() {
	comp := sdk.New("llm", "0.4.0")
	// Both handlers are request-local: provider/model lookup uses thread-safe
	// NATS requests, each chat owns its HTTP client, cancellation subscription,
	// stream accumulators, and result. The only package maps are read-only.
	// Opting in here prevents independent sessions/subagents from serializing
	// behind one long model request.
	comp.ToolConcurrent("llm_resolve", map[string]any{
		"type":        "object",
		"description": "Resolve the effective provider, model and context window without exposing credentials or making an inference request.",
		"properties": map[string]any{
			"provider": map[string]any{"type": "string", "description": "Optional stored or NIF_LLM_PROVIDERS nickname"},
			"model":    map[string]any{"type": "string", "description": "Optional model override"},
		},
		"x-harness": map[string]any{"hidden": true, "runner": true, "timeoutMs": 10000},
	}, resolveHandler)
	// Live model discovery (option B): the models component discovers this
	// hidden tool via reg.publish and calls it on its refresh cycle. The
	// patch adds ids each provider actually serves (probed after chats) to
	// the catalog; models.dev metadata stays authoritative for everything
	// else. Concurrent: it is a background management read (a mutex-guarded
	// map snapshot), and the models refresh must never wait behind a
	// streaming chat — that wait used to stall llm_resolve and every new
	// chat, because a serialized handler blocked the component's call queue.
	comp.ToolConcurrent("llm_models_source", map[string]any{
		"type":        "object",
		"description": "Live model ids observed per provider; x-models-source v1 patch.",
		"properties": map[string]any{
			"version": map[string]any{"type": "integer"},
		},
		"x-harness":       map[string]any{"hidden": true},
		"x-models-source": map[string]any{"version": modelsSourceVersion, "priority": 150},
	}, modelsSourceHandler)
	// Both handlers are request-local: each chat owns its HTTP client,
	// cancellation subscription, stream accumulators, and result. The only
	// package maps are read-only. Opting in prevents independent sessions
	// and subagents from serializing behind one long model request.
	// Concurrent for the same reason as chat: an embedding call is an
	// independent HTTP request and must never queue behind a streaming
	// completion. Runner-exempt because core's compaction/recall machinery
	// may reach it mid-turn.
	comp.ToolConcurrent("embed", map[string]any{
		"type":        "object",
		"description": "Embed text through the active provider's embedding model, returning one float vector per input. Use it to rank a candidate set you already hold or to persist vectors yourself; the model comes from the provider's embedModel.",
		"properties": map[string]any{
			"input": map[string]any{"type": "array", "items": map[string]any{"type": "string"},
				"description": "Texts to embed, in order (max 256)"},
			"model": map[string]any{"type": "string",
				"description": "Override the provider's embedModel"},
			"provider": map[string]any{"type": "string",
				"description": "Provider nickname (default: the provider component's active provider)"},
			"dimensions": map[string]any{"type": "integer",
				"description": "Requested vector length, when the model supports truncation (0 = model default)"},
		},
		"required":  []string{"input"},
		"x-harness": map[string]any{"hidden": true, "runner": true, "timeoutMs": 120000},
	}, embedHandler)
	comp.ToolConcurrent("chat", map[string]any{
		"type": "object",
		"properties": map[string]any{
			"messages": map[string]any{"type": "array",
				"description": "Chat messages: [{role, content}]"},
			"tools": map[string]any{"type": "array",
				"description": "OpenAI tool definitions: [{type: function, function: {name, description, parameters}}]"},
			"model": map[string]any{"type": "string",
				"description": "Override the provider's default model"},
			"provider": map[string]any{"type": "string",
				"description": "Provider nickname from NIF_LLM_PROVIDERS (default: the provider component's active provider, else NIF_OPENAI_*)"},
			"sessionId": map[string]any{"type": "string",
				"description": "Session handle for token routing and provider correlation"},
			"cancelId": map[string]any{"type": "string",
				"description": "Optional cancellation subject suffix; defaults to sessionId. Auxiliary callers use a distinct id."},
			"stream": map[string]any{"type": "boolean",
				"description": "Stream internally while generating (default false)"},
			"emitTokens": map[string]any{"type": "boolean",
				"description": "Publish ev.llm.token frames (default true; false for auxiliary calls)"},
			"purpose": map[string]any{"type": "string",
				"description": "Telemetry purpose only, for example compaction"},
			"reasoning_effort": map[string]any{"type": "string",
				"description": "Backend reasoning effort (low/medium/high/max); omitted when empty = provider default"},
			"maxTokens": map[string]any{"type": "integer",
				"description": "Per-call output cap in tokens; only lowers the provider default (used for small structured replies, e.g. judge verdicts)"},
		},
		"required":  []string{"messages"},
		"x-harness": map[string]any{"hidden": true, "runner": true, "timeoutMs": chatTimeoutMs()},
	}, chatHandler)
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "llm:", err)
		os.Exit(1)
	}
}
