// Package sdk is the Niffler component SDK (Go).
//
// The package name is 'sdk' so callers import the module `niffler.dev/sdk` and
// reference it as `sdk.New(...)` / `sdk.Component` — matching the module
// basename, which is what an LLM naturally writes.
package sdk

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

// ToolHandler implements one tool. args is the raw call arguments JSON;
// return the result value (any JSON-marshalable) or an error.
type ToolHandler func(c *Component, args json.RawMessage) (any, error)

// EventHandler implements a passive event subscription; subject is the
// concrete (unwildcarded) subject of the received event.
type EventHandler func(c *Component, subject string, payload json.RawMessage)

// TapHandler implements a raw wire tap: receives the full envelope bytes
// for every matching subject (all kinds: call/result/event/error), for
// bus observation.
type TapHandler func(c *Component, subject string, data []byte)

// Tool is a registered tool: LLM-facing schema plus its handler.
type Tool struct {
	Name    string         `json:"name"`
	Schema  map[string]any `json:"schema"`
	handler ToolHandler
}

// SlashSource describes where a slash-command parameter gets its value
// candidates: the UI calls this tool lazily when the user hits Tab on the
// argument and offers its result values for completion. Field selects the
// value inside each result item when the tool returns objects
// (e.g. "nickname" for provider_list); empty means "id".
type SlashSource struct {
	Tool  string         `json:"tool"`
	Args  map[string]any `json:"args,omitempty"`
	Field string         `json:"field,omitempty"`
}

// SlashParam is one command-line parameter of a slash command.
// Kind: string | bool | int | enum (default string). Default is the
// optional default value used when the user omits the parameter. Values
// lists inline completion candidates (small enums); Source fetches them
// from a tool when the user hits Tab.
type SlashParam struct {
	Name        string       `json:"name"`
	Kind        string       `json:"kind,omitempty"`
	Description string       `json:"description,omitempty"`
	Source      *SlashSource `json:"source,omitempty"`
	Default     any          `json:"default,omitempty"`
	Values      []string     `json:"values,omitempty"`
}

// SlashCommand declares how interactive UIs (TUIs, web) expose this
// component as a slash command (docs/WIRE.md). Tool is the target tool the
// UI calls with the parsed arguments; empty means the command name itself.
type SlashCommand struct {
	Name        string       `json:"name"`
	Description string       `json:"description,omitempty"`
	Tool        string       `json:"tool,omitempty"`
	Params      []SlashParam `json:"params,omitempty"`
}

type eventBinding struct {
	pattern string
	handler EventHandler
}

type tapBinding struct {
	pattern string
	handler TapHandler
}

// Component is a Niffler component.
type Component struct {
	Name    string
	Version string
	// Client marks this component as an interactive frontend (UI): its
	// registration carries "client": true and an autostarted core (see
	// EnsureHarness) stays alive while at least one interactive client is
	// registered, exiting when the last one departs.
	Client bool

	nc            *nats.Conn
	tools         []Tool
	slash         []SlashCommand
	events        []eventBinding
	taps          []tapBinding
	drainHandlers []func(*Component)
	subs          []*nats.Subscription
	mu            sync.Mutex // serializes handlers (mirrors Nim SDK's single thread)
	closeMu       sync.Mutex
	shutdown      chan struct{}
	shutdownOnce  sync.Once
	owner         *Component
	inHandler     bool
}

// New creates a component with the given bus identity.
func New(name, version string) *Component {
	c := &Component{Name: name, Version: version, shutdown: make(chan struct{})}
	c.owner = c
	return c
}

func (c *Component) handlerView() *Component {
	return &Component{
		Name: c.Name, Version: c.Version, nc: c.nc, tools: c.tools,
		events: c.events, taps: c.taps, subs: c.subs, shutdown: c.shutdown,
		drainHandlers: c.drainHandlers,
		owner: c, inHandler: true,
	}
}

// Tool registers a tool. Chainable: New("x","1").Tool(...).Tool(...).Run()
func (c *Component) Tool(name string, schema map[string]any, h ToolHandler) *Component {
	c.tools = append(c.tools, Tool{Name: name, Schema: schema, handler: h})
	return c
}

