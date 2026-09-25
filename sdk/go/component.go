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
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

// DieWithParent asks the kernel to SIGTERM this process when its parent
// dies (even on SIGKILL). Run() does this automatically; custom main flows
// (Connect/Wait/Close) must call it themselves. See pdeathsig_linux.go /
// pdeathsig_other.go for the platform-specific implementation.
func DieWithParent() { dieWithParent() }

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
	Name       string         `json:"name"`
	Schema     map[string]any `json:"schema"`
	handler    ToolHandler
	concurrent bool
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
	handlerMu     sync.RWMutex // serial handlers are exclusive; concurrent tools share
	// Call dispatch. The NATS subscription callback only enqueues; deliverLoop
	// owns all scheduling state and spawns handler goroutines. A serialized
	// tool must never stall delivery of unrelated calls behind it (a background
	// models refresh held llm_resolve and every chat for the length of a
	// streaming turn), so nothing here ever waits on handlerMu inside a
	// callback. handlerDone reports a finished handler back to deliverLoop;
	// dispatchStop/dispatchDone bound Close to accepted-but-unfinished work.
	callQueue         chan *nats.Msg
	handlerDone       chan bool // true = a serialized handler finished
	dispatchStop      chan struct{}
	dispatchDone      chan struct{}
	dispatchMu        sync.Mutex // guards dispatchStarted (lifecycle, not scheduling)
	dispatchStarted   bool
	dispatchStopOnce  sync.Once
	concurrentLimit   int
	closeMu           sync.Mutex
	shutdown          chan struct{}
	shutdownOnce      sync.Once
	reconnectStop     chan struct{} // stops the reconnect watch at Close
	reconnectStopOnce sync.Once
	owner             *Component
	inHandler         bool
	deferAnnounce     bool
	contractMu        sync.RWMutex // protects setup while deferred calls/events can arrive
	ready             bool
	// Re-attach (issue #3): callbacks for a successful post-outage re-attach;
	// guarded so a concurrent reconnectWatch tick cannot race registration.
	reattachedMu       sync.Mutex
	reattachedHandlers []func(*Component)
	// Idle work (see OnIdle): registered before Connect, run by its own
	// ticker goroutine under the serial handler lock.
	idleEvery   time.Duration
	idleHandler func(*Component)
	idleStop    chan struct{}
}

const defaultConcurrentLimit = 16

// defaultCallQueueLimit bounds accepted-but-not-yet-running calls. The queue
// only ever holds work waiting on the serial worker or a free concurrent slot;
// a full queue makes the NATS callback block instead of growing without bound,
// which is still far better than blocking on a multi-minute handler.
const defaultCallQueueLimit = 128

// New creates a component with the given bus identity.
func New(name, version string) *Component {
	c := &Component{
		Name:            name,
		Version:         version,
		shutdown:        make(chan struct{}),
		reconnectStop:   make(chan struct{}),
		concurrentLimit: defaultConcurrentLimit,
		callQueue:       make(chan *nats.Msg, defaultCallQueueLimit),
		handlerDone:     make(chan bool),
		dispatchStop:    make(chan struct{}),
		dispatchDone:    make(chan struct{}),
	}
	c.owner = c
	return c
}

func (c *Component) handlerView() *Component {
	c.contractMu.RLock()
	defer c.contractMu.RUnlock()
	return &Component{
		Name: c.Name, Version: c.Version, nc: c.nc, tools: c.tools,
		events: c.events, taps: c.taps, subs: c.subs, shutdown: c.shutdown,
		drainHandlers: c.drainHandlers,
		owner:         c, inHandler: true,
	}
}

// startDispatch launches the delivery loop that owns call scheduling. It runs
// for the life of the connection; NATS callbacks only enqueue, so a long
// handler (a streaming chat) can never stall delivery of unrelated calls.
func (c *Component) startDispatch() {
	c.dispatchMu.Lock()
	defer c.dispatchMu.Unlock()
	if c.dispatchStarted {
		return
	}
	c.dispatchStarted = true
	go c.deliverLoop()
}

