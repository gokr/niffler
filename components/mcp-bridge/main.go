// mcp-bridge — one external MCP server, one bus component.
//
// Spawned by the mcp manager (core.spawn with args, one supervised process
// per configured server). The bridge reads its server config from the store
// (kind "mcp", id = server name), registers the server's cached tools as
// normal catalog tools (mcp_<server>_<tool>, x-harness.onDemand by default)
// and proxies calls through the official MCP Go SDK
// (github.com/modelcontextprotocol/go-sdk).
//
// Sessions are lazy: the MCP subprocess (stdio) or HTTP/SSE session is
// established on the first tool call and idles out after idleMs. On the
// first connect the bridge re-lists the server's tools; if the tool contract
// drifted from the cached record it persists the fresh list (best effort)
// and exits 3 so the supervisor restarts it announcing the current truth —
// catalog and execution never disagree for long.
//
// Probe mode (manager-side validation):
//
//	mcp-bridge --server <name> --probe
//
// connects once, prints {"ok":true,"tools":[...]} on stdout and exits —
// no bus involvement. The manager uses it for mcp_add/mcp_edit validation.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	sdk "niffler.dev/sdk"
)

const (
	kindMCP         = "mcp"
	bridgeVersion   = "0.1.0"
	defaultIdleMs   = 300_000 // close an unused MCP session after 5 minutes
	defaultProbeTo  = 30_000
	driftExitCode   = 3 // supervisor restarts on-failure; announces the fresh contract
	probeTimeoutEnv = "NIF_MCP_PROBE_TIMEOUT_MS"
)

// serverConfig is the stored record (kind "mcp"). The manager owns every
// field except tools and prompts: the bridge rewrites only those cached
// listings when it detects drift.
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
	Approval    string            `json:"approval,omitempty"` // "always" gates every tool
	Expose      string            `json:"expose,omitempty"`   // "ondemand" (default) | "direct"
	Effect      string            `json:"effect,omitempty"`   // "read" hint; default write
	TimeoutMs   int               `json:"timeoutMs,omitempty"`
	IdleMs      int               `json:"idleMs,omitempty"`
	Concurrency string            `json:"concurrency,omitempty"` // parallel (default) | serial
	Tools       []cachedTool      `json:"tools,omitempty"`
	Prompts     []cachedPrompt    `json:"prompts,omitempty"`
}

func (c *serverConfig) enabled() bool {
	return c.Enabled == nil || *c.Enabled
}

func (c *serverConfig) transport() string {
	if c.Type == "" {
		return "stdio"
	}
	return c.Type
}

func (c *serverConfig) parallel() bool {
	return c.Concurrency != "serial"
}

func (c *serverConfig) idle() time.Duration {
	if c.IdleMs <= 0 {
		return defaultIdleMs
	}
	return time.Duration(c.IdleMs) * time.Millisecond
}

