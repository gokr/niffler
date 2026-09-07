// mcp-bridge: one external MCP server, one supervised bus component.
// Config is immutable for a process lifetime. Contract drift retires the
// process after persisting the new contract and draining accepted calls.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	sdk "niffler.dev/sdk"
)

const bridgeVersion = "0.1.0"
const driftExitCode = 3
const defaultCallTimeout = 120 * time.Second
const listingTimeout = 30 * time.Second

var errRetiring = errors.New("MCP bridge is retiring; retry after it re-registers")

type activeCall struct {
	session, tool string
	cancel        context.CancelFunc
}
type liveSession struct {
	cs   *mcp.ClientSession
	wire *captureTransport
	done chan struct{}
}
type bridge struct {
	cfg                     *serverConfig
	comp                    *sdk.Component
	probe                   bool
	mu                      sync.Mutex    // state only: never held across network I/O or Close
	gate                    chan struct{} // cancellable serialization of connect/list/close
	cs                      *liveSession
	active                  map[uint64]activeCall
	nextID                  uint64
	started, lastUsed       time.Time
	lastErr                 string
	retiring, restartWanted bool
	changed                 chan struct{}
	restart                 chan struct{}
	restartOnce             sync.Once
	ctx                     context.Context
	cancel                  context.CancelFunc
}