// stopDispatch ends the delivery loop and waits for every running handler to
// finish, so replies owed to callers are preserved across Close. Calls that
// were accepted but never started are refused instead of dropped silently.
// Close serializes callers through closeMu, so this runs once per component.
func (c *Component) stopDispatch() {
	c.dispatchMu.Lock()
	started := c.dispatchStarted
	c.dispatchStarted = false
	c.dispatchMu.Unlock()
	if !started {
		return
	}
	c.dispatchStopOnce.Do(func() { close(c.dispatchStop) })
	<-c.dispatchDone
}

// pendingCall is one resolved call waiting for a handler slot.
type pendingCall struct {
	m    *nats.Msg
	env  *Envelope
	tool *Tool
}

// deliverLoop is the single scheduler for accepted calls. It never runs a
// handler itself and never parses or waits inside a NATS callback; the
// callback only enqueues, so a long handler (a streaming chat) can never
// stall delivery of unrelated calls. That is the fix for the stall where the
// models refresh's serialized llm_models_source held the writer barrier
// behind a streaming chat and the blocked callback stopped llm_resolve and
// every new chat for the length of the turn.
//
// Scheduling:
//   - concurrent calls drain up to ConcurrentLimit, independent of a waiting
//     serialized call (a serialized tool must not block later concurrent
//     work);
//   - one serialized call at a time, started only when no concurrent handler
//     is running, so the handlerMu write lock is acquired, never parked (a
//     parked writer would block the readers behind it too);
//   - event handlers and taps keep taking handlerMu exclusively, exactly as
//     before; they may hold a serialized call back briefly, never the reverse.
func (c *Component) deliverLoop() {
	defer close(c.dispatchDone)
	var (
		serialQueue     []*pendingCall
		concurrentQueue []*pendingCall
		serialRunning   bool
		concurrent      int
	)
	startSerial := func(pc *pendingCall) {
		serialRunning = true
		go func() {
			// Acquired, not waited on: concurrent == 0 held this decision.
			c.handlerMu.Lock()
			c.invokeTool(pc.m, pc.env, pc.tool)
			c.handlerMu.Unlock()
			c.handlerDone <- true
		}()
	}
	startConcurrent := func(pc *pendingCall) {
		concurrent++
		go func() {
			c.handlerMu.RLock()
			c.invokeTool(pc.m, pc.env, pc.tool)
			c.handlerMu.RUnlock()
			c.handlerDone <- false
		}()
	}
	tryStart := func() {
		// Serialized calls first when the barrier is free: a continuous
		// concurrent queue must not starve a waiting writer (events and taps
		// need that barrier too).
		if !serialRunning && concurrent == 0 && len(serialQueue) > 0 {
			pc := serialQueue[0]
			serialQueue = serialQueue[1:]
			startSerial(pc)
			return
		}
		for len(concurrentQueue) > 0 && concurrent < c.concurrentLimit {
			pc := concurrentQueue[0]
			concurrentQueue = concurrentQueue[1:]
			startConcurrent(pc)
		}
	}
	refuse := func(pc *pendingCall) {
		c.respond(pc.m, Envelope{V: 1, ID: pc.env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "shutting-down",
				Message: "component is shutting down"}})
	}
	for {
		tryStart()
		select {
		case m := <-c.callQueue:
			if pc, ok := c.resolveCall(m); ok {
				if pc.tool.concurrent {
					concurrentQueue = append(concurrentQueue, pc)
				} else {
					serialQueue = append(serialQueue, pc)
				}
			}
		case isSerial := <-c.handlerDone:
			if isSerial {
				serialRunning = false
			} else {
				concurrent--
			}
		case <-c.dispatchStop:
			// Drain running handlers, then refuse every accepted-but-unstarted
			// call so no caller is left without a reply.
			for serialRunning || concurrent > 0 {
				if <-c.handlerDone {
					serialRunning = false
				} else {
					concurrent--
				}
			}
			for {
				select {
				case m := <-c.callQueue:
					if pc, ok := c.resolveCall(m); ok {
						refuse(pc)
					}
				default:
					goto drained
				}
			}
		drained:
			for _, pc := range serialQueue {
				refuse(pc)
			}
			for _, pc := range concurrentQueue {
				refuse(pc)
			}
			return
		}
	}
}

