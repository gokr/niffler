package main

import "testing"

// contextWindow: NIF_OPENAI_CONTEXT wins, then the tiny built-in table
// (case-insensitive), then the conservative default.
func TestContextWindow(t *testing.T) {
	if c := contextWindow("no-such-model-xyz"); c != defaultContext {
		t.Errorf("unknown model: got %d, want default %d", c, defaultContext)
	}
	if c := contextWindow("DeepSeek-Chat"); c <= 0 || c == defaultContext {
		t.Errorf("built-in table lookup should hit (case-insensitive), got %d", c)
	}
	if c := contextWindow("deepseek-reasoner"); c != 1000000 {
		t.Errorf("deepseek-reasoner: got %d, want 1000000", c)
	}
}

func TestContextWindowEnvOverride(t *testing.T) {
	t.Setenv("NIF_OPENAI_CONTEXT", "64000")
	defer t.Setenv("NIF_OPENAI_CONTEXT", "")
	if c := contextWindow("anything"); c != 64000 {
		t.Errorf("env override: got %d, want 64000", c)
	}
}