// Slash registers a slash command for interactive UIs (docs/WIRE.md).
// Chainable: New("x","1").Tool(...).Slash(...).Run(). The target tool
// (cmd.Tool, or cmd.Name when empty) must be registered by this component.
func (c *Component) Slash(cmd SlashCommand) *Component {
	if cmd.Tool == "" {
		cmd.Tool = cmd.Name
	}
	c.slash = append(c.slash, cmd)
	return c
}

// On subscribes to an event pattern (exact subject, ">" or "foo.>").
func (c *Component) On(pattern string, h EventHandler) *Component {
	c.events = append(c.events, eventBinding{pattern, h})
	return c
}

// Tap subscribes a raw wire tap (see TapHandler). The subscription joins
// the same serialized handler stream as events (Nim SDK single-thread
// parity). Taps see all envelope kinds, including this component's own calls.
func (c *Component) Tap(pattern string, h TapHandler) *Component {
	c.taps = append(c.taps, tapBinding{pattern, h})
	return c
}

// OnDrain registers a cleanup callback (e.g. close a database) invoked
// when the component receives ev.sys.drain — its authorized orderly
// shutdown event. Chainable like Tool/On/Tap. Mirrors the Nim SDK's
// onDrain.
func (c *Component) OnDrain(h func(*Component)) *Component {
	c.drainHandlers = append(c.drainHandlers, h)
	return c
}

// Emit publishes a fire-and-forget event.
func (c *Component) Emit(subject string, payload any) error {
	e := Envelope{V: 1, ID: NewID(), Kind: KindEvent}
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	e.Payload = raw
	data, err := e.Marshal()
	if err != nil {
		return err
	}
	return c.nc.Publish(subject, data)
}

// PublishEnvelope publishes any pre-built envelope to any subject.
func (c *Component) PublishEnvelope(subject string, env Envelope) error {
	data, err := env.Marshal()
	if err != nil {
		return err
	}
	return c.nc.Publish(subject, data)
}

// RequestEnvelope performs a request/reply with a pre-built envelope on an
// arbitrary subject; returns the full reply envelope (result or error).
func (c *Component) RequestEnvelope(subject string, env Envelope, timeout time.Duration) (Envelope, error) {
	data, err := env.Marshal()
	if err != nil {
		return Envelope{}, err
	}
	msg, err := c.nc.Request(subject, data, timeout)
	if err != nil {
		return Envelope{}, fmt.Errorf("request %s: %w", subject, err)
	}
	reply := *ParseEnvelope(msg.Data)
	if reply.ID != env.ID {
		return Envelope{}, fmt.Errorf("request %s: reply id mismatch", subject)
	}
	if reply.Kind != KindResult && reply.Kind != KindError {
		return Envelope{}, fmt.Errorf("request %s: expected result or error envelope", subject)
	}
	return reply, nil
}

// Log publishes a structured log event to ev.log.<name>:
// {component, level, msg, ctx, at}. Mirrors sdk/niffler's log.
func (c *Component) Log(level, msg string, ctx any) error {
	enabled, err := shouldLog(level, os.Getenv("NIF_LOG_LEVEL"))
	if err != nil || !enabled {
		return err
	}
	payload := map[string]any{
		"component": c.Name, "level": level, "msg": msg,
		"at": float64(time.Now().UnixMilli()) / 1000,
	}
	if ctx != nil {
		payload["ctx"] = ctx
	}
	return c.Emit("ev.log."+c.Name, payload)
}

var logLevels = [...]string{"debug", "info", "warn", "error"}

func logLevelIndex(level string) int {
	for i, candidate := range logLevels {
		if level == candidate {
			return i
		}
	}
	return -1
}

func shouldLog(level, threshold string) (bool, error) {
	levelIndex := logLevelIndex(level)
	if levelIndex < 0 {
		return false, fmt.Errorf("invalid log level %q (debug|info|warn|error)", level)
	}
	thresholdIndex := logLevelIndex(threshold)
	if thresholdIndex < 0 {
		thresholdIndex = logLevelIndex("info")
	}
	return levelIndex >= thresholdIndex, nil
}