// resolveCall parses and validates one accepted call, answering malformed,
// not-ready and unknown-tool calls directly. ok=false means the caller has
// already been answered.
func (c *Component) resolveCall(m *nats.Msg) (*pendingCall, bool) {
	env := ParseEnvelope(m.Data)
	if env.Kind != KindCall {
		c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "bad-envelope", Message: "expected call envelope"}})
		return nil, false
	}
	c.contractMu.RLock()
	ready := c.ready
	var tool *Tool
	if ready {
		for i := range c.tools {
			if c.tools[i].Name == env.Tool {
				copy := c.tools[i]
				tool = &copy
				break
			}
		}
	}
	c.contractMu.RUnlock()
	if !ready {
		c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "not-ready", Message: "component contract is not ready"}})
		return nil, false
	}
	if tool == nil {
		c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "no-tool",
				Message: fmt.Sprintf("component %s has no tool %q", c.Name, env.Tool)}})
		return nil, false
	}
	return &pendingCall{m: m, env: env, tool: tool}, true
}

// Tool registers a serialized tool. It runs exclusively with respect to all
// other tool, event, and tap handlers in this component. Chainable:
// New("x", "1").Tool(...).Tool(...).Run().
func (c *Component) Tool(name string, schema map[string]any, h ToolHandler) *Component {
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if c.ready {
		panic("Tool called after Announce")
	}
	c.tools = append(c.tools, Tool{Name: name, Schema: schema, handler: h})
	return c
}

// ToolConcurrent registers an explicitly concurrency-safe tool. Calls to
// concurrent tools may overlap each other, but never overlap serialized tools,
// event handlers, or taps. The component author must synchronize any mutable
// state shared by concurrent handlers. It must not synchronously request a
// serialized tool on the same component, which would wait on its own shared
// lock. This server-side execution choice is independent of the runner-side
// x-harness.parallel scheduling hint.
func (c *Component) ToolConcurrent(name string, schema map[string]any, h ToolHandler) *Component {
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if c.ready {
		panic("ToolConcurrent called after Announce")
	}
	c.tools = append(c.tools, Tool{
		Name: name, Schema: schema, handler: h, concurrent: true,
	})
	return c
}

// ConcurrentLimit sets the maximum number of ToolConcurrent handlers running
// at once. It must be called before Connect or Run; values below one become
// one. The default is 16.
func (c *Component) ConcurrentLimit(limit int) *Component {
	if limit < 1 {
		limit = 1
	}
	c.concurrentLimit = limit
	return c
}

