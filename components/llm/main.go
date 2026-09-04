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
//   chat {messages, tools?, model?, provider?, sessionId?, stream?}
//   → result {content, reasoning?, tool_calls?, model, context, usage?}
//   stream: true additionally emits ev.llm.token {sessionId, content,
//   reasoning} frames (deltas) while generating.
//   Cancellation: publish an envelope to llm.cancel.<sessionId> to abort
//   the in-flight streaming call.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
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
	BaseURL   string `json:"baseUrl"`
	APIKey    string `json:"apiKey"`
	Model     string `json:"model"`
	Context   int    `json:"context"`
	Catalog   string `json:"catalog"`
	Protocol  string `json:"protocol"`
	AuthType  string `json:"authType"`
	AccountID string `json:"accountId"`
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
var knownContext = map[string]int{
	"deepseek-chat":     1000000,
	"deepseek-reasoner": 1000000,
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
	StripPrefix    bool
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

// resolveOutputWindow returns the model's max output tokens and its
// provenance. The catalog's limit.output is authoritative when present;
// otherwise a generous default so the provider's server-side cap (which
// would otherwise truncate answers mid-stream) is not hit.
func resolveOutputWindow(ctx context.Context, c *sdk.Component, catalogProvider, model string) (int, string) {
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
						Output int `json:"output"`
					} `json:"limit"`
				} `json:"model"`
			}
			if json.Unmarshal(raw, &descriptor) == nil && descriptor.Model.Limit.Output > 0 {
				return descriptor.Model.Limit.Output, "catalog"
			}
		}
	}
	return defaultOutput, "fallback"
}