// Subscribe subscribes to a subject pattern and returns an unsubscribe
// function. Handlers run on their own goroutine, NOT serialized by the
// component mutex — intended for side channels a blocking tool handler
// needs while it runs (e.g. cancellation).
func (c *Component) Subscribe(pattern string, h func(subject string, payload json.RawMessage)) (func(), error) {
	sub, err := c.nc.Subscribe(pattern, func(m *nats.Msg) {
		env := ParseEnvelope(m.Data)
		h(m.Subject, env.Payload)
	})
	if err != nil {
		return nil, fmt.Errorf("subscribe %s: %w", pattern, err)
	}
	return func() { _ = sub.Unsubscribe() }, nil
}

// Request calls a tool on another component over the bus.
// Returns the result value; errors on timeout or error envelope.
func (c *Component) Request(component, tool string, args any, timeout time.Duration) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return c.RequestContext(ctx, component, tool, args)
}

// RequestContext calls a tool and lets the caller cancel the NATS request.
func (c *Component) RequestContext(ctx context.Context, component, tool string, args any) (json.RawMessage, error) {
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	e := Envelope{V: 1, ID: NewID(), Kind: KindCall, Tool: tool, Args: raw, Caller: c.Name}
	data, err := e.Marshal()
	if err != nil {
		return nil, err
	}
	subject := "svc." + component + ".call"
	msg, err := c.nc.RequestWithContext(ctx, subject, data)
	if err != nil {
		return nil, fmt.Errorf("request %s: %w", subject, err)
	}
	resp := ParseEnvelope(msg.Data)
	if resp.ID != e.ID {
		return nil, fmt.Errorf("request %s: reply id mismatch", subject)
	}
	if resp.Kind == KindError {
		if resp.Error != nil {
			return nil, errors.New(resp.Error.Message)
		}
		return nil, errors.New("component error")
	}
	if resp.Kind != KindResult {
		return nil, fmt.Errorf("request %s: expected result envelope", subject)
	}
	return resp.Args, nil
}

