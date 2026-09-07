// mcp — manager for external MCP servers (Model Context Protocol).
//
// The manager owns the configuration: every MCP server is one store record
// (kind "mcp", id = server name) and one supervised bridge process
// (components/mcp-bridge, spawned via core.spawn with argv --server <name>).
// The bridge announces the server's tools as ordinary catalog tools
// (mcp_<server>_<tool>), so they participate in progressive discovery like
// any component tool: hints via discover, full schemas into the conversation
// via discover {component, tools}, calls through invoke with the normal
// approval/timeout/cancellation semantics.
//
//	mcp_servers  list configured servers with live bridge state (read-only)
//	mcp_add      validate a server (one real connect + tools/list through
//	             the bridge in probe mode), store the record with the cached
//	             tool listing, spawn the bridge   (approval: always)
//	mcp_edit     update fields, re-validate, respawn the bridge
//	mcp_remove   kill the bridge, delete the record    (approval: always)
//	mcp_refresh  force a bridge to reconnect now and re-list its tools
//
// Sessions in the bridge are lazy: adding a server validates it with one
// connect, but the MCP subprocess/HTTP session itself only starts on the
// first tool call and idles out afterwards — booting the harness never pays
// for npx/uvx startup.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	sdk "niffler.dev/sdk"
)

const defaultManagerVersion = "0.1.0"

type manager struct {
	comp      *sdk.Component
	bridgeBin string // absolute path to mcp-bridge (NIF_ROOT/var/bin/mcp-bridge)
	root      string
}

