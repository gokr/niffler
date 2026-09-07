package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestValidateName(t *testing.T) {
	for _, name := range []string{"fixture", "github-mcp", "a1"} {
		if err := validateName(name); err != nil {
			t.Errorf("validateName(%q) = %v, want nil", name, err)
		}
	}
	for _, name := range []string{"", "-x", "x-", "A", "1x", "x--y", "x_y", "with space", "way-too-long-name-exceeding-thirty-two"} {
		if err := validateName(name); err == nil {
			t.Errorf("validateName(%q) accepted an invalid name", name)
		}
	}
}

func contract(t *testing.T, cfg *serverConfig) []string {
	t.Helper()
	names, err := contractNames(cfg)
	if err != nil {
		t.Fatalf("contractNames: %v", err)
	}
	return names
}

func TestContractNamesReservedHelpers(t *testing.T) {
	cfg := &serverConfig{Name: "fixture", Tools: []cachedTool{{Name: "echo", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	names := contract(t, cfg)
	for _, want := range []string{"mcp_fixture_echo", "mcp_fixture_resources", "mcp_fixture_bridge_status", "mcp_fixture_prompt"} {
		if !contains(names, want) {
			t.Errorf("missing %q in %v", want, names)
		}
	}
}

func TestContractNamesCollisionWithReservedHelper(t *testing.T) {
	cfg := &serverConfig{Name: "fixture", Tools: []cachedTool{{Name: "resources", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	if _, err := contractNames(cfg); err == nil {
		t.Error("a server tool colliding with the generated resources helper must be rejected")
	}
}

func TestContractNamesDuplicateTools(t *testing.T) {
	schema := json.RawMessage(`{"type":"object"}`)
	cfg := &serverConfig{Name: "fixture", Tools: []cachedTool{{Name: "echo", InputSchema: schema}, {Name: "ECHO", InputSchema: schema}}}
	if _, err := contractNames(cfg); err == nil {
		t.Error("case-insensitive duplicate tool names must be rejected")
	}
}

func TestContractNamesInvalidToolSchema(t *testing.T) {
	cfg := &serverConfig{Name: "fixture", Tools: []cachedTool{{Name: "echo", InputSchema: json.RawMessage(`{"type":"string"}`)}}}
	if _, err := contractNames(cfg); err == nil {
		t.Error("non-object inputSchema must be rejected")
	}
}

func TestContractNamesPrompts(t *testing.T) {
	cfg := &serverConfig{Name: "fixture", Prompts: []cachedPrompt{{
		Name: "greet", Arguments: []cachedPromptArg{{Name: "name", Required: true}},
	}}}
	names := contract(t, cfg)
	if !contains(names, "mcp_fixture_prompt_greet") {
		t.Errorf("prompt helper tool missing: %v", names)
	}
	bad := &serverConfig{Name: "fixture", Prompts: []cachedPrompt{{
		Name: "greet", Arguments: []cachedPromptArg{{Name: "name"}, {Name: "name"}},
	}}}
	if _, err := contractNames(bad); err == nil {
		t.Error("duplicate prompt arguments must be rejected")
	}
}

func TestCappedBuffer(t *testing.T) {
	b := cappedBuffer{limit: 8}
	n, err := b.Write([]byte("1234567890"))
	if n != 10 || err != nil {
		t.Fatalf("Write must accept the full input: %d %v", n, err)
	}
	if b.String() != "12345678" || !b.overflow {
		t.Errorf("buffer must keep the first limit bytes and set overflow: %q %v", b.String(), b.overflow)
	}
}

func TestRedactConfig(t *testing.T) {
	cfg := &serverConfig{Env: map[string]string{"TOKEN": "s3cr3t"}, Headers: map[string]string{"Authorization": "Bearer x"}}
	out := redactConfigText(cfg, "failed with s3cr3t and Bearer x")
	if strings.Contains(out, "s3cr3t") || strings.Contains(out, "Bearer x") {
		t.Errorf("probe diagnostics leaked configured secrets: %q", out)
	}
}