// Slash registers a slash command for interactive UIs (docs/WIRE.md).
// Chainable: New("x","1").Tool(...).Slash(...).Run(). The target tool
// (cmd.Tool, or cmd.Name when empty) must be registered by this component.
func (c *Component) Slash(cmd SlashCommand) *Component {
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if c.ready {
		panic("Slash called after Announce")
	}
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
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if c.ready {
		panic("OnDrain called after Announce")
	}
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
	if reply.Error != "" {
		return nil, errors.New(reply.Error)
	}
	if reply.OK != nil && !*reply.OK {
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

	url, err := c.dial()
	if err != nil {
		return err
	}
	nc := c.nc
	if c.shutdown == nil {
		c.shutdown = make(chan struct{})
	}
	// concurrentLimit is initialized in New and only mutated by
	// ConcurrentLimit (documented before Connect); the delivery loop reads it
	// after this point, so no write happens here.
	// The delivery loop starts with the connection: callbacks enqueue, the
	// loop schedules serialized and concurrent handlers.
	c.startDispatch()
	// Idle work starts with the connection (registered before Connect) and
	// stops in Close.
	c.startIdle()

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
			c.handlerMu.Lock()
			defer c.handlerMu.Unlock()
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
			c.handlerMu.Lock()
			defer c.handlerMu.Unlock()
			t.handler(c.handlerView(), m.Subject, m.Data)
		})
		if err != nil {
			return fmt.Errorf("subscribe %s: %w", t.pattern, err)
		}
		c.subs = append(c.subs, s)
	}

	if err := c.nc.Flush(); err != nil {
		return fmt.Errorf("flush subscriptions: %w", err)
	}
	if !c.deferAnnounce {
		if err := c.Announce(); err != nil {
			return err
		}
		if err := c.nc.Flush(); err != nil {
			return fmt.Errorf("flush registration: %w", err)
		}
		slog.Info("online", "component", c.Name, "version", c.Version, "url", url,
			"tools", len(c.tools))
	} else {
		slog.Info("connected (announce deferred)", "component", c.Name,
			"version", c.Version, "url", url)
	}
	// Reconnect watch (issue #3): nats.go reconnects forever on the SAME url,
	// but a server that stays down past its reconnect buffer, or a harness
	// restarted on a NEW port, leaves the component alive but deaf — no
	// reg.depart was sent, so the catalog keeps advertising tools nothing can
	// reach. A ticker goroutine measures the connection: a Reconnect/Disconnect
	// notice followed by a failed Flush past NIF_RECONNECT_GRACE_S (default
	// 180s, deliberately above nats.go's own patience) triggers a re-dial to a
	// re-resolved URL, a resubscribe of every pattern, and a re-announce.
	go c.reconnectWatch(url)
	return nil
}

// dial resolves the bus URL and connects. Resolution order: NIF_NATS_URL
// (explicit always wins), the harness root's var/nats-url discovery file
// (a restarted core usually binds a new port), then the well-known port.
func (c *Component) dial() (string, error) {
	url := os.Getenv("NIF_NATS_URL")
	if url == "" {
		if r := os.Getenv("NIF_ROOT"); r != "" {
			if data, err := os.ReadFile(filepath.Join(r, "var", "nats-url")); err == nil {
				if u := strings.TrimSpace(string(data)); u != "" {
					url = u
				}
			}
		}
	}
	if url == "" {
		url = "nats://127.0.0.1:4222"
	}
	nc, err := nats.Connect(url,
		nats.MaxReconnects(-1),
		nats.ReconnectWait(time.Second))
	if err != nil {
		return "", fmt.Errorf("connect %s: %w", url, err)
	}
	c.nc = nc
	return url, nil
}

// resubscribe installs the call subject, event bindings and taps on the
// CURRENT connection. Extracted from Connect so a re-attach can rebuild the
// surface on a fresh connection: subscriptions belong to their connection
// and do not survive a redial. The drain binding is added by Connect —
// exactly once per process, never per attach.
func (c *Component) resubscribe() error {
	nc := c.nc

	// queue-grouped call subject: N replicas, one gets each call
	callSubject := "svc." + c.Name + ".call"
	sub, err := nc.QueueSubscribe(callSubject, c.Name, c.handleCall)
	if err != nil {
		return fmt.Errorf("subscribe %s: %w", callSubject, err)
	}
	c.subs = append(c.subs, sub)

	for _, e := range c.events {
		e := e
		s, err := nc.Subscribe(e.pattern, func(m *nats.Msg) {
			c.handlerMu.Lock()
			defer c.handlerMu.Unlock()
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
			c.handlerMu.Lock()
			defer c.handlerMu.Unlock()
			t.handler(c.handlerView(), m.Subject, m.Data)
		})
		if err != nil {
			return fmt.Errorf("subscribe %s: %w", t.pattern, err)
		}
		c.subs = append(c.subs, s)
	}

	if err := c.nc.Flush(); err != nil {
		return fmt.Errorf("flush subscriptions: %w", err)
	}
	return nil
}