func main() {
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	bridgeBin := os.Getenv("NIF_MCP_BRIDGE_BIN")
	if bridgeBin == "" {
		bridgeBin = root + "/var/bin/mcp-bridge"
	}

	comp := sdk.New("mcp", defaultManagerVersion)
	m := &manager{comp: comp, bridgeBin: bridgeBin, root: root}

	comp.Tool("mcp_servers", map[string]any{
		"type": "object",
		"description": "List configured MCP servers with their transport, cached tool count and live bridge state. " +
			"Env/header values are never echoed. Use mcp_add/mcp_edit/mcp_remove to manage servers.",
		"properties": map[string]any{},
		"x-harness":  map[string]any{"onDemand": true, "effect": "read"},
	}, m.list)

	comp.Tool("mcp_add", map[string]any{
		"type": "object",
		"description": "Add an MCP server: validates it with one real connect (initialize + tools/list), " +
			"stores the config with the cached tool listing and spawns its bridge, whose tools become " +
			"discoverable as mcp_<server>_<tool>. Transports: stdio (command+args), http/sse (url, optional headers). " +
			"Validation timeout defaults to 30s (NIF_MCP_PROBE_TIMEOUT_MS overrides); npx/uvx first-run downloads may need more.",
		"properties": map[string]any{
			"name":        map[string]any{"type": "string", "description": "Server name (unique); sanitized into the component id mcp-<name>"},
			"type":        map[string]any{"type": "string", "enum": []string{"stdio", "http", "sse"}, "description": "Transport (default stdio)"},
			"command":     map[string]any{"type": "string", "description": "stdio: executable to launch (e.g. npx, uvx, /path/to/server)"},
			"args":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "stdio: command arguments"},
			"env":         map[string]any{"type": "object", "description": "stdio: extra environment variables for the subprocess; values may contain ${NAME} references resolved from the harness environment at spawn (store keeps the placeholder, listings redact values)"},
			"cwd":         map[string]any{"type": "string", "description": "stdio: working directory for the subprocess"},
			"url":         map[string]any{"type": "string", "description": "http/sse: endpoint URL (may contain ${NAME} env references, resolved at connect)"},
			"headers":     map[string]any{"type": "object", "description": "http/sse: request headers, e.g. Authorization; values may contain ${NAME} references resolved from the harness environment at connect (store keeps the placeholder, listings redact values)"},
			"approval":    map[string]any{"type": "string", "enum": []string{"", "always"}, "description": "Gate every tool of this server with a human approval prompt (default: none)"},
			"expose":      map[string]any{"type": "string", "enum": []string{"ondemand", "direct"}, "description": "ondemand (default) keeps tools out of the frozen direct toolset (discover+invoke); direct puts schemas into every new conversation"},
			"effect":      map[string]any{"type": "string", "enum": []string{"read", "write"}, "description": "Fabric scheduling hint for the server's tools (default write)"},
			"timeoutMs":   map[string]any{"type": "integer", "minimum": 0, "description": "Per-call deadline in milliseconds (0 = 120 seconds); includes lazy initialization"},
			"idleMs":      map[string]any{"type": "integer", "description": "Idle session close in milliseconds (default 300000)"},
			"concurrency": map[string]any{"type": "string", "enum": []string{"parallel", "serial"}, "description": "parallel (default) allows overlapping calls; serial for servers that cannot handle it"},
			"enabled":     map[string]any{"type": "boolean", "description": "Spawn the bridge now (default true); false stores the config without connecting"},
		},
		"required":  []string{"name"},
		"x-harness": map[string]any{"onDemand": true, "approval": "always"},
	}, m.add)

	comp.Tool("mcp_edit", map[string]any{
		"type": "object",
		"description": "Update an MCP server's configuration: provided fields replace current ones, the server is " +
			"re-validated (fresh tool listing) and its bridge respawns. Omitted fields keep their values.",
		"properties": map[string]any{
			"name":        map[string]any{"type": "string", "description": "Server to edit"},
			"type":        map[string]any{"type": "string", "enum": []string{"stdio", "http", "sse"}},
			"command":     map[string]any{"type": "string"},
			"args":        map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
			"env":         map[string]any{"type": "object", "description": "Replaces the whole env map"},
			"cwd":         map[string]any{"type": "string"},
			"url":         map[string]any{"type": "string"},
			"headers":     map[string]any{"type": "object", "description": "Replaces the whole headers map"},
			"approval":    map[string]any{"type": "string", "enum": []string{"", "always"}},
			"expose":      map[string]any{"type": "string", "enum": []string{"ondemand", "direct"}},
			"effect":      map[string]any{"type": "string", "enum": []string{"read", "write"}},
			"timeoutMs":   map[string]any{"type": "integer"},
			"idleMs":      map[string]any{"type": "integer"},
			"concurrency": map[string]any{"type": "string", "enum": []string{"parallel", "serial"}},
			"enabled":     map[string]any{"type": "boolean", "description": "false disables and removes the bridge; true respawns it"},
		},
		"required":  []string{"name"},
		"x-harness": map[string]any{"onDemand": true, "approval": "always"},
	}, m.edit)

	comp.Tool("mcp_remove", map[string]any{
		"type": "object",
		"description": "Remove an MCP server: kills its bridge and deletes the stored config. The server's tools " +
			"disappear from discovery; existing conversations keep their frozen toolset (calls fail through normal routing).",
		"properties": map[string]any{
			"name": map[string]any{"type": "string", "description": "Server to remove"},
		},
		"required":  []string{"name"},
		"x-harness": map[string]any{"onDemand": true, "approval": "always"},
	}, m.remove)

	comp.Tool("mcp_refresh", map[string]any{
		"type": "object",
		"description": "Force a running MCP bridge to drop its session, reconnect and re-list the server's tools now " +
			"(otherwise this happens lazily on the next tool call). Returns the refreshed bridge status.",
		"properties": map[string]any{
			"name": map[string]any{"type": "string", "description": "Server to refresh"},
		},
		"required":  []string{"name"},
		"x-harness": map[string]any{"onDemand": true},
	}, m.refresh)

	comp.Tool("mcp_search", map[string]any{
		"type": "object",
		"description": "Search the official MCP Registry (registry.modelcontextprotocol.io) for MCP servers by keyword. " +
			"Returns installable entries with ready mcp_add arguments (name/type/command/args/url) plus non-installable ones with the reason. " +
			"Read-only browse: pass an entry through mcp_add to actually connect it.",
		"properties": map[string]any{
			"query": map[string]any{"type": "string", "description": "Search keywords (e.g. \"github\", \"filesystem\")"},
			"limit": map[string]any{"type": "integer", "description": "Max results (default 10, max 20)"},
		},
		"required":  []string{"query"},
		"x-harness": map[string]any{"onDemand": true, "effect": "read"},
	}, m.search)

	if err := comp.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "mcp: %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------- listing

