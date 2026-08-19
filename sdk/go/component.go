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
	"strings"
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

// Tool is a registered tool: LLM-facing schema plus its handler.
type Tool struct {
	Name    string         `json:"name"`
	Schema  map[string]any `json:"schema"`
	handler ToolHandler
}

type eventBinding struct {
	pattern string
	handler EventHandler
}

// Component is a Niffler component.
type Component struct {
	Name    string
	Version string

	nc     *nats.Conn
	tools  []Tool
	events []eventBinding
	subs   []*nats.Subscription
	mu     sync.Mutex // serializes handlers (mirrors Nim SDK's single thread)
}

// New creates a component with the given bus identity.
func New(name, version string) *Component {
	return &Component{Name: name, Version: version}
}

// Tool registers a tool. Chainable: New("x","1").Tool(...).Tool(...).Run()
func (c *Component) Tool(name string, schema map[string]any, h ToolHandler) *Component {
	c.tools = append(c.tools, Tool{Name: name, Schema: schema, handler: h})
	return c
}

// On subscribes to an event pattern (exact subject, ">" or "foo.>").
func (c *Component) On(pattern string, h EventHandler) *Component {
	c.events = append(c.events, eventBinding{pattern, h})
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
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	e := Envelope{V: 1, ID: NewID(), Kind: KindCall, Tool: tool, Args: raw}
	data, err := e.Marshal()
	if err != nil {
		return nil, err
	}
	subject := "svc." + component + ".call"
	msg, err := c.nc.Request(subject, data, timeout)
	if err != nil {
		return nil, fmt.Errorf("request %s: %w", subject, err)
	}
	resp := ParseEnvelope(msg.Data)
	if resp.Kind == KindError {
		if resp.Error != nil {
			return nil, errors.New(resp.Error.Message)
		}
		return nil, errors.New("component error")
	}
	return resp.Args, nil
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

	// queue-grouped call subject: N replicas, one gets each call
	callSubject := "svc." + c.Name + ".call"
	sub, err := nc.QueueSubscribe(callSubject, c.Name, c.handleCall)
	if err != nil {
		return fmt.Errorf("subscribe %s: %w", callSubject, err)
	}
	c.subs = append(c.subs, sub)

	// passive event subscriptions + SDK-managed drain
	c.events = append(c.events, eventBinding{"ev.sys.drain",
		func(c *Component, subject string, p json.RawMessage) { /* handled via Close */ }})
	for _, e := range c.events {
		s, err := nc.Subscribe(e.pattern, func(m *nats.Msg) {
			c.mu.Lock()
			defer c.mu.Unlock()
			env := ParseEnvelope(m.Data)
			for _, b := range c.events {
				if matches(b.pattern, m.Subject) {
					b.handler(c, m.Subject, env.Payload)
				}
			}
		})
		if err != nil {
			return fmt.Errorf("subscribe %s: %w", e.pattern, err)
		}
		c.subs = append(c.subs, s)
	}

	if err := c.announce("reg.publish"); err != nil {
		return err
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
	if c.nc == nil {
		return
	}
	_ = c.announce("reg.depart")
	for _, s := range c.subs {
		_ = s.Drain()
	}
	time.Sleep(200 * time.Millisecond)
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
	<-ctx.Done()

	c.Close()
	return nil
}

func (c *Component) announce(subject string) error {
	tools := make([]map[string]any, 0, len(c.tools))
	for _, t := range c.tools {
		tools = append(tools, map[string]any{"name": t.Name, "schema": t.Schema})
	}
	payload := map[string]any{
		"name": c.Name, "version": c.Version, "pid": os.Getpid(), "tools": tools,
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
				res, err := t.handler(c, env.Args)
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

func matches(pattern, subject string) bool {
	if pattern == subject {
		return true
	}
	if pattern == ">" {
		return true
	}
	if strings.HasSuffix(pattern, ".>") {
		return strings.HasPrefix(subject, pattern[:len(pattern)-2])
	}
	return false
}
