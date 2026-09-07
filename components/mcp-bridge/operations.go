package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	sdk "niffler.dev/sdk"
)

const inlineLimit = 64 * 1024
const maxPages = 128

// pageAll enforces progress and a finite page budget against buggy servers.
func pageAll[T any](ctx context.Context, fetch func(context.Context, string) ([]T, string, error)) ([]T, error) {
	out := []T{}
	cursor := ""
	seen := map[string]bool{}
	for range maxPages {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		items, next, err := fetch(ctx, cursor)
		if err != nil {
			return nil, err
		}
		out = append(out, items...)
		if next == "" {
			return out, nil
		}
		if seen[next] {
			return nil, errors.New("MCP pagination cursor repeated")
		}
		seen[next] = true
		cursor = next
	}
	return nil, errors.New("MCP listing exceeds page limit")
}
func listContract(ctx context.Context, cs *mcp.ClientSession) ([]cachedTool, []cachedPrompt, error) {
	tools := []cachedTool{}
	prompts := []cachedPrompt{}
	caps := cs.InitializeResult().Capabilities
	if caps.Tools != nil {
		listed, err := pageAll(ctx, func(ctx context.Context, cursor string) ([]*mcp.Tool, string, error) {
			r, e := cs.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
			if e != nil {
				return nil, "", e
			}
			return r.Tools, r.NextCursor, nil
		})
		if err != nil {
			return nil, nil, fmt.Errorf("tools/list: %w", err)
		}
		for _, t := range listed {
			if t == nil {
				return nil, nil, errors.New("null MCP tool")
			}
			raw, err := json.Marshal(t.InputSchema)
			if err != nil {
				return nil, nil, err
			}
			tools = append(tools, cachedTool{t.Name, t.Description, raw})
		}
	}
	if caps.Prompts != nil {
		listed, err := pageAll(ctx, func(ctx context.Context, cursor string) ([]*mcp.Prompt, string, error) {
			r, e := cs.ListPrompts(ctx, &mcp.ListPromptsParams{Cursor: cursor})
			if e != nil {
				return nil, "", e
			}
			return r.Prompts, r.NextCursor, nil
		})
		if err != nil {
			return nil, nil, fmt.Errorf("prompts/list: %w", err)
		}
		for _, p := range listed {
			if p == nil {
				return nil, nil, errors.New("null MCP prompt")
			}
			cp := cachedPrompt{Name: p.Name, Title: p.Title, Description: p.Description}
			for _, a := range p.Arguments {
				if a == nil {
					return nil, nil, errors.New("null prompt argument")
				}
				cp.Arguments = append(cp.Arguments, cachedPromptArg{a.Name, a.Description, a.Required})
			}
			prompts = append(prompts, cp)
		}
	}
	sort.Slice(tools, func(i, j int) bool { return tools[i].Name < tools[j].Name })
	sort.Slice(prompts, func(i, j int) bool { return prompts[i].Name < prompts[j].Name })
	raw, err := json.Marshal([]any{tools, prompts})
	if err != nil {
		return nil, nil, err
	}
	if len(raw) > 512*1024 {
		return nil, nil, errors.New("MCP contract exceeds 512 KiB")
	}
	return tools, prompts, nil
}