func resolveRuntimeConfig(ctx context.Context, c *sdk.Component, providerOverride, modelOverride string) (resolvedConfig, error) {
	p, providerName, providerSource, err := resolveProvider(c, providerOverride)
	if err != nil {
		return resolvedConfig{}, err
	}
	model := strings.TrimSpace(modelOverride)
	if model == "" {
		model = p.Model
	}
	if model == "" {
		model = "deepseek-chat"
	}
	contextSize, catalogProvider, contextSource := resolveContextWindow(ctx, c, p, providerName, model)
	outputSize, outputSource := resolveOutputWindow(ctx, c, catalogProvider, model)
	return resolvedConfig{
		Provider: p, ProviderName: providerName, ProviderSource: providerSource,
		Model: model, Catalog: catalogProvider, Context: contextSize,
		ContextSource: contextSource, Output: outputSize, OutputSource: outputSource,
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
			BaseURL:  base,
			APIKey:   os.Getenv("NIF_OPENAI_API_KEY"),
			Model:    model,
			Catalog:  os.Getenv("NIF_OPENAI_PROVIDER"),
			Protocol: protocolOpenAI,
			AuthType: authAPIKey,
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
func resolveProvider(c *sdk.Component, name string) (provider, string, string, error) {
	if name != "" {
		if p, nickname, source, ok := namedStoredProvider(c, name); ok {
			return p, nickname, source, nil
		}
		p, nickname, err := envProvider(name)
		return p, nickname, "environment", err
	}
	if p, nickname, source, ok := activeStoredProvider(c); ok {
		return p, nickname, source, nil
	}
	p, nickname, err := envProvider(defaultProvider)
	return p, nickname, "environment", err
}

// envProvider looks up a named provider in the environment tables.
func envProvider(name string) (provider, string, error) {
	providers, err := loadProviders()
	if err != nil {
		return provider{}, "", err
	}
	p, ok := providers[name]
	if !ok {
		return provider{}, "", fmt.Errorf("unknown provider %q (have: %s)", name, providerNames(providers))
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
		BaseURL     string `json:"baseUrl"`
		Model       string `json:"model"`
		Catalog     string `json:"catalog"`
		Context     int    `json:"context"`
		StripPrefix bool   `json:"stripPrefix"`
	} `json:"provider"`
}

func requestStoredProvider(c *sdk.Component, tool string, args map[string]any) (provider, string, string, bool) {
	if c == nil {
		return provider{}, "", "", false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	raw, err := c.RequestContext(ctx, "provider", tool, args)
	if err != nil {
		return provider{}, "", "", false
	}
	var resp registryResponse
	if err := json.Unmarshal(raw, &resp); err != nil || !resp.Ok || resp.Provider == nil {
		return provider{}, "", "", false
	}
	credential := resp.Provider.APIKey
	accountID := ""
	if resp.Provider.OAuth != nil {
		credential = resp.Provider.OAuth.Access
		accountID = resp.Provider.OAuth.AccountID
	}
	if credential == "" {
		return provider{}, "", "", false
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
	return provider{
		BaseURL:     resp.Provider.BaseURL,
		APIKey:      credential,
		Model:       resp.Provider.Model,
		Catalog:     resp.Provider.Catalog,
		Context:     resp.Provider.Context,
		Protocol:    protocol,
		AuthType:    authType,
		AccountID:   accountID,
		StripPrefix: resp.Provider.StripPrefix,
	}, resp.Provider.Nickname, source, true
}

// activeStoredProvider asks the provider component for its active provider.
// Returns ok=false when the component is absent, has no active provider, or
// the lookup fails — the caller falls back to the environment. Because the
// answer is re-read per chat call, provider_switch live-updates the backend
// with no further coordination.
func activeStoredProvider(c *sdk.Component) (provider, string, string, bool) {
	return requestStoredProvider(c, "provider_active", map[string]any{})
}

func namedStoredProvider(c *sdk.Component, name string) (provider, string, string, bool) {
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
	}
	return result
}

type chatArgs struct {
	Messages  []chatMessage `json:"messages"`
	Tools     []openai.Tool `json:"tools"`
	Model     string        `json:"model"`
	Provider  string        `json:"provider"`
	SessionID string        `json:"sessionId"`
	Stream    bool          `json:"stream"`
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

func chatHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
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
	// stream (NATS events are not durable).
	streamCtx, streamCancel := context.WithCancel(context.Background())
	defer streamCancel()
	var unsub func()
	if args.Stream && args.SessionID != "" {
		var err error
		unsub, err = c.Subscribe("llm.cancel."+args.SessionID, func(subject string, payload json.RawMessage) {
			streamCancel()
		})
		if err != nil {
			return nil, err
		}
		defer unsub()
	}

	resolved, err := resolveRuntimeConfig(streamCtx, c, args.Provider, args.Model)
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
	// Best-effort live model discovery (option B): remember this provider's
	// endpoint and, when its id cache is stale, probe /models in the
	// background so the models component can publish served ids catalog-wide.
	maybeProbeLiveModels(streamCtx, c, resolved)
	switch resolved.Provider.Protocol {
	case protocolCodex:
		return chatCodex(streamCtx, c, resolved.Provider, model, resolved.ProviderName, args,
			resolved.Context)
	case protocolAnthropic:
		return chatAnthropic(streamCtx, c, resolved.Provider, model, resolved.ProviderName, args,
			resolved.Context, output)
	case "", protocolOpenAI:
		cfg := openai.DefaultConfig(resolved.Provider.APIKey)
		cfg.BaseURL = resolved.Provider.BaseURL
		client := openai.NewClientWithConfig(cfg)
		if args.Stream {
			return chatStream(streamCtx, c, client, model, resolved.ProviderName, args, resolved.Context, output)
		}
		return chatOnce(client, model, resolved.ProviderName, args, resolved.Context, output)
	default:
		return nil, fmt.Errorf("provider %q: unsupported protocol %q", resolved.ProviderName, resolved.Provider.Protocol)
	}
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
// strict backend never rejects replayed history. Only assistant tool_calls
// are touched; everything else round-trips unchanged.
func sanitizeMessages(msgs []chatMessage) {
	for i := range msgs {
		if msgs[i].Role != openai.ChatMessageRoleAssistant {
			continue
		}
		for j := range msgs[i].ToolCalls {
			msgs[i].ToolCalls[j].Function.Arguments =
				repairToolArgs(msgs[i].ToolCalls[j].Function.Arguments)
		}
	}
}

func chatOnce(client *openai.Client, model, providerName string, args chatArgs, contextSize, outputSize int) (any, error) {
	startedAt := time.Now()
	resp, err := client.CreateChatCompletion(context.Background(), openai.ChatCompletionRequest{
		Model:               model,
		Messages:            openAIMessages(args.Messages),
		Tools:               args.Tools,
		ParallelToolCalls:   true,
		MaxCompletionTokens: outputSize,
		ReasoningEffort:     args.ReasoningEffort,
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Choices) == 0 {
		return nil, errors.New("no choices in llm response")
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
	log.Printf("INFO chat provider=%s model=%s effort=%s ttft=n/a dur=%s prompt=%d completion=%d tok/s=%.1f status=ok",
		providerName, usedModel, effort, total.Truncate(time.Millisecond),
		resp.Usage.PromptTokens, resp.Usage.CompletionTokens, tps)
	return resultJSON(providerName, usedModel, contextSize, msg.Content,
		msg.ReasoningContent, msg.ToolCalls, resp.Usage, true)
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
	Delta llmDelta `json:"delta"`
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

	stream, err := client.CreateChatCompletionStream(ctx, openai.ChatCompletionRequest{
		Model:               model,
		Messages:            openAIMessages(args.Messages),
		Tools:               args.Tools,
		ParallelToolCalls:   true,
		MaxCompletionTokens: outputSize,
		ReasoningEffort:     args.ReasoningEffort,
		StreamOptions:       &openai.StreamOptions{IncludeUsage: true},
	})
	if err != nil {
		return nil, err
	}
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
		log.Printf("INFO chat provider=%s model=%s effort=%s ttft=%s dur=%s prompt=%d completion=%d tok/s=%.1f reasoning_chars=%d status=%s",
			providerName, model, effort, ttft.Truncate(time.Millisecond), total.Truncate(time.Millisecond),
			usage.PromptTokens, usage.CompletionTokens, tps, reasoningChars, status)
	}

	var content, reasoning strings.Builder
	var calls []openai.ToolCall // aggregated by index, in stream order
	var usedModel string
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
		var resp llmChunk
		if err := json.Unmarshal(raw, &resp); err != nil {
			logStreamStats(usage, reasoning.Len(), true)
			return nil, fmt.Errorf("bad stream chunk: %w", err)
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
		if args.SessionID != "" && (delta.Content != "" || delta.reasoning() != "") {
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
	logStreamStats(usage, reasoning.Len(), false)
	return resultJSON(providerName, usedModel, contextSize, content.String(),
		reasoning.String(), calls, usage, usageSeen)
}

// resultJSON builds the wire result — the same shape llm-openai returns,
// so core's conversation loop consumes it unchanged — plus `reasoning`.
func resultJSON(providerName, model string, ctx int, content, reasoning string,
	calls []openai.ToolCall, usage openai.Usage, usageSeen bool) (any, error) {
	r := map[string]any{"content": content, "reasoning": reasoning}
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
		// Cache economics (docs/research/EXPERT.md §8): forward the provider's cached-input
		// breakdown when reported, so callers can measure prompt-cache hits.
		if usage.PromptTokensDetails != nil && usage.PromptTokensDetails.CachedTokens > 0 {
			u["prompt_tokens_details"] = map[string]any{
				"cached_tokens": usage.PromptTokensDetails.CachedTokens,
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
	return map[string]any{
		"ok":       true,
		"provider": resolved.ProviderName, "providerSource": resolved.ProviderSource,
		"model": resolved.Model, "catalog": resolved.Catalog,
		"context": resolved.Context, "contextSource": resolved.ContextSource,
		"output": resolved.Output, "outputSource": resolved.OutputSource,
		"protocol": resolved.Provider.Protocol, "authType": resolved.Provider.AuthType,
		"hasKey": resolved.Provider.APIKey != "",
	}, nil
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
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 10000},
	}, resolveHandler)
	// Live model discovery (option B): the models component discovers this
	// hidden tool via reg.publish and calls it on its refresh cycle. The
	// patch adds ids each provider actually serves (probed after chats) to
	// the catalog; models.dev metadata stays authoritative for everything
	// else.
	comp.Tool("llm_models_source", map[string]any{
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
				"description": "Session handle for ev.llm.token routing and llm.cancel.<sessionId> cancellation"},
			"stream": map[string]any{"type": "boolean",
				"description": "Emit ev.llm.token {sessionId, content, reasoning} frames while generating (default false)"},
			"reasoning_effort": map[string]any{"type": "string",
				"description": "Backend reasoning effort (low/medium/high/max); omitted when empty = provider default"},
			"maxTokens": map[string]any{"type": "integer",
				"description": "Per-call output cap in tokens; only lowers the provider default (used for small structured replies, e.g. judge verdicts)"},
		},
		"required":  []string{"messages"},
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 300000},
	}, chatHandler)
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "llm:", err)
		os.Exit(1)
	}
}