func (m *manager) list(_ *sdk.Component, _ json.RawMessage) (any, error) {
	records, err := m.comp.StoreList(kindMCP, "", 1000, 5*time.Second)
	if err != nil {
		return nil, err
	}
	snapshot, err := m.comp.Request("core", "catalog", map[string]any{"op": "snapshot"}, 10*time.Second)
	if err != nil {
		snapshot = nil // catalog down: report records without live state
	}
	live := map[string]json.RawMessage{}
	if snapshot != nil {
		var snap struct {
			Components []struct {
				Name  string `json:"name"`
				Tools []struct {
					Name string `json:"name"`
				} `json:"tools"`
			} `json:"components"`
		}
		if json.Unmarshal(snapshot, &snap) == nil {
			for _, c := range snap.Components {
				var names []string
				for _, t := range c.Tools {
					names = append(names, t.Name)
				}
				raw, _ := json.Marshal(names)
				live[c.Name] = raw
			}
		}
	}
	items := []map[string]any{}
	for _, rec := range records {
		var cfg serverConfig
		if err := json.Unmarshal(rec.Value, &cfg); err != nil {
			items = append(items, map[string]any{"name": rec.ID, "error": "unreadable record"})
			continue
		}
		entry := map[string]any{
			"name":        cfg.Name,
			"type":        cfg.Type,
			"enabled":     cfg.Enabled == nil || *cfg.Enabled,
			"toolCount":   len(cfg.Tools),
			"promptCount": len(cfg.Prompts),
			"timeoutMs":   cfg.TimeoutMs,
			"idleMs":      cfg.IdleMs,
			"cwd":         cfg.Cwd,
			"effect":      cfg.Effect,
			"concurrency": cfg.Concurrency,
			"approval":    cfg.Approval,
			"expose":      cfg.Expose,
		}
		switch cfg.Type {
		case "http", "sse":
			entry["url"] = cfg.URL
			entry["headerKeys"] = keys(cfg.Headers)
		default:
			entry["command"] = cfg.Command
			entry["args"] = cfg.Args
			entry["envKeys"] = keys(cfg.Env)
		}
		component := "mcp-" + cfg.Name
		entry["component"] = component
		if names, ok := live[component]; ok {
			entry["live"] = true
			var toolNames []string
			_ = json.Unmarshal(names, &toolNames)
			entry["registeredTools"] = toolNames

		} else {
			entry["live"] = false
		}
		items = append(items, entry)
	}
	// One stalled bridge must not serialize every live-state lookup.
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for _, entry := range items {
		if entry["live"] != true {
			continue
		}
		sem <- struct{}{}
		wg.Add(1)
		go func(entry map[string]any) {
			defer wg.Done()
			defer func() { <-sem }()
			if status, err := m.bridgeStatus(entry["name"].(string), "status", time.Second); err == nil {
				entry["bridge"] = status
			}
		}(entry)
	}
	wg.Wait()
	return map[string]any{"servers": items, "count": len(items)}, nil
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

const registryDefaultURL = "https://registry.modelcontextprotocol.io"

// registryEntry is one official-MCP-Registry result narrowed to what
// mcp_add can consume directly. Browsing is read-only — nothing installs
// without the caller passing the entry through mcp_add (which validates
// with a real connect and asks for approval).
type registryEntry struct {
	Name           string         `json:"name"`
	Title          string         `json:"title,omitempty"`
	Description    string         `json:"description,omitempty"`
	Version        string         `json:"version,omitempty"`
	Transport      string         `json:"transport,omitempty"`
	Command        string         `json:"command,omitempty"`
	Args           []string       `json:"args,omitempty"`
	URL            string         `json:"url,omitempty"`
	Config         map[string]any `json:"config,omitempty"`
	Requirements   []string       `json:"requirements,omitempty"`
	Installable    bool           `json:"installable"`
	NotInstallable string         `json:"notInstallableReason,omitempty"`
}

// registrySearch queries the official MCP Registry browse endpoint
// (?search=&version=latest) with a short timeout and a response cap.
// NIF_MCP_REGISTRY_URL overrides the base (air-gapped/proxied setups).
func registrySearch(query string, limit int) ([]registryEntry, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("query is required")
	}
	if limit <= 0 || limit > 20 {
		limit = 10
	}
	base := strings.TrimSpace(os.Getenv("NIF_MCP_REGISTRY_URL"))
	if base == "" {
		base = registryDefaultURL
	}
	url := fmt.Sprintf("%s/v0/servers?search=%s&version=latest&limit=%d",
		strings.TrimRight(base, "/"), neturl.QueryEscape(query), limit)
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("registry unreachable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("registry returned status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(body) > 4<<20 {
		return nil, errors.New("registry response exceeds 4 MiB")
	}
	var payload struct {
		Servers []struct {
			Server registryServer `json:"server"`
		} `json:"servers"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, fmt.Errorf("bad registry payload: %w", err)
	}
	out := make([]registryEntry, 0, len(payload.Servers))
	for _, wrapped := range payload.Servers {
		if wrapped.Server.Name == "" {
			return nil, errors.New("registry entry is missing server.name")
		}
		out = append(out, registryCandidate(wrapped.Server))
		if len(out) == limit {
			break
		}
	}
	return out, nil
}

// registrySuggestedName turns "io.github.user/server-name" into "server-name".
func registrySuggestedName(full string) string {
	if idx := strings.LastIndex(full, "/"); idx >= 0 {
		return full[idx+1:]
	}
	return full
}

// ---------------------------------------------------------------- add/edit

// parseConfig extracts the shared mcp_add/mcp_edit fields from raw args.
// present tracks which optional fields the caller actually supplied so edit
// merges instead of replacing.
func parseConfig(raw json.RawMessage) (cfg serverConfig, present map[string]bool, err error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || fields == nil {
		return cfg, nil, errors.New("arguments must be an object")
	}
	present = map[string]bool{}
	for key, value := range fields {
		if key == "tools" || key == "prompts" {
			return cfg, nil, fmt.Errorf("%s is not editable", key)
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return cfg, nil, fmt.Errorf("%s must not be null", key)
		}
		present[key] = true
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cfg); err != nil {
		return cfg, nil, fmt.Errorf("bad arguments: %w", err)
	}
	return cfg, present, nil
}

var oneOf = map[string][]string{
	"type":        {"", "stdio", "http", "sse"},
	"approval":    {"", "always"},
	"expose":      {"", "ondemand", "direct"},
	"effect":      {"", "read", "write"},
	"concurrency": {"", "parallel", "serial"},
}

// validate checks enum fields and transport-specific requirements. It does
// not touch the network — that is the probe's job.
func (m *manager) validate(cfg *serverConfig) error {
	if err := validateName(cfg.Name); err != nil {
		return err
	}
	if cfg.Name == "bridge" {
		return errors.New("server name bridge is reserved")
	}
	for field, allowed := range oneOf {
		var got string
		switch field {
		case "type":
			got = cfg.Type
		case "approval":
			got = cfg.Approval
		case "expose":
			got = cfg.Expose
		case "effect":
			got = cfg.Effect
		case "concurrency":
			got = cfg.Concurrency
		}
		ok := false
		for _, a := range allowed {
			if got == a {
				ok = true
				break
			}
		}
		if !ok {
			return fmt.Errorf("%s must be one of %v", field, allowed)
		}
	}
	if cfg.Type == "" {
		cfg.Type = "stdio"
	}
	switch cfg.Type {
	case "stdio":
		if strings.TrimSpace(cfg.Command) == "" {
			return fmt.Errorf("stdio servers need a command")
		}
	case "http", "sse":
		u, err := neturl.Parse(cfg.URL)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Fragment != "" {
			return errors.New("url must be http(s), without embedded credentials or fragment")
		}
	}
	if cfg.TimeoutMs < 0 || cfg.IdleMs < 0 || cfg.TimeoutMs > 86_400_000 || cfg.IdleMs > 86_400_000 {
		return fmt.Errorf("timeoutMs/idleMs must be between 0 and 86400000")
	}
	for k, v := range cfg.Env {
		if k == "" || strings.ContainsAny(k, "=\x00") || strings.ContainsRune(v, 0) {
			return errors.New("invalid environment key/value")
		}
	}
	for k, v := range cfg.Headers {
		if !headerNamePattern.MatchString(k) || strings.ContainsAny(v, "\r\n\x00") {
			return errors.New("invalid header key/value")
		}
	}
	return nil
}

// probe validates a candidate config through the bridge binary (config on
// stdin, one real connect, tool+prompt listings on stdout).
func (m *manager) probe(cfg *serverConfig) ([]cachedTool, []cachedPrompt, error) {
	payload, err := json.Marshal(cfg)
	if err != nil {
		return nil, nil, err
	}
	// First runs of npx/uvx servers download packages; a server-configured
	// per-call timeout above 30s extends validation too.
	timeout := 30 * time.Second
	if cfg.TimeoutMs > 30_000 {
		timeout = time.Duration(cfg.TimeoutMs) * time.Millisecond
	}
	if raw := os.Getenv("NIF_MCP_PROBE_TIMEOUT_MS"); raw != "" {
		var ms int
		if _, err := fmt.Sscanf(raw, "%d", &ms); err == nil && ms > 0 {
			timeout = time.Duration(ms) * time.Millisecond
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, m.bridgeBin, "--server", cfg.Name, "--probe")
	cmd.Stdin = bytes.NewReader(payload)
	stdout := cappedBuffer{limit: 1 << 20}
	stderr := cappedBuffer{limit: 64 << 10}
	cmd.WaitDelay = 3 * time.Second
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.Env = os.Environ()
	if err := cmd.Run(); err != nil {
		tail := redactConfigText(cfg, stderr.String())
		if len(tail) > 400 {
			tail = tail[len(tail)-400:]
		}
		if ctx.Err() != nil {
			return nil, nil, fmt.Errorf("validation timed out after %s (first run of npx/uvx servers downloads packages — raise NIF_MCP_PROBE_TIMEOUT_MS): %s", timeout, strings.TrimSpace(tail))
		}
		return nil, nil, fmt.Errorf("server did not validate: %s", strings.TrimSpace(tail))
	}
	var reply struct {
		OK      bool           `json:"ok"`
		Tools   []cachedTool   `json:"tools"`
		Prompts []cachedPrompt `json:"prompts"`
	}
	if stdout.overflow {
		return nil, nil, errors.New("probe result exceeded 1 MiB")
	}
	if err := json.Unmarshal(stdout.Bytes(), &reply); err != nil || !reply.OK {
		return nil, nil, fmt.Errorf("probe produced no usable result: %s", strings.TrimSpace(stdout.String()))
	}
	candidate := *cfg
	candidate.Tools = reply.Tools
	candidate.Prompts = reply.Prompts
	if _, err := contractNames(&candidate); err != nil {
		return nil, nil, err
	}
	return reply.Tools, reply.Prompts, nil
}

// spawnBridge asks core to supervise mcp-<name>. Idempotent: an already
// supervised bridge (boot restore) is fine.
func (m *manager) spawnBridge(name string) error {
	_, err := m.comp.RequestOK("core", "spawn", map[string]any{
		"name":   "mcp-" + name,
		"binary": m.bridgeBin,
		"args":   []string{"--server", name},
	}, 30*time.Second)
	if err != nil && !strings.Contains(err.Error(), "already supervised") {
		return err
	}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		snap, e := m.comp.RequestOK("core", "catalog", map[string]any{"op": "snapshot"}, time.Second)
		if e == nil {
			var catalog struct {
				Components []struct {
					Name string `json:"name"`
				} `json:"components"`
			}
			if json.Unmarshal(snap, &catalog) == nil {
				for _, c := range catalog.Components {
					if c.Name == "mcp-"+name {
						return nil
					}
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("bridge did not register within 15s; inspect var/logs/mcp-" + name + ".log")
}

// stopBridge kills (and, with removeRecord, un-persists) the bridge.
func (m *manager) stopBridge(name string, removeRecord bool) error {
	op := "kill"
	if removeRecord {
		op = "remove"
	}
	_, err := m.comp.RequestOK("core", op, map[string]any{"name": "mcp-" + name}, 30*time.Second)
	if err != nil && (strings.Contains(err.Error(), "no such component") ||
		strings.Contains(err.Error(), "not found")) {
		return nil
	}
	return err
}

func (m *manager) add(_ *sdk.Component, raw json.RawMessage) (any, error) {
	cfg, present, err := parseConfig(raw)
	if err != nil {
		return nil, err
	}
	if present["enabled"] && !*cfg.Enabled {
		// Storing a disabled server is legitimate; validation still runs so
		// typos do not persist silently? No — a disabled server is a parked
		// config: skip the probe, skip the spawn.
		if err := m.validate(&cfg); err != nil {
			return nil, err
		}
		if _, err := m.comp.StoreGet(kindMCP, cfg.Name, 10*time.Second); err == nil {
			return nil, fmt.Errorf("server %q is already configured (use mcp_edit)", cfg.Name)
		} else if !isNotFound(err) {
			return nil, err
		}
		if err := m.validateNamespace(&cfg); err != nil {
			return nil, err
		}
		if _, err := m.comp.StorePut(kindMCP, cfg.Name, cfg, 0, 10*time.Second); err != nil {
			return nil, err
		}
		return map[string]any{"ok": true, "name": cfg.Name, "stored": true, "enabled": false}, nil
	}
	if err := m.validate(&cfg); err != nil {
		return nil, err
	}
	if _, err := m.comp.StoreGet(kindMCP, cfg.Name, 10*time.Second); err == nil {
		return nil, fmt.Errorf("server %q is already configured (use mcp_edit)", cfg.Name)
	} else if !isNotFound(err) {
		return nil, err
	}
	tools, prompts, err := m.probe(&cfg)
	if err != nil {
		return nil, err
	}
	cfg.Tools = tools
	cfg.Prompts = prompts
	if err := m.validateNamespace(&cfg); err != nil {
		return nil, err
	}
	if _, err := m.comp.StorePut(kindMCP, cfg.Name, cfg, 0, 10*time.Second); err != nil {
		return nil, err
	}
	if err := m.spawnBridge(cfg.Name); err != nil {
		return map[string]any{"ok": true, "name": cfg.Name, "stored": true,
			"warning": fmt.Sprintf("stored but bridge did not start: %v", err)}, nil
	}
	return m.addResult(&cfg), nil
}

func (m *manager) addResult(cfg *serverConfig) any {
	tools := make([]string, 0, len(cfg.Tools))
	for _, t := range cfg.Tools {
		tools = append(tools, prefixedToolName(cfg.Name, t.Name))
	}
	return map[string]any{
		"ok": true, "name": cfg.Name, "type": cfg.Type, "stored": true,
		"component": "mcp-" + cfg.Name, "tools": tools, "toolCount": len(tools),
		"note": "tools are on-demand: discover {component: \"" + "mcp-" + cfg.Name +
			"\"} for schemas, invoke to call; the MCP session starts lazily on first call",
	}
}

func (m *manager) edit(_ *sdk.Component, raw json.RawMessage) (any, error) {
	cfg, present, err := parseConfig(raw)
	if err != nil {
		return nil, err
	}
	name := cfg.Name
	if err := validateName(name); err != nil {
		return nil, err
	}
	item, err := m.comp.StoreGet(kindMCP, name, 10*time.Second)
	if err != nil {
		if isNotFound(err) {
			return nil, fmt.Errorf("no such server: %q (use mcp_add)", name)
		}
		return nil, err
	}
	var current serverConfig
	if err := json.Unmarshal(item.Value, &current); err != nil {
		return nil, err
	}
	// Merge: provided fields replace, omitted fields keep. Name and the
	// cached tools are not editable (identity + bridge-owned cache).
	currentName := current.Name
	mergeConfig(&current, cfg, present)
	current.Name = currentName
	if err := m.validate(&current); err != nil {
		return nil, err
	}
	disabled := current.Enabled != nil && !*current.Enabled
	if !disabled {
		tools, prompts, err := m.probe(&current)
		if err != nil {
			return nil, fmt.Errorf("re-validation failed (record unchanged): %w", err)
		}
		current.Tools = tools
		current.Prompts = prompts
	}
	if err := m.validateNamespace(&current); err != nil {
		return nil, err
	}
	if _, err := m.comp.StorePut(kindMCP, name, current, item.Rev, 10*time.Second); err != nil {
		return nil, err
	}
	respawned := false
	if disabled {
		if err := m.stopBridge(name, true); err != nil {
			return nil, err
		}
	} else if err := m.stopBridge(name, false); err != nil {
		return map[string]any{"ok": true, "name": name, "stored": true,
			"warning": fmt.Sprintf("stored but old bridge is still running: %v", err)}, nil
	} else if err := m.spawnBridge(name); err != nil {
		return map[string]any{"ok": true, "name": name, "stored": true,
			"warning": fmt.Sprintf("stored but bridge did not restart: %v", err)}, nil
	} else {
		respawned = true
	}
	out := m.addResult(&current)
	if mm, ok := out.(map[string]any); ok {
		mm["respawned"] = respawned
		mm["enabled"] = !disabled
	}
	return out, nil
}

// mergeConfig applies present fields from src onto dst.
func mergeConfig(dst *serverConfig, src serverConfig, present map[string]bool) {
	applyStr := func(key string, target *string, val string) {
		if present[key] {
			*target = val
		}
	}
	applyStr("type", &dst.Type, src.Type)
	applyStr("command", &dst.Command, src.Command)
	applyStr("cwd", &dst.Cwd, src.Cwd)
	applyStr("url", &dst.URL, src.URL)
	applyStr("approval", &dst.Approval, src.Approval)
	applyStr("expose", &dst.Expose, src.Expose)
	applyStr("effect", &dst.Effect, src.Effect)
	applyStr("concurrency", &dst.Concurrency, src.Concurrency)
	if present["args"] {
		dst.Args = src.Args
	}
	if present["env"] {
		dst.Env = src.Env
	}
	if present["headers"] {
		dst.Headers = src.Headers
	}
	if present["timeoutMs"] {
		dst.TimeoutMs = src.TimeoutMs
	}
	if present["idleMs"] {
		dst.IdleMs = src.IdleMs
	}
	if src.Enabled != nil {
		dst.Enabled = src.Enabled
	}
}

func (m *manager) remove(_ *sdk.Component, raw json.RawMessage) (any, error) {
	var args struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad arguments: %w", err)
	}
	name := args.Name
	if err := validateName(name); err != nil {
		return nil, err
	}
	if _, err := m.comp.StoreGet(kindMCP, name, 10*time.Second); err != nil {
		if isNotFound(err) {
			return nil, fmt.Errorf("no such server: %q", name)
		}
		return nil, err
	}
	// core remove = kill + delete the persisted component record, so the
	// bridge does not resurrect on the next boot.
	if err := m.stopBridge(name, true); err != nil {
		return map[string]any{"ok": true, "name": name,
			"warning": fmt.Sprintf("record retained because bridge stop failed: %v", err)}, nil
	}
	if err := m.comp.StoreDel(kindMCP, name, 10*time.Second); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "name": name, "removed": true}, nil
}

func (m *manager) refresh(_ *sdk.Component, raw json.RawMessage) (any, error) {
	var args struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad arguments: %w", err)
	}
	name := args.Name
	if err := validateName(name); err != nil {
		return nil, err
	}
	status, err := m.bridgeStatus(name, "refresh", 65*time.Second)
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "name": name, "bridge": status}, nil
}

// bridgeStatus calls the bridge's hidden status tool directly over NATS
// (component-to-component calls may target hidden tools).
func (m *manager) bridgeStatus(server, op string, timeout time.Duration) (any, error) {
	component := "mcp-" + server
	return m.comp.RequestOK(component, prefixedToolName(server, "")+"bridge_status",
		map[string]any{"op": op}, timeout)
}

func isNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "not found")
}

// search browses the official MCP Registry. Installable entries carry ready
// mcp_add arguments; the caller still goes through mcp_add (validation +
// approval) — browsing never mutates anything.
func (m *manager) search(_ *sdk.Component, raw json.RawMessage) (any, error) {
	var args struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("bad arguments: %w", err)
	}
	entries, err := registrySearch(args.Query, args.Limit)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"ok": true, "query": strings.TrimSpace(args.Query),
		"entries": entries, "count": len(entries),
		"note": "installable entries: call mcp_add with name=" + "\"<your-name>\"" +
			" plus the entry's type/command/args/url (name suggestion: last path segment)",
	}, nil
}
