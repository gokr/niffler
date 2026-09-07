// Config and namespace contract shared (duplicated) with mcp-bridge/types.go.
// Keep these files identical; the components remain independent Go modules.
package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

const kindMCP = "mcp"

type serverConfig struct {
	Name        string            `json:"name"`
	Type        string            `json:"type"`
	Command     string            `json:"command,omitempty"`
	Args        []string          `json:"args,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	URL         string            `json:"url,omitempty"`
	Headers     map[string]string `json:"headers,omitempty"`
	Cwd         string            `json:"cwd,omitempty"`
	Enabled     *bool             `json:"enabled,omitempty"`
	Approval    string            `json:"approval,omitempty"`
	Expose      string            `json:"expose,omitempty"`
	Effect      string            `json:"effect,omitempty"`
	TimeoutMs   int               `json:"timeoutMs,omitempty"`
	IdleMs      int               `json:"idleMs,omitempty"`
	Concurrency string            `json:"concurrency,omitempty"`
	Tools       []cachedTool      `json:"tools,omitempty"`
	Prompts     []cachedPrompt    `json:"prompts,omitempty"`
}
type cachedTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"inputSchema,omitempty"`
}
type cachedPrompt struct {
	Name        string            `json:"name"`
	Title       string            `json:"title,omitempty"`
	Description string            `json:"description,omitempty"`
	Arguments   []cachedPromptArg `json:"arguments,omitempty"`
}
type cachedPromptArg struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Required    bool   `json:"required,omitempty"`
}

var serverNamePattern = regexp.MustCompile(`^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`)
var paramNamePattern = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_-]*$`)

func validateName(name string) error {
	if len(name) > 32 || !serverNamePattern.MatchString(name) {
		return fmt.Errorf("name must be 1–32 lowercase letters/digits with single separating hyphens, starting with a letter")
	}
	return nil
}
func sanitizeTool(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + 'a' - 'A')
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}
func prefixedToolName(server, tool string) string {
	return "mcp_" + sanitizeTool(server) + "_" + sanitizeTool(tool)
}

// contractNames validates the entire namespace, including generated helpers.
// Names cannot silently alias a different MCP operation or exceed LLM limits.
func contractNames(cfg *serverConfig) ([]string, error) {
	if err := validateName(cfg.Name); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var names []string
	add := func(remote string) error {
		name := prefixedToolName(cfg.Name, remote)
		if remote == "" || len(name) > 64 {
			return fmt.Errorf("unusable/overlong MCP name %q", remote)
		}
		if seen[name] {
			return fmt.Errorf("MCP namespace collision: %s", name)
		}
		seen[name] = true
		names = append(names, name)
		return nil
	}
	for _, name := range []string{"resources", "bridge_status", "prompt"} {
		if err := add(name); err != nil {
			return nil, err
		}
	}
	for _, t := range cfg.Tools {
		if err := add(t.Name); err != nil {
			return nil, err
		}
		var schema map[string]any
		if err := json.Unmarshal(t.InputSchema, &schema); err != nil || schema == nil || schema["type"] != "object" {
			return nil, fmt.Errorf("tool %q inputSchema must be an object schema", t.Name)
		}
	}
	if len(cfg.Prompts) > 32 {
		return nil, fmt.Errorf("at most 32 prompts per server are supported")
	}
	for _, p := range cfg.Prompts {
		if p.Name == "" {
			return nil, fmt.Errorf("empty prompt name")
		}
		if err := add("prompt_" + sanitizeTool(p.Name)); err != nil {
			return nil, err
		}
		if len(p.Arguments) > 16 {
			return nil, fmt.Errorf("prompt %q has more than 16 arguments", p.Name)
		}
		args := map[string]bool{}
		for _, a := range p.Arguments {
			if !paramNamePattern.MatchString(a.Name) || args[a.Name] || a.Name == "__session" {
				return nil, fmt.Errorf("prompt %q has invalid/duplicate argument %q", p.Name, a.Name)
			}
			args[a.Name] = true
		}
	}
	return names, nil
}