// projectResult follows WIRE's text projection: the text field must describe
// everything useful to the model, not silently hide structured/non-text data.
func projectResult(res *mcp.CallToolResult) any {
	texts := []string{}
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			texts = append(texts, tc.Text)
		} else {
			raw, _ := json.Marshal(c)
			texts = append(texts, string(raw))
		}
	}
	if res.StructuredContent != nil {
		raw, _ := json.Marshal(res.StructuredContent)
		texts = append(texts, "Structured result: "+string(raw))
	}
	return map[string]any{"text": strings.Join(texts, "\n"), "structured": res.StructuredContent, "content": res.Content, "isError": res.IsError}
}
func truncateUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// bound retains full results in a private local JSON file and sends only a
// preview/reference over NATS. The core transcript receives the same pointer.
func bound(value any) (any, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(raw) <= inlineLimit {
		return value, nil
	}
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	dir, err := filepath.Abs(filepath.Join(root, "var", "mcp-results"))
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	f, err := os.CreateTemp(dir, "result-*.json")
	if err != nil {
		return nil, err
	}
	name := f.Name()
	if _, err = f.Write(raw); err != nil {
		f.Close()
		os.Remove(name)
		return nil, err
	}
	if err = f.Close(); err != nil {
		os.Remove(name)
		return nil, err
	}
	preview := string(raw)
	if obj, ok := value.(map[string]any); ok {
		if text, ok := obj["text"].(string); ok {
			preview = text
		}
	}
	text := truncateUTF8(preview, 16*1024) + fmt.Sprintf("\n[Full MCP result: %d bytes saved to %s; use read to inspect the JSON file.]", len(raw), name)
	return map[string]any{"text": text, "spill": map[string]any{"path": name, "bytes": len(raw)}, "truncated": true}, nil
}
func (b *bridge) callTool(ctx context.Context, tool string, args json.RawMessage) (any, error) {
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		b.markErr(err)
		return nil, fmt.Errorf("MCP tool %q: %w", tool, err)
	}
	result, err := bound(projectResult(res))
	if err != nil {
		return nil, err
	}
	if res.IsError {
		obj := result.(map[string]any)
		text, _ := obj["text"].(string)
		if text == "" {
			text = "MCP tool reported an error"
		}
		return nil, errors.New(text)
	}
	return result, nil
}
func (b *bridge) callPrompt(ctx context.Context, prompt string, args map[string]string) (any, error) {
	var template *cachedPrompt
	for i := range b.cfg.Prompts {
		if b.cfg.Prompts[i].Name == prompt {
			template = &b.cfg.Prompts[i]
			break
		}
	}
	if template == nil {
		return nil, errors.New("unknown cached prompt")
	}
	known := map[string]bool{}
	for _, a := range template.Arguments {
		known[a.Name] = true
		if a.Required {
			if _, ok := args[a.Name]; !ok {
				return nil, fmt.Errorf("required prompt argument: %s", a.Name)
			}
		}
	}
	for name := range args {
		if !known[name] {
			return nil, fmt.Errorf("unknown prompt argument: %s", name)
		}
	}
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.GetPrompt(ctx, &mcp.GetPromptParams{Name: prompt, Arguments: args})
	if err != nil {
		return nil, err
	}
	texts := []string{}
	for _, msg := range res.Messages {
		if msg == nil {
			return nil, errors.New("null MCP prompt message")
		}
		text := ""
		if tc, ok := msg.Content.(*mcp.TextContent); ok {
			text = tc.Text
		} else {
			raw, _ := json.Marshal(msg.Content)
			text = string(raw)
		}
		texts = append(texts, fmt.Sprintf("[%s]\n%s", msg.Role, text))
	}
	text := strings.Join(texts, "\n\n")
	// Generic slash-result convention: explicit user invocation appends this
	// text as a user message, never as system instructions or assistant history.
	out := map[string]any{"prompt": prompt, "description": res.Description, "messages": res.Messages, "text": text}
	bounded, err := bound(out)
	if err != nil {
		return nil, err
	}
	result := bounded.(map[string]any)
	result["userMessage"] = result["text"]
	if text == "" {
		return nil, errors.New("MCP prompt returned no content")
	}
	return result, nil
}
func (b *bridge) resources(ctx context.Context, args json.RawMessage) (any, error) {
	var req struct {
		Op  string `json:"op"`
		URI string `json:"uri"`
	}
	if err := json.Unmarshal(args, &req); err != nil {
		return nil, err
	}
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	if cs.InitializeResult().Capabilities.Resources == nil {
		return nil, errors.New("server does not support resources")
	}
	switch req.Op {
	case "", "list":
		items, err := pageAll(ctx, func(ctx context.Context, cursor string) ([]*mcp.Resource, string, error) {
			r, e := cs.ListResources(ctx, &mcp.ListResourcesParams{Cursor: cursor})
			if e != nil {
				return nil, "", e
			}
			return r.Resources, r.NextCursor, nil
		})
		if err != nil {
			return nil, err
		}
		return bound(map[string]any{"resources": items, "count": len(items)})
	case "templates":
		items, err := pageAll(ctx, func(ctx context.Context, cursor string) ([]*mcp.ResourceTemplate, string, error) {
			r, e := cs.ListResourceTemplates(ctx, &mcp.ListResourceTemplatesParams{Cursor: cursor})
			if e != nil {
				return nil, "", e
			}
			return r.ResourceTemplates, r.NextCursor, nil
		})
		if err != nil {
			return nil, err
		}
		return bound(map[string]any{"templates": items, "count": len(items)})
	case "read":
		if strings.TrimSpace(req.URI) == "" {
			return nil, errors.New("uri is required")
		}
		res, err := cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: req.URI})
		if err != nil {
			return nil, err
		}
		return bound(map[string]any{"contents": res.Contents})
	default:
		return nil, errors.New("op must be list, templates or read")
	}
}
func xHarness(cfg *serverConfig, hidden bool) map[string]any {
	xh := map[string]any{"sessionId": true, "timeoutMs": cfg.timeout().Milliseconds()}
	if hidden {
		xh["hidden"] = true
	} else if cfg.Expose != "direct" {
		xh["onDemand"] = true
	}
	if cfg.Approval == "always" {
		xh["approval"] = "always"
	}
	if cfg.Effect == "read" {
		xh["effect"] = "read"
	}
	return xh
}
func (b *bridge) register() error {
	if _, err := contractNames(b.cfg); err != nil {
		return err
	}
	add := func(name string, schema map[string]any, handler func(context.Context, json.RawMessage) (any, error)) {
		wrapped := func(_ *sdk.Component, args json.RawMessage) (any, error) {
			ctx, clean, end, err := b.begin(name, args)
			if err != nil {
				return nil, err
			}
			defer end()
			return handler(ctx, clean)
		}
		if b.cfg.Concurrency == "serial" {
			b.comp.Tool(name, schema, wrapped)
		} else {
			b.comp.ToolConcurrent(name, schema, wrapped)
		}
	}
	for _, ct := range b.cfg.Tools {
		schema := map[string]any{}
		if err := json.Unmarshal(ct.InputSchema, &schema); err != nil {
			return err
		}
		schema["x-harness"] = xHarness(b.cfg, false)
		schema["description"] = fmt.Sprintf("[mcp:%s] %s", b.cfg.Name, ct.Description)
		add(prefixedToolName(b.cfg.Name, ct.Name), schema, func(ctx context.Context, args json.RawMessage) (any, error) { return b.callTool(ctx, ct.Name, args) })
	}
	resourceXH := xHarness(b.cfg, false)
	resourceXH["effect"] = "read"
	add(prefixedToolName(b.cfg.Name, "resources"), map[string]any{"type": "object", "description": "List/read MCP resources or list URI templates. Large results spill to a local JSON file readable with read.", "properties": map[string]any{"op": map[string]any{"type": "string", "enum": []string{"list", "templates", "read"}}, "uri": map[string]any{"type": "string"}}, "x-harness": resourceXH}, b.resources)
	add(prefixedToolName(b.cfg.Name, "prompt"), map[string]any{"type": "object", "description": "Render a named MCP prompt (UI helper).", "properties": map[string]any{"name": map[string]any{"type": "string"}, "arguments": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "string"}}}, "required": []string{"name"}, "x-harness": xHarness(b.cfg, true)}, func(ctx context.Context, raw json.RawMessage) (any, error) {
		var req struct {
			Name      string            `json:"name"`
			Arguments map[string]string `json:"arguments"`
		}
		if err := json.Unmarshal(raw, &req); err != nil {
			return nil, err
		}
		return b.callPrompt(ctx, req.Name, req.Arguments)
	})
	for _, p := range b.cfg.Prompts {
		props := map[string]any{}
		required := []string{}
		params := []sdk.SlashParam{}
		for _, a := range p.Arguments {
			props[a.Name] = map[string]any{"type": "string", "description": a.Description}
			if a.Required {
				required = append(required, a.Name)
			}
			params = append(params, sdk.SlashParam{Name: a.Name, Kind: "string", Description: a.Description})
		}
		name := prefixedToolName(b.cfg.Name, "prompt_"+sanitizeTool(p.Name))
		add(name, map[string]any{"type": "object", "description": p.Description, "properties": props, "required": required, "additionalProperties": false, "x-harness": xHarness(b.cfg, true)}, func(ctx context.Context, raw json.RawMessage) (any, error) {
			var args map[string]string
			if err := json.Unmarshal(raw, &args); err != nil {
				return nil, err
			}
			return b.callPrompt(ctx, p.Name, args)
		})
		b.comp.Slash(sdk.SlashCommand{Name: "mcp-" + b.cfg.Name + "-" + sanitizeTool(p.Name), Description: p.Description, Tool: name, Params: params})
	}
	b.comp.ToolConcurrent(prefixedToolName(b.cfg.Name, "bridge_status"), map[string]any{"type": "object", "description": "MCP bridge status/refresh (manager helper).", "properties": map[string]any{"op": map[string]any{"type": "string", "enum": []string{"status", "refresh"}}}, "x-harness": map[string]any{"hidden": true}}, b.status)
	return nil
}
