// Shared shapes between the mcp manager and the mcp-bridge. The two are
// separate Go modules (per-component go.mod), so the small config type and
// naming helpers are duplicated deliberately — keep them in sync. A shared
// internal module would work but is not worth the replace-graph complexity
// for ~80 lines.
package main

import (
	"encoding/json"
	"strings"
)

const kindMCP = "mcp"

// serverConfig is the stored record (kind "mcp", id = sanitized server
// name). Mirrors the bridge's type exactly.
type serverConfig struct {
	Name        string            `json:"name"`
	Type        string            `json:"type"` // stdio (default) | http | sse
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

// cachedTool is one MCP tool as last seen from the server (the bridge
// refreshes this list when the server's contract drifts).
type cachedTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"inputSchema,omitempty"`
}

// cachedPrompt is one MCP prompt template cached by the bridge (the bridge
// owns this list; the manager only round-trips it when editing records).
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

// sanitizeComponent mirrors sdk/subjects.nim's sanitizeSessionId: catalog
// component names are NATS subject tokens.
func sanitizeComponent(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

// sanitizeTool lowers and flattens a name into the niffler tool convention
// (lowercase underscores).
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