// cachedTool is one MCP tool as last seen from the server.
type cachedTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"inputSchema,omitempty"`
}

// cachedPrompt is one MCP prompt template as last seen from the server —
// the bridge surfaces these as slash commands for interactive UIs.
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

// ---------------------------------------------------------------- naming

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
// (lowercase underscores). Empty result means the name was unusable.
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

// ---------------------------------------------------------------- session

// bridge holds the lazy MCP session for one server.
type bridge struct {
	cfg        *serverConfig
	comp       *sdk.Component // nil in probe mode (no bus involvement)
	probe      bool
	mu         sync.Mutex // guards session lifecycle (connect is serialized)
	cs         *mcp.ClientSession
	sessCtx    context.Context // session lifetime — never a per-call context
	sessCancel context.CancelFunc
	started    time.Time
	lastUsed   time.Time
	lastErr    string
	drifted    bool
}

var errDisabled = errors.New("mcp server is disabled")

func (b *bridge) markErr(err error) {
	b.mu.Lock()
	b.lastErr = err.Error()
	b.mu.Unlock()
}

// ensure returns a live session, connecting lazily on first use. The lock is
// held across the whole connect so concurrent first calls serialize instead
// of stampeding; established sessions are shared. A session that errored on
// its last use is torn down and rebuilt here.
func (b *bridge) ensure(ctx context.Context) (*mcp.ClientSession, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cfg.Enabled != nil && !*b.cfg.Enabled {
		return nil, errDisabled
	}
	if b.cs != nil && b.sessCtx.Err() == nil {
		b.lastUsed = time.Now()
		return b.cs, nil
	}
	if b.cs != nil { // context canceled underneath: rebuild
		_ = b.cs.Close()
		b.cs = nil
	}
	if err := b.connectLocked(); err != nil {
		return nil, err
	}
	b.lastUsed = time.Now()
	return b.cs, nil
}

func (b *bridge) connectLocked() error {
	// The session (and any stdio subprocess) lives on its own context: a
	// per-call timeout must abandon the RPC, not kill the MCP server. The
	// session context is canceled only by dropSession (error/idle/refresh).
	b.sessCtx, b.sessCancel = context.WithCancel(context.Background())
	transport, err := b.transportLocked(b.sessCtx)
	if err != nil {
		b.sessCancel()
		b.lastErr = err.Error()
		return err
	}
	client := mcp.NewClient(&mcp.Implementation{
		Name: "niffler-mcp", Version: bridgeVersion,
	}, &mcp.ClientOptions{
		// Server-initiated contract changes take effect immediately: list,
		// persist, restart. Without this the stale cached listing would only
		// be corrected on the next fresh session.
		ToolListChangedHandler: func(ctx context.Context, _ *mcp.ToolListChangedRequest) {
			b.handleToolListChanged(ctx)
		},
		PromptListChangedHandler: func(ctx context.Context, _ *mcp.PromptListChangedRequest) {
			b.handleToolListChanged(ctx) // same flow: re-list, persist, restart
		},
	})
	cs, err := client.Connect(b.sessCtx, transport, nil)
	if err != nil {
		b.sessCancel()
		b.lastErr = err.Error()
		return fmt.Errorf("mcp connect: %w", err)
	}
	b.cs = cs
	b.started = time.Now()
	b.lastErr = ""
	// Fresh session: the server's real tool contract may have drifted from
	// the cached record this process announced at boot. Detect, persist,
	// restart. The current call still completes on the live session.
	if err := b.checkDriftLocked(b.sessCtx); err != nil {
		b.lastErr = err.Error() // tool listing failed; keep the session anyway
	}
	return nil
}

// handleToolListChanged runs on the SDK's reader goroutine when the server
// pushes notifications/tools/list_changed.
func (b *bridge) handleToolListChanged(ctx context.Context) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cs == nil {
		return
	}
	if err := b.checkDriftLocked(ctx); err != nil {
		b.lastErr = err.Error()
	}
}

// transportLocked builds the MCP transport per configured type. stdio
// subprocesses are owned by the SDK transport: closing the session closes
// stdin and (after a grace period) SIGTERMs the process.
func (b *bridge) transportLocked(ctx context.Context) (mcp.Transport, error) {
	switch b.cfg.transport() {
	case "stdio":
		if strings.TrimSpace(b.cfg.Command) == "" {
			return nil, errors.New("stdio server needs a command")
		}
		cmd := exec.CommandContext(ctx, b.cfg.Command, b.cfg.Args...)
		cmd.Env = mergedEnv(b.cfg.Env)
		if b.cfg.Cwd != "" {
			cmd.Dir = b.cfg.Cwd
		}
		return &mcp.CommandTransport{Command: cmd}, nil
	case "http":
		if b.cfg.URL == "" {
			return nil, errors.New("http server needs a url")
		}
		t := &mcp.StreamableClientTransport{Endpoint: b.cfg.URL}
		if len(b.cfg.Headers) > 0 {
			t.HTTPClient = &http.Client{Transport: headerTransport{base: http.DefaultTransport, headers: b.cfg.Headers}}
		}
		return t, nil
	case "sse":
		if b.cfg.URL == "" {
			return nil, errors.New("sse server needs a url")
		}
		t := &mcp.SSEClientTransport{Endpoint: b.cfg.URL}
		if len(b.cfg.Headers) > 0 {
			t.HTTPClient = &http.Client{Transport: headerTransport{base: http.DefaultTransport, headers: b.cfg.Headers}}
		}
		return t, nil
	default:
		return nil, fmt.Errorf("unknown transport type %q (stdio|http|sse)", b.cfg.Type)
	}
}

// mergedEnv inherits the bridge environment and layers the record's env on
// top, so MCP servers see PATH/NIF_NATS_URL plus their configured secrets.
func mergedEnv(overrides map[string]string) []string {
	env := os.Environ()
	for k, v := range overrides {
		env = append(env, k+"="+v)
	}
	return env
}

// headerTransport injects the record's static headers into every request
// (bearer tokens etc. for http/sse servers).
type headerTransport struct {
	base    http.RoundTripper
	headers map[string]string
}

func (h headerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	r := req.Clone(req.Context())
	for k, v := range h.headers {
		r.Header.Set(k, v)
	}
	return h.base.RoundTrip(r)
}

// ---------------------------------------------------------------- tools

// listAllTools paginates tools/list to the end.
func listAllTools(ctx context.Context, cs *mcp.ClientSession) ([]*mcp.Tool, error) {
	var out []*mcp.Tool
	cursor := ""
	for {
		res, err := cs.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		out = append(out, res.Tools...)
		if res.NextCursor == "" {
			return out, nil
		}
		cursor = res.NextCursor
	}
}

// cacheTools converts a server listing into the record's cached form.
func cacheTools(tools []*mcp.Tool) []cachedTool {
	out := make([]cachedTool, 0, len(tools))
	for _, t := range tools {
		ct := cachedTool{Name: t.Name, Description: t.Description}
		if t.InputSchema != nil {
			if raw, err := json.Marshal(t.InputSchema); err == nil {
				ct.InputSchema = raw
			}
		}
		out = append(out, ct)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// toolsChanged compares two cached listings independent of order.
func toolsChanged(a, b []cachedTool) bool {
	if len(a) != len(b) {
		return true
	}
	ra, _ := json.Marshal(a)
	rb, _ := json.Marshal(b)
	return string(ra) != string(rb)
}

// cachePrompts converts a server listing into the record's cached form.
func cachePrompts(prompts []*mcp.Prompt) []cachedPrompt {
	out := make([]cachedPrompt, 0, len(prompts))
	for _, p := range prompts {
		cp := cachedPrompt{Name: p.Name, Title: p.Title, Description: p.Description}
		for _, a := range p.Arguments {
			if a == nil || sanitizeTool(a.Name) == "" {
				continue
			}
			cp.Arguments = append(cp.Arguments, cachedPromptArg{
				Name: a.Name, Description: a.Description, Required: a.Required,
			})
		}
		out = append(out, cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// listAllPrompts paginates prompts/list. A server without prompt support
// yields (nil, err) — callers treat that as "no prompts", not a failure.
func listAllPrompts(ctx context.Context, cs *mcp.ClientSession) ([]*mcp.Prompt, error) {
	var out []*mcp.Prompt
	cursor := ""
	for {
		res, err := cs.ListPrompts(ctx, &mcp.ListPromptsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		out = append(out, res.Prompts...)
		if res.NextCursor == "" {
			return out, nil
		}
		cursor = res.NextCursor
	}
}

// checkDriftLocked re-lists the server's tools (and prompts, best effort)
// and, when the contract moved, persists the fresh lists (best effort,
// rev-retried) and schedules a restart so the announced catalog matches
// reality again. Probe mode skips both: it only fills cfg for the report.
func (b *bridge) checkDriftLocked(ctx context.Context) error {
	fresh, err := listAllTools(ctx, b.cs)
	if err != nil {
		return err
	}
	newList := cacheTools(fresh)
	// Prompts are optional: a server without prompt support (or an error
	// listing them) keeps the cached set — only a fresh successful listing
	// that differs from the cache signals drift.
	newPrompts := b.cfg.Prompts
	if listed, err := listAllPrompts(ctx, b.cs); err == nil {
		newPrompts = cachePrompts(listed)
	}
	if !toolsChanged(b.cfg.Tools, newList) && !toolsChangedPrompts(b.cfg.Prompts, newPrompts) {
		return nil
	}
	b.drifted = true
	b.cfg.Tools = newList
	b.cfg.Prompts = newPrompts
	if b.probe || b.comp == nil {
		return nil
	}
	sdkLog(b.comp, "mcp tool contract drifted — persisting and restarting", map[string]any{
		"server": b.cfg.Name, "cached": len(b.cfg.Tools), "fresh": len(newList),
	})
	// Persist the fresh listing into the store record. The manager may be
	// editing concurrently: retry the read-modify-write a few times, then
	// give up (the restart re-reads whatever is current).
	for attempt := 0; attempt < 3; attempt++ {
		item, err := b.comp.StoreGet(kindMCP, b.cfg.Name, 10*time.Second)
		if err != nil {
			break
		}
		var record serverConfig
		if err := json.Unmarshal(item.Value, &record); err != nil {
			break
		}
		record.Tools = newList
		record.Prompts = newPrompts
		if _, err := b.comp.StorePut(kindMCP, b.cfg.Name, record, item.Rev, 10*time.Second); err != nil {
			if errors.Is(err, sdk.ErrStoreConflict) {
				continue
			}
			break
		}
		break
	}
	// Exit after the current replies have had a moment to go out; the
	// supervisor's on-failure policy brings a fresh bridge up.
	go func() {
		time.Sleep(250 * time.Millisecond)
		os.Exit(driftExitCode)
	}()
	return nil
}

// toolsChangedPrompts compares two cached prompt listings independent of order.
func toolsChangedPrompts(a, b []cachedPrompt) bool {
	if len(a) != len(b) {
		return true
	}
	ra, _ := json.Marshal(a)
	rb, _ := json.Marshal(b)
	return string(ra) != string(rb)
}

// callPrompt renders one MCP prompt template through the lazy session.
func (b *bridge) callPrompt(prompt string, args json.RawMessage) (any, error) {
	ctx := context.Background()
	if b.cfg.TimeoutMs > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(b.cfg.TimeoutMs)*time.Millisecond)
		defer cancel()
	}
	var req struct {
		Arguments map[string]string `json:"arguments"`
	}
	_ = json.Unmarshal(args, &req)
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.GetPrompt(ctx, &mcp.GetPromptParams{Name: prompt, Arguments: req.Arguments})
	if err != nil {
		b.markErr(err)
		b.dropSession()
		return nil, fmt.Errorf("mcp prompt %q failed: %w", prompt, err)
	}
	b.touch()
	messages := make([]map[string]any, 0, len(res.Messages))
	for _, msg := range res.Messages {
		entry := map[string]any{"role": string(msg.Role)}
		if tc, ok := msg.Content.(*mcp.TextContent); ok {
			entry["text"] = tc.Text
		} else if raw, err := json.Marshal(msg.Content); err == nil {
			entry["content"] = json.RawMessage(raw)
		}
		messages = append(messages, entry)
	}
	return map[string]any{
		"prompt": prompt, "description": res.Description, "messages": messages,
	}, nil
}

// resourcesList/read serve the server's resource catalog through the lazy
// session. Readable resource text is capped: a huge file must not blow the
// conversation (the LLM can ask for it in pieces when chunked URIs exist).
const resourceTextCap = 64 * 1024

func (b *bridge) listResources(ctx context.Context) (any, error) {
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.ListResources(ctx, &mcp.ListResourcesParams{})
	if err != nil {
		b.markErr(err)
		return nil, fmt.Errorf("mcp resources/list failed: %w", err)
	}
	b.touch()
	items := make([]map[string]any, 0, len(res.Resources))
	for _, r := range res.Resources {
		if r == nil {
			continue
		}
		items = append(items, map[string]any{
			"uri": r.URI, "name": r.Name, "title": r.Title,
			"description": r.Description, "mimeType": r.MIMEType, "size": r.Size,
		})
	}
	return map[string]any{"resources": items, "count": len(items)}, nil
}

func (b *bridge) readResource(ctx context.Context, uri string) (any, error) {
	if strings.TrimSpace(uri) == "" {
		return nil, errors.New("uri is required for op=read")
	}
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: uri})
	if err != nil {
		b.markErr(err)
		return nil, fmt.Errorf("mcp resources/read failed: %w", err)
	}
	b.touch()
	contents := make([]map[string]any, 0, len(res.Contents))
	for _, c := range res.Contents {
		if c == nil {
			continue
		}
		entry := map[string]any{"uri": c.URI, "mimeType": c.MIMEType}
		if c.Text != "" {
			if len(c.Text) > resourceTextCap {
				entry["text"] = c.Text[:resourceTextCap]
				entry["truncated"] = true
			} else {
				entry["text"] = c.Text
			}
		} else if len(c.Blob) > 0 {
			entry["blob"] = base64.StdEncoding.EncodeToString(c.Blob)
		}
		contents = append(contents, entry)
	}
	return map[string]any{"contents": contents}, nil
}

// resourcesHandler backs the on-demand mcp_<server>_resources tool.
func (b *bridge) resourcesHandler(_ *sdk.Component, args json.RawMessage) (any, error) {
	var req struct {
		Op  string `json:"op"`
		URI string `json:"uri"`
	}
	_ = json.Unmarshal(args, &req)
	ctx := context.Background()
	if b.cfg.TimeoutMs > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(b.cfg.TimeoutMs)*time.Millisecond)
		defer cancel()
	}
	switch req.Op {
	case "", "list":
		return b.listResources(ctx)
	case "read":
		return b.readResource(ctx, req.URI)
	default:
		return nil, fmt.Errorf("op must be \"list\" or \"read\" (got %q)", req.Op)
	}
}

// promptHandler backs the hidden mcp_<server>_prompt tool that slash
// commands route to.
func (b *bridge) promptHandler(_ *sdk.Component, args json.RawMessage) (any, error) {
	var req struct {
		Name      string            `json:"name"`
		Arguments map[string]string `json:"arguments"`
	}
	if err := json.Unmarshal(args, &req); err != nil {
		return nil, fmt.Errorf("bad arguments: %w", err)
	}
	if req.Name == "" {
		return nil, errors.New("name is required")
	}
	return b.callPrompt(req.Name, args)
}

// callTool runs one MCP tool call through the lazy session.
func (b *bridge) callTool(tool string, args json.RawMessage) (any, error) {
	ctx := context.Background()
	if b.cfg.TimeoutMs > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(b.cfg.TimeoutMs)*time.Millisecond)
		defer cancel()
	}
	cs, err := b.ensure(ctx)
	if err != nil {
		return nil, err
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{
		Name:      tool,
		Arguments: json.RawMessage(args),
	})
	if err != nil {
		b.markErr(err)
		// A failed transport must not poison later calls: drop the session
		// so the next call reconnects.
		b.dropSession()
		return nil, fmt.Errorf("mcp tool %q failed: %w", tool, err)
	}
	b.touch()
	if res.IsError {
		return nil, errors.New(toolErrorText(res))
	}
	return projectResult(res), nil
}

func (b *bridge) touch() {
	b.mu.Lock()
	b.lastUsed = time.Now()
	b.mu.Unlock()
}

func (b *bridge) dropSession() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cs != nil {
		_ = b.cs.Close()
		b.cs = nil
	}
	if b.sessCancel != nil {
		b.sessCancel() // kills stdio subprocesses bound to the session context
		b.sessCancel = nil
	}
}

// toolErrorText flattens an MCP error result into one message.
func toolErrorText(res *mcp.CallToolResult) string {
	var texts []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok && tc.Text != "" {
			texts = append(texts, tc.Text)
		}
	}
	if len(texts) == 0 {
		return "mcp tool reported an error"
	}
	return strings.Join(texts, "\n")
}

// projectResult maps an MCP result onto the bus's plain-JSON convention:
// joined text under "text", structured output under "structured", and the
// raw content array whenever it carried anything beyond text.
func projectResult(res *mcp.CallToolResult) any {
	var texts []string
	extra := false
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			texts = append(texts, tc.Text)
		} else {
			extra = true
		}
	}
	out := map[string]any{"text": strings.Join(texts, "\n")}
	if res.StructuredContent != nil {
		out["structured"] = res.StructuredContent
	}
	if extra {
		raw, err := json.Marshal(res.Content)
		if err == nil {
			out["content"] = json.RawMessage(raw)
		}
	}
	return out
}

// registerTools declares the cached contract as bus tools.
func registerTools(comp *sdk.Component, cfg *serverConfig) (int, error) {
	server := cfg.Name
	serial := !cfg.parallel()
	registered := 0
	for _, ct := range cfg.Tools {
		name := prefixedToolName(server, ct.Name)
		if sanitizeTool(ct.Name) == "" {
			continue
		}
		schema, err := toolSchema(server, cfg, ct)
		if err != nil {
			return registered, err
		}
		tool := ct.Name
		call := func(_ *sdk.Component, args json.RawMessage) (any, error) {
			return bGlobal.callTool(tool, args)
		}
		if serial {
			comp.Tool(name, schema, call)
		} else {
			comp.ToolConcurrent(name, schema, call)
		}
		registered++
	}
	if registered == 0 {
		return 0, fmt.Errorf("server %q has no tools", server)
	}
	// Resources (on demand, LLM-visible): servers without resource support
	// surface a clean error on the first call — the tool itself is cheap and
	// keeps the contract uniform.
	comp.ToolConcurrent(prefixedToolName(server, "resources"), map[string]any{
		"type": "object",
		"description": fmt.Sprintf("[mcp:%s] List or read the server's MCP resources (exposed files/data). "+
			"op=list (default) returns the catalog; op=read with uri returns the content.", server),
		"properties": map[string]any{
			"op":  map[string]any{"type": "string", "enum": []string{"list", "read"}, "description": "list (default) or read"},
			"uri": map[string]any{"type": "string", "description": "resource URI (required for op=read)"},
		},
		"x-harness": resourcesXHarness(cfg),
	}, func(_ *sdk.Component, args json.RawMessage) (any, error) {
		return bGlobal.resourcesHandler(nil, args)
	})
	registered++
	return registered, nil
}

// resourcesXHarness builds the metadata block for the resources tool.
func resourcesXHarness(cfg *serverConfig) map[string]any {
	xh := map[string]any{}
	if cfg.Expose != "direct" {
		xh["onDemand"] = true
	}
	if cfg.Approval == "always" {
		xh["approval"] = "always"
	}
	if cfg.TimeoutMs > 0 {
		xh["timeoutMs"] = cfg.TimeoutMs
	}
	xh["effect"] = "read" // listing/reading resources never mutates
	return xh
}

// registerPrompts declares the cached prompt templates: one hidden tool
// that renders a prompt, plus one slash command per template for
// interactive UIs (docs/WIRE.md). Slash commands re-announce with the
// catalog on drift, so UIs pick changes up through ev.catalog.updated.
func registerPrompts(comp *sdk.Component, cfg *serverConfig) int {
	server := cfg.Name
	if len(cfg.Prompts) == 0 {
		return 0
	}
	toolName := prefixedToolName(server, "prompt")
	comp.Tool(toolName, map[string]any{
		"type":        "object",
		"description": fmt.Sprintf("Render an MCP prompt template from server %q (manager/UI-facing, hidden).", server),
		"properties": map[string]any{
			"name":      map[string]any{"type": "string", "description": "Prompt template name"},
			"arguments": map[string]any{"type": "object", "description": "Template arguments"},
		},
		"required":  []string{"name"},
		"x-harness": map[string]any{"hidden": true},
	}, func(_ *sdk.Component, args json.RawMessage) (any, error) {
		return bGlobal.promptHandler(nil, args)
	})
	count := 0
	for _, p := range cfg.Prompts {
		if sanitizeTool(p.Name) == "" {
			continue
		}
		cmdName := "mcp-" + sanitizeComponent(server) + "-" + sanitizeTool(p.Name)
		desc := p.Description
		if desc == "" {
			desc = p.Title
		}
		if desc == "" {
			desc = fmt.Sprintf("MCP prompt %q from server %s", p.Name, server)
		}
		params := make([]sdk.SlashParam, 0, len(p.Arguments))
		for _, a := range p.Arguments {
			params = append(params, sdk.SlashParam{
				Name: a.Name, Kind: "string",
				Description: a.Description,
			})
		}
		comp.Slash(sdk.SlashCommand{
			Name: cmdName, Description: desc, Tool: toolName, Params: params,
		})
		count++
	}
	return count
}

// toolSchema builds the catalog schema: the MCP input schema plus the
// x-harness exposure/approval/timeout metadata and a provenance description.
func toolSchema(server string, cfg *serverConfig, ct cachedTool) (map[string]any, error) {
	schema := map[string]any{"type": "object", "properties": map[string]any{}}
	if len(ct.InputSchema) > 0 {
		var parsed map[string]any
		if err := json.Unmarshal(ct.InputSchema, &parsed); err != nil {
			return nil, fmt.Errorf("tool %q has invalid inputSchema: %w", ct.Name, err)
		}
		for k, v := range parsed {
			if k == "x-harness" {
				continue // the server does not set our private metadata
			}
			schema[k] = v
		}
	}
	xh := map[string]any{}
	if cfg.Expose != "direct" {
		xh["onDemand"] = true
	}
	if cfg.Approval == "always" {
		xh["approval"] = "always"
	}
	if cfg.TimeoutMs > 0 {
		xh["timeoutMs"] = cfg.TimeoutMs
	}
	if cfg.Effect == "read" {
		xh["effect"] = "read"
	}
	if len(xh) > 0 {
		schema["x-harness"] = xh
	}
	desc := ct.Description
	if cfg.Expose != "direct" {
		desc = fmt.Sprintf("[mcp:%s] %s", server, desc)
	}
	schema["description"] = desc
	return schema, nil
}

// statusTool is the manager's window into a live bridge (hidden: components
// may call hidden tools over NATS; the LLM never sees it).
func (b *bridge) status(_ *sdk.Component, args json.RawMessage) (any, error) {
	var req struct {
		Op string `json:"op"`
	}
	_ = json.Unmarshal(args, &req)
	if req.Op == "refresh" {
		b.dropSession()
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		if _, err := b.ensure(ctx); err != nil {
			return nil, err
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return map[string]any{
		"server":    b.cfg.Name,
		"type":      b.cfg.transport(),
		"connected": b.cs != nil,
		"tools":     len(b.cfg.Tools),
		"prompts":   len(b.cfg.Prompts),
		"drifted":   b.drifted,
		"lastError": b.lastErr,
		"startedAt": epoch(b.started),
		"lastUsed":  epoch(b.lastUsed),
		"idleMs":    b.cfg.idle().Milliseconds(),
	}, nil
}

func epoch(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return float64(t.UnixMilli()) / 1000
}

func sdkLog(comp *sdk.Component, msg string, ctx any) {
	if comp != nil {
		_ = comp.Log("info", msg, ctx)
		return
	}
	fmt.Fprintln(os.Stderr, "mcp-bridge: "+msg)
}

// ---------------------------------------------------------------- probe

// runProbe validates a config by connecting once and printing the tool
// listing; the config arrives on stdin — no bus, no store involvement.
func runProbe(cfg *serverConfig) error {
	b := &bridge{cfg: cfg, probe: true}
	ctx := context.Background()
	if raw := os.Getenv(probeTimeoutEnv); raw != "" {
		var ms int
		if _, err := fmt.Sscanf(raw, "%d", &ms); err == nil && ms > 0 {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, time.Duration(ms)*time.Millisecond)
			defer cancel()
		}
	}
	if _, err := b.ensure(ctx); err != nil {
		if b.cs != nil {
			_ = b.cs.Close()
		}
		return err
	}
	b.mu.Lock()
	tools := b.cfg.Tools
	prompts := b.cfg.Prompts
	sess := b.cs
	b.mu.Unlock()
	out, err := json.Marshal(map[string]any{"ok": true, "tools": tools, "prompts": prompts})
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	_ = sess.Close()
	return nil
}

// ---------------------------------------------------------------- main

var bGlobal *bridge

func main() {
	sdk.DieWithParent()
	bGlobal = &bridge{}
	server := flag.String("server", "", "MCP server name (store record id, kind \"mcp\")")
	probe := flag.Bool("probe", false, "validate a config: JSON config on stdin, connect once, print tools, exit")
	flag.Parse()
	if *server == "" {
		fmt.Fprintln(os.Stderr, "usage: mcp-bridge --server <name> [--probe]")
		os.Exit(2)
	}
	name := sanitizeComponent(*server)
	if name == "" {
		fmt.Fprintln(os.Stderr, "mcp-bridge: empty server name")
		os.Exit(2)
	}

	if *probe {
		// Probe mode reads the candidate config on stdin — the manager may
		// validate a server before any record exists.
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mcp-bridge: read config: %v\n", err)
			os.Exit(1)
		}
		var cfg serverConfig
		if err := json.Unmarshal(raw, &cfg); err != nil {
			fmt.Fprintf(os.Stderr, "mcp-bridge: parse config: %v\n", err)
			os.Exit(1)
		}
		if cfg.Name == "" {
			cfg.Name = *server
		}
		bGlobal.cfg = &cfg
		if err := runProbe(bGlobal.cfg); err != nil {
			fmt.Fprintf(os.Stderr, "mcp-bridge: probe failed: %v\n", err)
			os.Exit(1)
		}
		return
	}

	// Normal mode: the bridge is a thin store client. The manager owns the
	// record; we only read it (plus drift rewrites of the tools cache).
	// NIF_ROOT/NIF_NATS_URL arrive from the supervisor environment. The
	// announce is deferred: the catalog's first sight of this component must
	// already carry the final toolset, which is only known after the store
	// round-trip.
	comp := sdk.New("mcp-"+name, bridgeVersion).DeferAnnounce()
	bGlobal.comp = comp
	if err := comp.Connect(); err != nil {
		fmt.Fprintf(os.Stderr, "mcp-bridge: %v\n", err)
		os.Exit(1)
	}

	cfg, err := loadConfig(comp, *server)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcp-bridge: %v\n", err)
		os.Exit(1)
	}
	bGlobal.cfg = cfg
	if !cfg.enabled() {
		fmt.Fprintf(os.Stderr, "mcp-bridge: server %q is disabled\n", *server)
		os.Exit(0)
	}

	if *probe {
		if err := runProbe(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "mcp-bridge: probe failed: %v\n", err)
			os.Exit(1)
		}
		return
	}

	registered, err := registerTools(comp, cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcp-bridge: %v\n", err)
		os.Exit(1)
	}
	// Prompt templates become hidden prompt tools + slash commands for the
	// interactive UIs; zero prompts is normal (most servers have none).
	registerPrompts(comp, cfg)
	comp.Tool("mcp_"+sanitizeTool(cfg.Name)+"_bridge_status", map[string]any{
		"type":        "object",
		"description": fmt.Sprintf("Bridge status for MCP server %q (manager-facing, hidden).", cfg.Name),
		"properties": map[string]any{
			"op": map[string]any{"type": "string", "enum": []string{"status", "refresh"},
				"description": "status (default) reports state; refresh drops the session and reconnects now"},
		},
		"x-harness": map[string]any{"hidden": true},
	}, bGlobal.status)

	// Idle reaper: close sessions nobody used for idleMs (kills stdio
	// subprocesses); the next call reconnects lazily.
	go bGlobal.reaper()

	comp.OnDrain(func(_ *sdk.Component) { bGlobal.dropSession() })
	sdkLog(comp, fmt.Sprintf("serving %d tools from MCP server %q", registered, cfg.Name),
		map[string]any{"server": cfg.Name, "type": cfg.transport(), "tools": registered})
	if err := comp.Announce(); err != nil {
		fmt.Fprintf(os.Stderr, "mcp-bridge: announce: %v\n", err)
		os.Exit(1)
	}
	comp.Wait()
	comp.Close()
}

// loadConfig reads the record from the store. The bridge cannot run without
// the store — fail loudly rather than announcing a guess.
func loadConfig(comp *sdk.Component, name string) (*serverConfig, error) {
	item, err := comp.StoreGet(kindMCP, name, 15*time.Second)
	if err != nil {
		return nil, fmt.Errorf("load config for %q: %w", name, err)
	}
	var cfg serverConfig
	if err := json.Unmarshal(item.Value, &cfg); err != nil {
		return nil, fmt.Errorf("parse config for %q: %w", name, err)
	}
	if cfg.Name == "" {
		cfg.Name = name
	}
	return &cfg, nil
}

// reaper closes the session when it has been idle past the configured
// window. stdio subprocesses die with the session (SDK transport close).
func (b *bridge) reaper() {
	idle := b.cfg.idle()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		b.mu.Lock()
		if b.cs != nil && time.Since(b.lastUsed) > idle {
			_ = b.cs.Close()
			b.cs = nil
			sdkLog(b.comp, "closed idle MCP session", map[string]any{"server": b.cfg.Name})
		}
		b.mu.Unlock()
	}
}
