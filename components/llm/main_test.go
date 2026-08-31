package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	openai "github.com/sashabaranov/go-openai"
)

func TestInferCatalogProviderPrefersEndpoint(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		baseURL  string
		model    string
		want     string
	}{
		{"deepseek", defaultProvider, "https://api.deepseek.com/v1", "deepseek-chat", "deepseek"},
		{"openrouter", defaultProvider, "https://openrouter.ai/api/v1", "deepseek-chat", "openrouter"},
		{"openai", defaultProvider, "https://api.openai.com/v1", "deepseek-chat", "openai"},
		{"model fallback", defaultProvider, "https://gateway.example/v1", "deepseek-chat", "deepseek"},
		{"named fallback", "local", "http://localhost:11434/v1", "qwen3", "local"},
		{"proxy host not confused", defaultProvider, "https://api.openai.com.proxy.example/v1", "llama-3", ""},
		{"path spoof not confused", defaultProvider, "https://gateway.example/api.openai.com/v1", "llama-3", ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := inferCatalogProvider(test.provider, test.baseURL, test.model)
			if got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func withEnv(t *testing.T, set, unset map[string]string) {
	t.Helper()
	for k := range set {
		t.Setenv(k, set[k])
	}
	for k := range unset {
		t.Setenv(k, unset[k])
	}
}

func TestLoadProvidersParsesEnvTable(t *testing.T) {
	withEnv(t,
		map[string]string{
			"NIF_OPENAI_BASE_URL": "https://api.deepseek.com",
			"NIF_OPENAI_MODEL":    "deepseek-chat",
			"NIF_OPENAI_API_KEY":  "sk-env",
			"NIF_LLM_PROVIDERS": `{"openrouter": {"baseUrl": "https://openrouter.ai/api/v1",
				"apiKey": "sk-or", "model": "deepseek/deepseek-chat", "catalog": "openrouter"}}`,
		},
		nil)

	ps, err := loadProviders()
	if err != nil {
		t.Fatalf("loadProviders: %v", err)
	}
	def, ok := ps[defaultProvider]
	if !ok {
		t.Fatalf("default provider missing")
	}
	if def.BaseURL != "https://api.deepseek.com" || def.APIKey != "sk-env" || def.Model != "deepseek-chat" {
		t.Fatalf("default provider wrong: %+v", def)
	}
	or, ok := ps["openrouter"]
	if !ok {
		t.Fatalf("openrouter provider missing")
	}
	if or.BaseURL != "https://openrouter.ai/api/v1" || or.APIKey != "sk-or" || or.Catalog != "openrouter" {
		t.Fatalf("openrouter provider wrong: %+v", or)
	}
}

func TestLoadProvidersRejectsBadEnvTable(t *testing.T) {
	withEnv(t, map[string]string{"NIF_LLM_PROVIDERS": "{not json"}, nil)
	if _, err := loadProviders(); err == nil {
		t.Fatalf("expected parse error for bad NIF_LLM_PROVIDERS")
	}
}

func TestEnvProviderResolution(t *testing.T) {
	withEnv(t,
		map[string]string{
			"NIF_OPENAI_BASE_URL": "https://api.deepseek.com",
			"NIF_OPENAI_API_KEY":  "sk-env",
		},
		map[string]string{"NIF_LLM_PROVIDERS": ""})

	// explicit unknown name errors with the known list
	if _, _, err := envProvider("nope"); err == nil {
		t.Fatalf("expected error for unknown provider")
	}
	// default resolves from NIF_OPENAI_*
	p, name, err := envProvider(defaultProvider)
	if err != nil {
		t.Fatalf("envProvider(default): %v", err)
	}
	if name != defaultProvider || p.APIKey != "sk-env" {
		t.Fatalf("got %+v (%q)", p, name)
	}
	// missing key is an error
	withEnv(t, map[string]string{"NIF_OPENAI_API_KEY": ""}, nil)
	if _, _, err := envProvider(defaultProvider); err == nil {
		t.Fatalf("expected error when no API key")
	}
}

func TestResolveProviderFallsBackToEnvWithoutStore(t *testing.T) {
	// No provider component on the bus (nil component never reaches NATS):
	// the default must fall back to the environment, not hang or fail.
	withEnv(t, map[string]string{"NIF_OPENAI_API_KEY": "sk-env"}, nil)
	p, name, source, err := resolveProvider(nil, "")
	if err != nil {
		t.Fatalf("resolveProvider(nil): %v", err)
	}
	if name != defaultProvider || source != "environment" || p.APIKey != "sk-env" {
		t.Fatalf("got %+v (%q, %q)", p, name, source)
	}
}

func TestResolveRuntimeConfigReportsContextSource(t *testing.T) {
	withEnv(t,
		map[string]string{
			"NIF_OPENAI_BASE_URL": "https://api.deepseek.com/v1",
			"NIF_OPENAI_API_KEY":  "sk-env",
			"NIF_OPENAI_MODEL":    "deepseek-chat",
			"NIF_OPENAI_CONTEXT":  "777777",
		},
		map[string]string{"NIF_LLM_PROVIDERS": ""})

	resolved, err := resolveRuntimeConfig(t.Context(), nil, "", "deepseek-reasoner")
	if err != nil {
		t.Fatalf("resolveRuntimeConfig: %v", err)
	}
	if resolved.ProviderName != defaultProvider || resolved.ProviderSource != "environment" {
		t.Fatalf("provider resolution = %+v", resolved)
	}
	if resolved.Model != "deepseek-reasoner" || resolved.Catalog != "deepseek" {
		t.Fatalf("model/catalog resolution = %+v", resolved)
	}
	if resolved.Context != 777777 || resolved.ContextSource != "environment" {
		t.Fatalf("context resolution = %+v", resolved)
	}
}

func TestResolveHandlerNeverReturnsCredentials(t *testing.T) {
	withEnv(t,
		map[string]string{
			"NIF_OPENAI_BASE_URL": "https://token-in-url.example/v1?api_key=url-secret",
			"NIF_OPENAI_API_KEY":  "sk-super-secret",
			"NIF_OPENAI_MODEL":    "deepseek-chat",
		},
		map[string]string{"NIF_LLM_PROVIDERS": ""})

	result, err := resolveHandler(nil, json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	text := string(encoded)
	for _, forbidden := range []string{"sk-super-secret", "url-secret", "baseUrl", "apiKey"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("llm_resolve leaked %q in %s", forbidden, text)
		}
	}
	if !strings.Contains(text, `"hasKey":true`) {
		t.Fatalf("llm_resolve omitted safe key-presence flag: %s", text)
	}
}

func TestResultJSONIncludesProvider(t *testing.T) {
	result, err := resultJSON("deepseek", "deepseek-chat", 1_000_000, "ok", "", nil, openai.Usage{}, false)
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["provider"] != "deepseek" || got["model"] != "deepseek-chat" || got["context"] != 1_000_000 {
		t.Fatalf("result = %#v", got)
	}
}

func TestStripModelPrefix(t *testing.T) {
	cases := map[string]string{
		"alibaba/glm-5.2":        "glm-5.2",
		"glm-5.2":                "glm-5.2",
		"deepseek/deepseek-chat": "deepseek-chat",
		"":                       "",
	}
	for in, want := range cases {
		if got := stripModelPrefix(in); got != want {
			t.Fatalf("stripModelPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRepairToolArgs(t *testing.T) {
	truncated := `{"command": "cd /home/gokr && echo \"=== worktrees ===\"`
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"valid passes through", `{"tool":"info","arguments":{}}`, `{"tool":"info","arguments":{}}`},
		{"truncated string value completes", truncated, truncated + `"}`},
		{"truncated object completes", `{"a": 1`, `{"a": 1}`},
		{"truncated array completes", `[1, 2`, `[1, 2]`},
		{"truncated bare string completes", `"abc`, `"abc"`},
		{"empty falls back", "", `{}`},
		{"garbage falls back", `garbage`, `{}`},
		{"trailing garbage falls back", `{"a": 1} junk`, `{}`},
		{"mismatched closer falls back", `{"a": 1]`, `{}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := repairToolArgs(c.in)
			if !json.Valid([]byte(got)) {
				t.Fatalf("repairToolArgs(%q) = %q, not valid JSON", c.in, got)
			}
			if got != c.want {
				t.Fatalf("repairToolArgs(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestSanitizeMessagesRepairsPoisonedHistory(t *testing.T) {
	bad := `{"command": "cd /home/gokr && echo \"=== worktrees ===\"`
	msgs := []chatMessage{
		{Role: openai.ChatMessageRoleUser, Content: "hi"},
		{Role: openai.ChatMessageRoleAssistant, ToolCalls: []openai.ToolCall{
			{ID: "c1", Type: openai.ToolTypeFunction, Function: openai.FunctionCall{Name: "bash", Arguments: bad}},
			{ID: "c2", Type: openai.ToolTypeFunction, Function: openai.FunctionCall{Name: "invoke", Arguments: `{"tool":"info"}`}},
		}},
		{Role: openai.ChatMessageRoleTool, Content: "{}"},
	}
	sanitizeMessages(msgs)
	if got := msgs[1].ToolCalls[0].Function.Arguments; !json.Valid([]byte(got)) {
		t.Fatalf("first tool call still invalid after sanitize: %q", got)
	}
	if got := msgs[1].ToolCalls[0].Function.Arguments; got != bad+`"}` {
		t.Fatalf("repaired arguments = %q", got)
	}
	if got := msgs[1].ToolCalls[1].Function.Arguments; got != `{"tool":"info"}` {
		t.Fatalf("valid arguments were altered: %q", got)
	}
	if msgs[0].Content != "hi" || msgs[2].Content != "{}" {
		t.Fatal("non-assistant messages were altered")
	}
}

func TestChatArgsRestoresReasoningContent(t *testing.T) {
	var args chatArgs
	if err := json.Unmarshal([]byte(`{"messages":[{"role":"assistant","content":null,"reasoning":"checked the tools","tool_calls":[{"id":"c1","type":"function","function":{"name":"list","arguments":"{}"}}]}]}`), &args); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(openAIMessages(args.Messages))
	if err != nil {
		t.Fatal(err)
	}
	got := string(encoded)
	if !strings.Contains(got, `"reasoning_content":"checked the tools"`) {
		t.Fatalf("reasoning_content missing from provider messages: %s", got)
	}
	if strings.Contains(got, `"reasoning":`) {
		t.Fatalf("internal reasoning field leaked to provider: %s", got)
	}
}

// TestChatStreamCapturesZaiReasoningField covers the regression where
// zai/glm-family gateways stream thinking as "reasoning" — a field the
// go-openai library drops — so every thinking block silently vanished.
// The stream loop reads RecvRaw and keeps both field names.
func TestChatStreamCapturesZaiReasoningField(t *testing.T) {
	tests := []struct {
		name      string
		fieldName string // "reasoning" (zai) or "reasoning_content" (deepseek)
	}{
		{name: "zai reasoning", fieldName: "reasoning"},
		{name: "deepseek reasoning_content", fieldName: "reasoning_content"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newSSEChatServer(t, []string{
				`{"model":"m1","choices":[{"delta":{"` + test.fieldName + `":"The user"}}]}`,
				`{"model":"m1","choices":[{"delta":{"` + test.fieldName + `":" asked"}}]}`,
				`{"choices":[{"delta":{"content":"Sure!"}}]}`,
			})
			defer server.Close()

			cfg := openai.DefaultConfig("test-key")
			cfg.BaseURL = server.URL
			client := openai.NewClientWithConfig(cfg)

			result, err := chatStream(t.Context(), nil, client, "m1", "test",
				chatArgs{}, 128000, 4096)
			if err != nil {
				t.Fatalf("chatStream: %v", err)
			}
			got, ok := result.(map[string]any)
			if !ok {
				t.Fatalf("result = %#v, want map", result)
			}
			if got["reasoning"] != "The user asked" {
				t.Fatalf("reasoning = %q, want %q", got["reasoning"], "The user asked")
			}
			if got["content"] != "Sure!" {
				t.Fatalf("content = %q, want %q", got["content"], "Sure!")
			}
		})
	}
}

// newSSEChatServer serves an OpenAI-compatible SSE chat stream with the
// given JSON chunk payloads, terminated by [DONE].
func newSSEChatServer(t *testing.T, chunks []string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			http.Error(w, "unexpected path: "+r.URL.Path, http.StatusNotFound)
			return
		}
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flusher", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, chunk := range chunks {
			if _, err := fmt.Fprintf(w, "data: %s\n\n", chunk); err != nil {
				return
			}
			flusher.Flush()
		}
		_, _ = fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
	}))
}

