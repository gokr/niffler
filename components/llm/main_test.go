package main

import "testing"

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
