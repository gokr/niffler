// llm component — streaming OpenAI-compatible chat completions adapter.
//
// The full adapter: streaming with reasoning tokens (deepseek-reasoner's
// reasoning_content), streamed tool-call aggregation, per-call model
// override and a provider nickname table. The tiny `llm-openai` component
// stays as the minimal example implementation.
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

type provider struct {
	BaseURL string `json:"baseUrl"`
	APIKey  string `json:"apiKey"`
	Model   string `json:"model"`
	Context int    `json:"context"`
	Catalog string `json:"catalog"`
}

const defaultProvider = "default"

const defaultContext = 128000 // conservative fallback for unknown models

// knownContext: model id (lowercase) -> context window (tokens).
var knownContext = map[string]int{
	"deepseek-chat":     1000000,
	"deepseek-reasoner": 1000000,
}

// contextWindow returns the context size for a model: explicit overrides,
// the models component's effective catalog, the local fallback, then default.
// ctx bounds the catalog lookup (and is canceled when the caller aborts).
func contextWindow(ctx context.Context, c *sdk.Component, p provider, providerName, model string) int {
	if p.Context > 0 {
		return p.Context
	}
	if v := os.Getenv("NIF_OPENAI_CONTEXT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	catalogProvider := p.Catalog
	if catalogProvider == "" {
		catalogProvider = inferCatalogProvider(providerName, p.BaseURL, model)
	}
	if catalogProvider != "" {
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
				return descriptor.Model.Limit.Context
			}
		}
	}
	if c, ok := knownContext[strings.ToLower(model)]; ok {
		return c
	}
	return defaultContext
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
			BaseURL: base,
			APIKey:  os.Getenv("NIF_OPENAI_API_KEY"),
			Model:   model,
			Catalog: os.Getenv("NIF_OPENAI_PROVIDER"),
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

// ---------------------------------------------------------------------------
// chat tool

type chatArgs struct {
	Messages  []openai.ChatCompletionMessage `json:"messages"`
	Tools     []openai.Tool                  `json:"tools"`
	Model     string                         `json:"model"`
	Provider  string                         `json:"provider"`
	SessionID string                         `json:"sessionId"`
	Stream    bool                           `json:"stream"`
}

func chatHandler(c *sdk.Component, raw json.RawMessage) (any, error) {
	var args chatArgs
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad chat args: %w", err)
	}
	if len(args.Messages) == 0 {
		return nil, fmt.Errorf("messages required")
	}

	providers, err := loadProviders()
	if err != nil {
		return nil, err
	}
	key := args.Provider
	if key == "" {
		key = defaultProvider
	}
	p, ok := providers[key]
	if !ok {
		return nil, fmt.Errorf("unknown provider %q (have: %s)", key, providerNames(providers))
	}
	if p.APIKey == "" {
		return nil, fmt.Errorf("provider %q: no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)", key)
	}
	model := args.Model
	if model == "" {
		model = p.Model
	}
	if model == "" {
		model = "deepseek-chat"
	}

	cfg := openai.DefaultConfig(p.APIKey)
	cfg.BaseURL = p.BaseURL
	client := openai.NewClientWithConfig(cfg)

	// The cancellation side-channel is subscribed before the context-window
	// lookup: a cancel published during that window must still abort the
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

	contextSize := contextWindow(streamCtx, c, p, key, model)

	if args.Stream {
		return chatStream(streamCtx, c, client, model, args, contextSize)
	}
	return chatOnce(client, model, args, contextSize)
}

func chatOnce(client *openai.Client, model string, args chatArgs, contextSize int) (any, error) {
	resp, err := client.CreateChatCompletion(context.Background(), openai.ChatCompletionRequest{
		Model:    model,
		Messages: args.Messages,
		Tools:    args.Tools,
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Choices) == 0 {
		return nil, errors.New("no choices in llm response")
	}
	msg := resp.Choices[0].Message
	return resultJSON(resp.Model, contextSize, msg.Content,
		msg.ReasoningContent, msg.ToolCalls, resp.Usage, true)
}

func chatStream(ctx context.Context, c *sdk.Component, client *openai.Client, model string, args chatArgs, contextSize int) (any, error) {
	// chatHandler owns the llm.cancel.<sessionId> side-channel subscription;
	// this derivation just bounds this call to that shared context.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	stream, err := client.CreateChatCompletionStream(ctx, openai.ChatCompletionRequest{
		Model:         model,
		Messages:      args.Messages,
		Tools:         args.Tools,
		StreamOptions: &openai.StreamOptions{IncludeUsage: true},
	})
	if err != nil {
		return nil, err
	}
	defer stream.Close()

	var content, reasoning strings.Builder
	var calls []openai.ToolCall // aggregated by index, in stream order
	var usedModel string
	var usage openai.Usage
	var usageSeen bool

	for {
		resp, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
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
		if delta.ReasoningContent != "" {
			reasoning.WriteString(delta.ReasoningContent)
		}
		// one token frame per chunk with anything to show
		if args.SessionID != "" && (delta.Content != "" || delta.ReasoningContent != "") {
			_ = c.Emit("ev.llm.token", map[string]any{
				"sessionId": args.SessionID,
				"content":   delta.Content,
				"reasoning": delta.ReasoningContent,
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
	return resultJSON(usedModel, contextSize, content.String(),
		reasoning.String(), calls, usage, usageSeen)
}

// resultJSON builds the wire result — the same shape llm-openai returns,
// so core's conversation loop consumes it unchanged — plus `reasoning`.
func resultJSON(model string, ctx int, content, reasoning string,
	calls []openai.ToolCall, usage openai.Usage, usageSeen bool) (any, error) {
	r := map[string]any{"content": content, "reasoning": reasoning}
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
		r["usage"] = map[string]any{
			"prompt_tokens":     usage.PromptTokens,
			"completion_tokens": usage.CompletionTokens,
			"total_tokens":      usage.TotalTokens,
		}
	}
	return r, nil
}

func main() {
	comp := sdk.New("llm", "0.2.0")
	comp.Tool("chat", map[string]any{
		"type": "object",
		"properties": map[string]any{
			"messages": map[string]any{"type": "array",
				"description": "Chat messages: [{role, content}]"},
			"tools": map[string]any{"type": "array",
				"description": "OpenAI tool definitions: [{type: function, function: {name, description, parameters}}]"},
			"model": map[string]any{"type": "string",
				"description": "Override the provider's default model"},
			"provider": map[string]any{"type": "string",
				"description": "Provider nickname from NIF_LLM_PROVIDERS (default: default)"},
			"sessionId": map[string]any{"type": "string",
				"description": "Session handle for ev.llm.token routing and llm.cancel.<sessionId> cancellation"},
			"stream": map[string]any{"type": "boolean",
				"description": "Emit ev.llm.token {sessionId, content, reasoning} frames while generating (default false)"},
		},
		"required":  []string{"messages"},
		"x-harness": map[string]any{"hidden": true, "timeoutMs": 300000},
	}, chatHandler)
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "llm:", err)
		os.Exit(1)
	}
}