// reattachCandidates lists bus URLs to try when re-attaching, most likely
// first: the env URL (the same bus may simply have returned), the discovery
// file (a restarted core usually binds a new port), the well-known port.
func (c *Component) reattachCandidates() []string {
	var urls []string
	seen := map[string]bool{}
	add := func(u string) {
		if u != "" && !seen[u] {
			seen[u] = true
			urls = append(urls, u)
		}
	}
	add(os.Getenv("NIF_NATS_URL"))
	if r := os.Getenv("NIF_ROOT"); r != "" {
		if data, err := os.ReadFile(filepath.Join(r, "var", "nats-url")); err == nil {
			add(strings.TrimSpace(string(data)))
		}
	}
	add("nats://127.0.0.1:4222")
	return urls
}

// reconnectWatch measures the connection every 2s. Disconnect/Reconnecting
// notices start the unhealthy clock; a Flush success resets it. Unhealthy
// past reconnectGraceSecs triggers a re-dial, resubscribe and re-announce —
// issue #3's alive-but-deaf component recovers without a process restart.
func (c *Component) reconnectWatch(initialURL string) {
	grace := 180 * time.Second
	if v := os.Getenv("NIF_RECONNECT_GRACE_S"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			grace = time.Duration(secs) * time.Second
		}
	}
	var unhealthySince time.Time
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-c.shutdown:
			return
		case <-c.reconnectStop:
			return
		case <-tick.C:
		}
		// Snapshot under contractMu: Close (and a re-attach) write c.nc, and
		// handlerView reads it the same way — one lock, no torn reads.
		c.contractMu.RLock()
		nc := c.nc
		c.contractMu.RUnlock()
		if nc == nil {
			continue
		}
		status := nc.Status()
		if status == nats.CONNECTED {
			// Trust a successful round trip over the status flag alone.
			if err := nc.Flush(); err == nil {
				unhealthySince = time.Time{}
				continue
			}
		} else if status != nats.DISCONNECTED && status != nats.RECONNECTING &&
			status != nats.CLOSED {
			continue
		}
		if unhealthySince.IsZero() {
			unhealthySince = time.Now()
			continue
		}
		if time.Since(unhealthySince) < grace {
			continue
		}
		// Past the grace: re-dial, resubscribe, re-announce.
		slog.Warn("bus unreachable past the reconnect grace — re-attaching",
			"component", c.Name, "url", initialURL,
			"unhealthy_for", time.Since(unhealthySince).Round(time.Second))
		if err := c.reattachNow(); err != nil {
			slog.Error("re-attach failed — retrying", "component", c.Name, "err", err)
			continue // unhealthySince stays set: retry on the next tick
		}
		unhealthySince = time.Time{}
	}
}