func newBridge(cfg *serverConfig, comp *sdk.Component, probe bool) *bridge {
	ctx, cancel := context.WithCancel(context.Background())
	return &bridge{cfg: cfg, comp: comp, probe: probe, gate: make(chan struct{}, 1), active: map[uint64]activeCall{}, changed: make(chan struct{}, 1), restart: make(chan struct{}), ctx: ctx, cancel: cancel}
}
func (c *serverConfig) enabled() bool { return c.Enabled == nil || *c.Enabled }
func (c *serverConfig) transport() string {
	if c.Type == "" {
		return "stdio"
	}
	return c.Type
}
func (c *serverConfig) idle() time.Duration {
	if c.IdleMs <= 0 {
		return 5 * time.Minute
	}
	return time.Duration(c.IdleMs) * time.Millisecond
}
func (c *serverConfig) timeout() time.Duration {
	if c.TimeoutMs <= 0 {
		return defaultCallTimeout
	}
	return time.Duration(c.TimeoutMs) * time.Millisecond
}
func (b *bridge) lock(ctx context.Context) error {
	select {
	case b.gate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			b.unlock()
			return err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (b *bridge) unlock()           { <-b.gate }
func (b *bridge) markErr(err error) { b.mu.Lock(); b.lastErr = err.Error(); b.mu.Unlock() }

// begin strips harness-private context before passing arguments to MCP. The
// independent cancel subscription can run even while SDK handlers are busy.
func (b *bridge) begin(tool string, raw json.RawMessage) (context.Context, json.RawMessage, func(), error) {
	var args map[string]json.RawMessage
	if err := json.Unmarshal(raw, &args); err != nil || args == nil {
		return nil, nil, nil, errors.New("arguments must be an object")
	}
	var private struct {
		Session string `json:"session"`
	}
	if v, ok := args["__session"]; ok {
		if err := json.Unmarshal(v, &private); err != nil {
			return nil, nil, nil, err
		}
		delete(args, "__session")
	}
	clean, err := json.Marshal(args)
	if err != nil {
		return nil, nil, nil, err
	}
	ctx, cancel := context.WithTimeout(b.ctx, b.cfg.timeout())
	b.mu.Lock()
	if b.retiring {
		b.mu.Unlock()
		cancel()
		return nil, nil, nil, errRetiring
	}
	b.nextID++
	id := b.nextID
	b.active[id] = activeCall{private.Session, tool, cancel}
	b.mu.Unlock()
	return ctx, clean, func() {
		cancel()
		b.mu.Lock()
		delete(b.active, id)
		b.lastUsed = time.Now()
		b.maybeRestartLocked()
		b.mu.Unlock()
	}, nil
}
func (b *bridge) cancelCalls(_ string, raw json.RawMessage) {
	var ev struct {
		Session string `json:"sessionId"`
		Tool    string `json:"tool"`
	}
	if json.Unmarshal(raw, &ev) != nil || ev.Session == "" {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, call := range b.active {
		if call.session == ev.Session && (ev.Tool == "" || ev.Tool == call.tool) {
			call.cancel()
		}
	}
}
func (b *bridge) maybeRestartLocked() {
	if b.restartWanted && len(b.active) == 0 {
		b.restartOnce.Do(func() { close(b.restart) })
	}
}

func (b *bridge) ensure(ctx context.Context) (*mcp.ClientSession, error) {
	if !b.cfg.enabled() {
		return nil, errors.New("MCP server is disabled")
	}
	if err := b.lock(ctx); err != nil {
		return nil, err
	}
	defer b.unlock()
	b.mu.Lock()
	session := b.cs
	retiring := b.retiring
	b.mu.Unlock()
	if retiring {
		return nil, errRetiring
	}
	if session != nil {
		select {
		case <-session.done:
			b.detachAndClose(session)
		default:
			return session.cs, nil
		}
	}
	initCtx, cancel := context.WithTimeout(ctx, listingTimeout)
	defer cancel()
	transport, err := makeTransport(b.cfg)
	if err != nil {
		return nil, err
	}
	wire := &captureTransport{Transport: transport}
	// Force the low-level connection closed on initialization timeout. Graceful
	// SDK Close alone can wait for a non-cooperating peer's pending requests.
	stopAbort := context.AfterFunc(initCtx, wire.abort)
	defer stopAbort()
	notify := func() {
		select {
		case b.changed <- struct{}{}:
		default:
		}
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "niffler-mcp", Version: bridgeVersion}, &mcp.ClientOptions{
		ToolListChangedHandler:   func(context.Context, *mcp.ToolListChangedRequest) { notify() },
		PromptListChangedHandler: func(context.Context, *mcp.PromptListChangedRequest) { notify() },
	})
	cs, err := client.Connect(initCtx, wire, nil)
	if err != nil {
		wire.abort()
		b.markErr(err)
		return nil, fmt.Errorf("MCP connect: %w", err)
	}
	tools, prompts, err := listContract(initCtx, cs)
	if err == nil {
		candidate := *b.cfg
		candidate.Tools = tools
		candidate.Prompts = prompts
		_, err = contractNames(&candidate)
	}
	if err != nil {
		wire.abort()
		_ = cs.Close()
		b.markErr(err)
		return nil, err
	}
	if !stopAbort() || initCtx.Err() != nil {
		wire.abort()
		_ = cs.Close()
		return nil, initCtx.Err()
	}
	live := &liveSession{cs: cs, wire: wire, done: make(chan struct{})}
	b.mu.Lock()
	b.cs = live
	b.started = time.Now()
	b.lastUsed = time.Now()
	b.lastErr = ""
	b.mu.Unlock()
	go func() { _ = cs.Wait(); close(live.done) }()
	if b.probe {
		b.cfg.Tools = tools
		b.cfg.Prompts = prompts
		return cs, nil
	}
	if err := b.acceptContract(tools, prompts); err != nil {
		return nil, err
	}
	return cs, nil
}

// acceptContract never edits the immutable advertised config. If persistence
// fails after bounded retries, fail closed in retiring state (status reports
// the error; mcp_edit can repair it), rather than crash-looping a stale cache.
// nilEmpty normalizes empty slices to nil: stored records omit empty
// tool/prompt lists (json omitempty), while listContract returns non-nil
// empty slices — without this, a server with no prompts (or no tools)
// "drifts" on every boot and fail-closes the bridge into retiring forever.
func nilEmpty[T any](s []T) []T {
	if len(s) == 0 {
		return nil
	}
	return s
}

func (b *bridge) acceptContract(tools []cachedTool, prompts []cachedPrompt) error {
	old, _ := json.Marshal([]any{nilEmpty(b.cfg.Tools), nilEmpty(b.cfg.Prompts)})
	fresh, _ := json.Marshal([]any{nilEmpty(tools), nilEmpty(prompts)})
	if string(old) == string(fresh) {
		return nil
	}
	b.mu.Lock()
	b.retiring = true
	b.mu.Unlock()
	err := b.persistContract(tools, prompts)
	b.mu.Lock()
	defer b.mu.Unlock()
	if err != nil {
		b.lastErr = "contract drift could not be persisted; edit/refresh to recover: " + err.Error()
		return errors.New(b.lastErr)
	}
	b.restartWanted = true
	b.maybeRestartLocked()
	return errRetiring
}
func (b *bridge) persistContract(tools []cachedTool, prompts []cachedPrompt) error {
	if b.comp == nil {
		return errors.New("no store connection")
	}
	for attempt := 0; attempt < 3; attempt++ {
		item, err := b.comp.StoreGet(kindMCP, b.cfg.Name, 5*time.Second)
		if err != nil {
			return err
		}
		var record serverConfig
		if err := json.Unmarshal(item.Value, &record); err != nil {
			return err
		}
		// An old bridge must never overwrite a manager's edited connection/config.
		previous := *b.cfg
		previous.Tools = nil
		previous.Prompts = nil
		current := record
		current.Tools = nil
		current.Prompts = nil
		a, _ := json.Marshal(previous)
		c, _ := json.Marshal(current)
		if string(a) != string(c) {
			return errors.New("server configuration changed concurrently")
		}
		record.Tools = tools
		record.Prompts = prompts
		if _, err := b.comp.StorePut(kindMCP, b.cfg.Name, record, item.Rev, 5*time.Second); err != nil {
			if errors.Is(err, sdk.ErrStoreConflict) {
				continue
			}
			return err
		}
		return nil
	}
	return errors.New("store conflict after three attempts")
}
func (b *bridge) watch() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-b.ctx.Done():
			return
		case now := <-ticker.C:
			b.reap(now)
		case <-b.changed:
			ctx, cancel := context.WithTimeout(b.ctx, listingTimeout)
			if b.lock(ctx) == nil {
				b.mu.Lock()
				s := b.cs
				retiring := b.retiring
				b.mu.Unlock()
				if s != nil && !retiring {
					tools, prompts, err := listContract(ctx, s.cs)
					if err == nil {
						candidate := *b.cfg
						candidate.Tools = tools
						candidate.Prompts = prompts
						_, err = contractNames(&candidate)
					}
					if err == nil {
						err = b.acceptContract(tools, prompts)
					}
					if err != nil && !errors.Is(err, errRetiring) {
						b.markErr(err)
					}
				}
				b.unlock()
			}
			cancel()
		}
	}
}
func (b *bridge) reap(now time.Time) {
	select {
	case b.gate <- struct{}{}:
	default:
		return
	}
	defer b.unlock()
	b.mu.Lock()
	s := b.cs
	idle := len(b.active) == 0 && !b.retiring && now.Sub(b.lastUsed) >= b.cfg.idle()
	b.mu.Unlock()
	if s != nil && idle {
		b.detachAndClose(s)
	}
}
func (b *bridge) detachAndClose(s *liveSession) {
	b.mu.Lock()
	if b.cs == s {
		b.cs = nil
	}
	b.mu.Unlock()
	s.wire.abort() // outside the state mutex; forces pending RPCs to return
	_ = s.cs.Close()
}
func (b *bridge) shutdown() {
	b.cancel()
	b.mu.Lock()
	b.retiring = true
	s := b.cs
	b.cs = nil
	for _, call := range b.active {
		call.cancel()
	}
	b.mu.Unlock()
	if s != nil {
		s.wire.abort()
		_ = s.cs.Close()
	}
}
func (b *bridge) status(_ *sdk.Component, raw json.RawMessage) (any, error) {
	var req struct {
		Op string `json:"op"`
	}
	if err := json.Unmarshal(raw, &req); err != nil {
		return nil, err
	}
	if req.Op == "refresh" {
		ctx, cancel := context.WithTimeout(b.ctx, listingTimeout)
		defer cancel()
		if err := b.lock(ctx); err != nil {
			return nil, err
		}
		b.mu.Lock()
		busy := len(b.active) > 0
		s := b.cs
		if !busy && !b.restartWanted {
			b.retiring = false
		}
		b.mu.Unlock()
		if busy {
			b.unlock()
			return nil, errors.New("server has active calls; refresh after they finish")
		}
		if s != nil {
			b.detachAndClose(s)
		}
		b.unlock()
		if _, err := b.ensure(ctx); err != nil {
			return nil, err
		}
	} else if req.Op != "" && req.Op != "status" {
		return nil, errors.New("op must be status or refresh")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return map[string]any{"server": b.cfg.Name, "type": b.cfg.transport(), "connected": b.cs != nil, "tools": len(b.cfg.Tools), "prompts": len(b.cfg.Prompts), "retiring": b.retiring, "activeCalls": len(b.active), "lastError": b.lastErr, "startedAt": epoch(b.started), "lastUsed": epoch(b.lastUsed), "idleMs": b.cfg.idle().Milliseconds()}, nil
}
func epoch(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return float64(t.UnixMilli()) / 1000
}

func runProbe(cfg *serverConfig) error {
	timeout := listingTimeout
	if raw := os.Getenv("NIF_MCP_PROBE_TIMEOUT_MS"); raw != "" {
		var ms int
		if _, err := fmt.Sscanf(raw, "%d", &ms); err == nil && ms > 0 {
			timeout = time.Duration(ms) * time.Millisecond
		}
	}
	b := newBridge(cfg, nil, true)
	defer b.shutdown()
	ctx, cancel := context.WithTimeout(b.ctx, timeout)
	defer cancel()
	if _, err := b.ensure(ctx); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "tools": cfg.Tools, "prompts": cfg.Prompts})
}
func main() { os.Exit(run()) }
func run() int {
	if len(os.Args) > 1 && os.Args[1] == "--stdio-guard" {
		return runGuard(os.Args[2:])
	}
	sdk.DieWithParent()
	server := flag.String("server", "", "stored MCP server name")
	probe := flag.Bool("probe", false, "validate JSON config from stdin without the bus")
	flag.Parse()
	if err := validateName(*server); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if *probe {
		var cfg serverConfig
		if err := json.NewDecoder(io.LimitReader(os.Stdin, 4<<20)).Decode(&cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		cfg.Name = *server
		if err := runProbe(&cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	}
	comp := sdk.New("mcp-"+*server, bridgeVersion).DeferAnnounce()
	if err := comp.Connect(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer comp.Close()
	item, err := comp.StoreGet(kindMCP, *server, 15*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var cfg serverConfig
	if err := json.Unmarshal(item.Value, &cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if !cfg.enabled() {
		return 0
	}
	if cfg.Name != *server {
		fmt.Fprintln(os.Stderr, "stored server identity mismatch")
		return 1
	}
	b := newBridge(&cfg, comp, false)
	defer b.shutdown()
	if err := b.register(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	unsub, err := comp.Subscribe("cancel."+comp.Name, b.cancelCalls)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer unsub()
	comp.OnDrain(func(*sdk.Component) { b.shutdown() })
	if err := comp.Announce(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	go b.watch()
	stopped := make(chan struct{})
	go func() { comp.Wait(); close(stopped) }()
	code := 0
	select {
	case <-stopped:
	case <-b.restart:
		code = driftExitCode
	}
	b.shutdown()
	// Close drains SDK handlers and flushes their replies before process exit.
	comp.Close()
	return code
}