// RequestOK is Request plus the {ok, error} result convention: it fails
// when the reply carries ok:false (its "error" field becomes the
// message), so callers stop writing ok-flag chains. Replies without an
// "ok" field pass through unchanged.
func (c *Component) RequestOK(component, tool string, args any, timeout time.Duration) (json.RawMessage, error) {
	raw, err := c.Request(component, tool, args, timeout)
	if err != nil {
		return nil, err
	}
	var reply struct {
		OK    *bool  `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return raw, nil // not the convention's shape — pass through
	}
	if reply.OK != nil && !*reply.OK {
		if reply.Error != "" {
			return nil, errors.New(reply.Error)
		}
		return nil, errors.New("tool call failed")
	}
	return raw, nil
}

// Connect connects to the bus, announces registration and starts serving
// calls in the background. For embedding (e.g. a Wails bridge): call
// Connect, do your thing, call Close. Run() = Connect + block on signal +
// Close.
func (c *Component) Connect() error {
	// .env from cwd and the harness root (existing env always wins)
	LoadDotEnv(".env", filepath.Join(os.Getenv("NIF_ROOT"), ".env"))

	url := os.Getenv("NIF_NATS_URL")
	if url == "" {
		url = "nats://127.0.0.1:4222"
	}
	nc, err := nats.Connect(url,
		nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second))
	if err != nil {
		return fmt.Errorf("connect %s: %w", url, err)
	}
	c.nc = nc
	if c.shutdown == nil {
		c.shutdown = make(chan struct{})
	}

	// queue-grouped call subject: N replicas, one gets each call
	callSubject := "svc." + c.Name + ".call"
	sub, err := nc.QueueSubscribe(callSubject, c.Name, c.handleCall)
	if err != nil {
		return fmt.Errorf("subscribe %s: %w", callSubject, err)
	}
	c.subs = append(c.subs, sub)

	// passive event subscriptions + SDK-managed drain
	c.events = append(c.events, eventBinding{"ev.sys.drain",
		func(c *Component, subject string, p json.RawMessage) {
			for _, h := range c.drainHandlers {
				func() {
					defer func() {
						if r := recover(); r != nil {
							slog.Error("drain handler panic", "component", c.Name, "panic", r)
						}
					}()
					h(c)
				}()
			}
			c.signalShutdown()
		}})
	for _, e := range c.events {
		e := e
		s, err := nc.Subscribe(e.pattern, func(m *nats.Msg) {
			c.mu.Lock()
			defer c.mu.Unlock()
			env := ParseEnvelope(m.Data)
			e.handler(c.handlerView(), m.Subject, env.Payload)
		})
		if err != nil {
			return fmt.Errorf("subscribe %s: %w", e.pattern, err)
		}
		c.subs = append(c.subs, s)
	}

	// raw wire taps (serialized like events)
	for _, t := range c.taps {
		t := t
		s, err := nc.Subscribe(t.pattern, func(m *nats.Msg) {
			c.mu.Lock()
			defer c.mu.Unlock()
			t.handler(c.handlerView(), m.Subject, m.Data)
		})
		if err != nil {
			return fmt.Errorf("subscribe %s: %w", t.pattern, err)
		}
		c.subs = append(c.subs, s)
	}

	if err := c.announce("reg.publish"); err != nil {
		return err
	}
	if err := c.nc.Flush(); err != nil {
		return fmt.Errorf("flush subscriptions: %w", err)
	}
	slog.Info("online", "component", c.Name, "version", c.Version, "url", url,
		"tools", len(c.tools))
	return nil
}

// Connected reports whether the component is connected to the bus.
func (c *Component) Connected() bool {
	return c.nc != nil && c.nc.IsConnected()
}

// Close announces departure, drains subscriptions and closes the connection.
func (c *Component) Close() {
	if c.inHandler && c.owner != nil {
		go c.owner.Close()
		return
	}
	c.closeMu.Lock()
	defer c.closeMu.Unlock()
	if c.nc == nil {
		return
	}
	_ = c.announce("reg.depart")
	for _, s := range c.subs {
		_ = s.Drain()
	}
	deadline := time.Now().Add(5 * time.Second)
	for _, s := range c.subs {
		for s.IsValid() && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
	}
	_ = c.nc.FlushTimeout(time.Second)
	c.nc.Close()
	c.nc = nil
}

// Run connects, serves calls until SIGTERM/SIGINT or ev.sys.drain, then
// departs gracefully and exits the process.
func (c *Component) Run() error {
	if err := c.Connect(); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	select {
	case <-ctx.Done():
	case <-c.shutdown:
	}

	c.Close()
	return nil
}

func (c *Component) signalShutdown() {
	if c.owner != nil && c.owner != c {
		c.owner.signalShutdown()
		return
	}
	c.shutdownOnce.Do(func() { close(c.shutdown) })
}

func (c *Component) announce(subject string) error {
	tools := make([]map[string]any, 0, len(c.tools))
	for _, t := range c.tools {
		tools = append(tools, map[string]any{"name": t.Name, "schema": t.Schema})
	}
	payload := map[string]any{
		"name": c.Name, "version": c.Version, "pid": os.Getpid(), "tools": tools,
	}
	if len(c.slash) > 0 {
		payload["slash"] = c.slash
	}
	if c.Client {
		payload["client"] = true
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return c.nc.Publish(subject, data)
}

func (c *Component) handleCall(m *nats.Msg) {
	c.mu.Lock()
	defer c.mu.Unlock()

	env := ParseEnvelope(m.Data)
	var resp Envelope
	if env.Kind != KindCall {
		resp = Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "bad-envelope", Message: "expected call envelope"}}
	} else {
		var found bool
		for _, t := range c.tools {
			if t.Name == env.Tool {
				found = true
				res, err := t.handler(c.handlerView(), env.Args)
				if err != nil {
					resp = Envelope{V: 1, ID: env.ID, Kind: KindError,
						Error: &ErrorInfo{Code: "boom", Message: err.Error()}}
				} else {
					raw, _ := json.Marshal(res)
					resp = Envelope{V: 1, ID: env.ID, Kind: KindResult, Args: raw}
				}
				break
			}
		}
		if !found {
			resp = Envelope{V: 1, ID: env.ID, Kind: KindError,
				Error: &ErrorInfo{Code: "no-tool",
					Message: fmt.Sprintf("component %s has no tool %q", c.Name, env.Tool)}}
		}
	}
	data, err := resp.Marshal()
	if err == nil {
		_ = m.Respond(data)
	}
}
