package main

import (
	"encoding/json"
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