func TestResultJSONForwardsCachedTokenDetails(t *testing.T) {
	usage := openai.Usage{
		PromptTokens:     900,
		CompletionTokens: 30,
		TotalTokens:      930,
		PromptTokensDetails: &openai.PromptTokensDetails{
			CachedTokens: 800,
		},
	}
	result, err := resultJSON("deepseek", "deepseek-chat", 128000,
		"ok", "", nil, usage, true)
	if err != nil {
		t.Fatalf("resultJSON: %v", err)
	}
	got, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v, want map", result)
	}
	u, ok := got["usage"].(map[string]any)
	if !ok {
		t.Fatalf("usage missing: %#v", got)
	}
	details, ok := u["prompt_tokens_details"].(map[string]any)
	if !ok {
		t.Fatalf("prompt_tokens_details missing: %#v", u)
	}
	if details["cached_tokens"] != 800 {
		t.Fatalf("cached_tokens = %v, want 800", details["cached_tokens"])
	}

	// Without a details breakdown the field is omitted entirely (WIRE.md:
	// missing fields are omitted, never null).
	plain, err := resultJSON("deepseek", "deepseek-chat", 128000,
		"ok", "", nil, openai.Usage{PromptTokens: 10, TotalTokens: 10}, true)
	if err != nil {
		t.Fatalf("resultJSON plain: %v", err)
	}
	u2 := plain.(map[string]any)["usage"].(map[string]any)
	if _, present := u2["prompt_tokens_details"]; present {
		t.Fatalf("prompt_tokens_details should be omitted without details: %#v", u2)
	}
}