// reconnectNow replaces the connection: close the dead one, dial a
// freshly-resolved URL, rebuild every subscription, re-announce. The old
// subscriptions are drained first so no handler fires on a dying connection.
func (c *Component) reconnectNow() error {
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if c.nc != nil {
		for _, s := range c.subs {
			_ = s.Drain()
		}
		c.subs = nil
		c.nc.Close()
		c.nc = nil
	}
	var lastErr error
	for _, url := range c.reattachCandidates() {
		nc, err := nats.Connect(url,
			nats.MaxReconnects(-1),
			nats.ReconnectWait(time.Second))
		if err != nil {
			lastErr = fmt.Errorf("connect %s: %w", url, err)
			continue
		}
		c.nc = nc
		if err := c.resubscribe(); err != nil {
			lastErr = err
			nc.Close()
			c.nc = nil
			continue
		}
		if err := c.announceLocked("reg.publish"); err != nil {
			lastErr = err
			nc.Close()
			c.nc = nil
			continue
		}
		slog.Info("reattached after the outage — resubscribed and re-announced",
			"component", c.Name, "url", url)
		return nil
	}
	return lastErr
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
	// Stop the reconnect watch before tearing the connection down: its
	// goroutine must not observe (or act on) a half-closed component.
	c.reconnectStopOnce.Do(func() { close(c.reconnectStop) })
	_ = c.announce("reg.depart")
	// The rest mutates exactly what the reconnect watch reads under
	// contractMu (c.nc, c.subs): hold the same lock so a re-attach in flight
	// cannot interleave with teardown. Two SECTIONS, never spanning
	// stopDispatch: a running handler may still need handlerView's RLock, so
	// the lock must not be held while waiting on handlers (deadlock). No
	// inverse nesting exists — nothing takes closeMu under contractMu.
	c.contractMu.Lock()
	for _, s := range c.subs {
		_ = s.Drain()
	}
	deadline := time.Now().Add(5 * time.Second)
	for _, s := range c.subs {
		for s.IsValid() && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
	}
	c.contractMu.Unlock()
	// Stop scheduling and wait for every accepted handler to finish before
	// closing the shared NATS connection, so replies owed to callers are
	// preserved (a handler may still be streaming its response).
	c.stopDispatch()
	c.stopIdle()
	c.contractMu.Lock()
	_ = c.nc.FlushTimeout(time.Second)
	c.nc.Close()
	c.nc = nil
	c.contractMu.Unlock()
}

// Run connects, serves calls until SIGTERM/SIGINT or ev.sys.drain, then
// departs gracefully and exits the process.
func (c *Component) Run() error {
	dieWithParent()
	if err := c.Connect(); err != nil {
		return err
	}
	c.Wait()
	c.Close()
	return nil
}

// reattachNow replaces the connection (reconnectNow) and then runs every
// OnReattached handler. Deferred-announce components (mcp-bridge) use the
// hook to re-publish their contract on the fresh connection.
func (c *Component) reattachNow() error {
	if err := c.reconnectNow(); err != nil {
		return err
	}
	c.reattachedMu.Lock()
	handlers := append([]func(*Component){}, c.reattachedHandlers...)
	c.reattachedMu.Unlock()
	for _, h := range handlers {
		func() {
			defer func() {
				if r := recover(); r != nil {
					slog.Error("reattached handler panic", "component", c.Name, "panic", r)
				}
			}()
			h(c)
		}()
	}
	return nil
}

// OnReattached registers a callback for a successful re-attach after a bus
// outage (issue #3): the connection was re-dialed, subscriptions rebuilt and
// reg.publish re-sent. Deferred-announce components re-announce here (their
// contract may have drifted while disconnected); ordinary components need
// no hook — the SDK's re-attach already re-announced the frozen contract.
func (c *Component) OnReattached(h func(*Component)) *Component {
	c.reattachedMu.Lock()
	c.reattachedHandlers = append(c.reattachedHandlers, h)
	c.reattachedMu.Unlock()
	return c
}

// DeferAnnounce: Connect() performs no reg.publish; call Announce() once the
// tool contract is complete. For components that must load their config (or
// otherwise discover their tools) before they can declare a contract — the
// catalog rejects a differing re-announce, so the first publish must already
// carry the final toolset. Calls before Announce receive not-ready without
// touching the partially built contract. Tool/Slash/OnDrain registration
// is frozen by Announce; events and taps must be installed before Connect.
func (c *Component) DeferAnnounce() *Component {
	c.deferAnnounce = true
	return c
}

// Announce publishes (or republishes) the current tool contract to the
// catalog. Required after Connect when DeferAnnounce is set.
func (c *Component) Announce() error {
	c.contractMu.Lock()
	defer c.contractMu.Unlock()
	if err := c.announceLocked("reg.publish"); err != nil {
		return err
	}
	c.ready = true
	return c.nc.Flush()
}

// Wait blocks until SIGTERM/SIGINT or ev.sys.drain. Call Close afterwards.
// Run is Connect + Wait + Close; use Wait directly when Connect happened
// earlier (e.g. deferred-announce setup in between).
// OnIdle runs handler periodically for as long as the component is connected:
// the Go SDK's counterpart of the Nim SDK's onIdle, for work that has no
// request to ride on (reaping background children, health probes, cache
// refreshes — components/processes uses it to notice a child's exit without
// anyone polling).
//
// Semantics, and where they differ from Nim: the handler runs on its own
// ticker goroutine, but takes the same lock a *serial* handler takes, so it
// never interleaves with a serial tool call touching the same state. Concurrent
// tools (ToolConcurrent) hold only the read lock, so an idle handler can
// overlap them — keep an idle handler to component-local state you would
// protect anyway. Panics are recovered and logged, never fatal.
//
// Register BEFORE Connect (like events and taps). One handler per component: a
// second registration replaces the first. The interval is floored at 10ms.
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component {
	if interval < 10*time.Millisecond {
		interval = 10 * time.Millisecond
	}
	c.idleEvery = interval
	c.idleHandler = handler
	return c
}

// idleLoop ticks the registered idle handler until the component closes.
func (c *Component) idleLoop(stop chan struct{}) {
	ticker := time.NewTicker(c.idleEvery)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			c.handlerMu.Lock()
			func() {
				defer func() {
					if r := recover(); r != nil {
						slog.Error("idle handler panic", "component", c.Name, "panic", r)
					}
				}()
				c.idleHandler(c)
			}()
			c.handlerMu.Unlock()
		}
	}
}

func (c *Component) startIdle() {
	if c.idleHandler == nil || c.idleStop != nil {
		return
	}
	c.idleStop = make(chan struct{})
	go c.idleLoop(c.idleStop)
}

func (c *Component) stopIdle() {
	if c.idleStop != nil {
		close(c.idleStop)
		c.idleStop = nil
	}
}

func (c *Component) Wait() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	select {
	case <-ctx.Done():
	case <-c.shutdown:
	}
}

func (c *Component) signalShutdown() {
	if c.owner != nil && c.owner != c {
		c.owner.signalShutdown()
		return
	}
	c.shutdownOnce.Do(func() { close(c.shutdown) })
}

func (c *Component) announce(subject string) error {
	c.contractMu.RLock()
	defer c.contractMu.RUnlock()
	return c.announceLocked(subject)
}

func (c *Component) announceLocked(subject string) error {
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
	// Enqueue only: never run a handler (or wait for one) inside the NATS
	// subscription callback. nats.go invokes one subscription's callbacks
	// serially, so a callback blocked on a handler would also stop delivery
	// of every call queued behind it — the failure mode where a background
	// models-source call held llm_resolve and every chat off for minutes.
	select {
	case c.callQueue <- m:
	case <-c.dispatchStop:
		// Shutting down: refuse rather than enqueue work nobody will serve.
		c.replyNoTool(m)
	}
}

// replyNoTool refuses a call the delivery loop will not run (shutdown path).
func (c *Component) replyNoTool(m *nats.Msg) {
	env := ParseEnvelope(m.Data)
	c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
		Error: &ErrorInfo{Code: "shutting-down",
			Message: "component is shutting down"}})
}

func (c *Component) invokeTool(m *nats.Msg, env *Envelope, tool *Tool) {
	res, err := tool.handler(c.handlerView(), env.Args)
	if err != nil {
		c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "boom", Message: err.Error()}})
		return
	}
	raw, err := json.Marshal(res)
	if err != nil {
		c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindError,
			Error: &ErrorInfo{Code: "boom", Message: err.Error()}})
		return
	}
	c.respond(m, Envelope{V: 1, ID: env.ID, Kind: KindResult, Args: raw})
}

func (c *Component) respond(m *nats.Msg, resp Envelope) {
	data, err := resp.Marshal()
	if err != nil {
		slog.Error("marshal tool reply", "component", c.Name, "error", err)
		return
	}
	if err := m.Respond(data); err != nil {
		// A caller timing out/cancelling before a long handler finishes is normal.
		slog.Debug("publish tool reply", "component", c.Name, "error", err)
	}
}
