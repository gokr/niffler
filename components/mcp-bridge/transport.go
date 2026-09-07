package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// captureTransport owns a low-level close handle even if initialization fails.
// abort can precede Connect finishing; a late connection is closed immediately.
type captureTransport struct {
	mcp.Transport
	mu      sync.Mutex
	conn    mcp.Connection
	aborted bool
}

func (t *captureTransport) Connect(ctx context.Context) (mcp.Connection, error) {
	t.mu.Lock()
	aborted := t.aborted
	t.mu.Unlock()
	if aborted {
		return nil, context.Canceled
	}
	// Legacy SSE retains the Connect request context for its stream. Bound
	// establishment with ctx, then detach the established stream's lifetime.
	life, cancel := context.WithCancel(context.WithoutCancel(ctx))
	stop := context.AfterFunc(ctx, cancel)
	conn, err := t.Transport.Connect(life)
	stopped := stop()
	if err != nil || !stopped || ctx.Err() != nil {
		cancel()
		if conn != nil {
			_ = conn.Close()
		}
		if err == nil {
			err = ctx.Err()
		}
		return nil, err
	}
	conn = &contextConnection{Connection: conn, cancel: cancel}
	t.mu.Lock()
	t.conn = conn
	t.mu.Unlock()
	return conn, err
}

type contextConnection struct {
	mcp.Connection
	cancel context.CancelFunc
}

func (c *contextConnection) Close() error { c.cancel(); return c.Connection.Close() }

func (t *captureTransport) abort() {
	t.mu.Lock()
	t.aborted = true
	conn := t.conn
	t.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

// Only inject credentials at their configured origin. Redirects are rejected
// across origins even when no secret headers are present (including SSE POSTs).
type headerTransport struct {
	base    http.RoundTripper
	headers map[string]string
	origin  *url.URL
}

func sameOrigin(a, b *url.URL) bool {
	port := func(u *url.URL) string {
		if p := u.Port(); p != "" {
			return p
		}
		if u.Scheme == "https" {
			return "443"
		}
		return "80"
	}
	return strings.EqualFold(a.Scheme, b.Scheme) && strings.EqualFold(a.Hostname(), b.Hostname()) && port(a) == port(b)
}
func (h headerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if h.origin == nil || !sameOrigin(h.origin, req.URL) {
		return nil, errors.New("MCP request to a different origin refused")
	}
	r := req.Clone(req.Context())
	// Streamable transport cleanup issues DELETE with a session context;
	// bound it independently so shutdown cannot hang on a remote endpoint.
	if req.Method == http.MethodDelete {
		ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
		defer cancel()
		r = req.Clone(ctx)
	}
	for k, v := range h.headers {
		r.Header.Set(k, v)
	}
	return h.base.RoundTrip(r)
}
func makeTransport(cfg *serverConfig) (mcp.Transport, error) {
	switch cfg.transport() {
	case "stdio":
		if strings.TrimSpace(cfg.Command) == "" {
			return nil, errors.New("stdio server needs a command")
		}
		return &guardTransport{cfg: cfg}, nil
	case "http", "sse":
		endpoint, err := expandEnvRefs(cfg.URL)
		if err != nil {
			return nil, fmt.Errorf("url: %w", err)
		}
		headers, err := expandEnvMap(cfg.Headers)
		if err != nil {
			return nil, fmt.Errorf("headers: %w", err)
		}
		u, err := url.Parse(endpoint)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil {
			return nil, errors.New("MCP URL must be http(s), without embedded credentials")
		}
		base := http.DefaultTransport.(*http.Transport).Clone()
		base.ResponseHeaderTimeout = 30 * time.Second
		client := &http.Client{Transport: headerTransport{base, headers, u}, CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many MCP redirects")
			}
			if !sameOrigin(u, req.URL) {
				return errors.New("cross-origin MCP redirect refused")
			}
			return nil
		}}
		if cfg.transport() == "sse" {
			return &mcp.SSEClientTransport{Endpoint: endpoint, HTTPClient: client}, nil
		}
		return &mcp.StreamableClientTransport{Endpoint: endpoint, HTTPClient: client}, nil
	default:
		return nil, fmt.Errorf("unknown transport %q", cfg.Type)
	}
}

// External servers get OS/runtime essentials, not the harness's API keys or
// NATS credentials. Required application variables must be explicitly supplied.
func mergedEnv(overrides map[string]string) []string {
	values := map[string]string{}
	for _, key := range []string{"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "SYSTEMROOT", "SSL_CERT_FILE", "SSL_CERT_DIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "UV_CACHE_DIR", "NPM_CONFIG_CACHE"} {
		if v, ok := os.LookupEnv(key); ok {
			values[key] = v
		}
	}
	for k, v := range overrides {
		values[k] = v
	}
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, k := range keys {
		env = append(env, k+"="+values[k])
	}
	return env
}

// The guard is a small separate process with an inherited lifeline pipe. EOF
// means its bridge died (including SIGKILL). It terminates the server's entire
// process group, not just an npx/uvx launcher. No heartbeat/timing dependency.
type guardTransport struct{ cfg *serverConfig }

func (t *guardTransport) Connect(ctx context.Context) (mcp.Connection, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	r, w, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	bin, err := os.Executable()
	if err != nil {
		r.Close()
		w.Close()
		return nil, err
	}
	env, err := expandEnvMap(t.cfg.Env)
	if err != nil {
		return nil, fmt.Errorf("env: %w", err)
	}
	args := make([]string, 0, len(t.cfg.Args)+2)
	args = append(args, "--stdio-guard", t.cfg.Command)
	for _, a := range t.cfg.Args {
		expanded, err := expandEnvRefs(a)
		if err != nil {
			return nil, fmt.Errorf("args: %w", err)
		}
		args = append(args, expanded)
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = mergedEnv(env)
	cmd.Dir = t.cfg.Cwd
	cmd.ExtraFiles = []*os.File{r}
	cmd.Stderr = os.Stderr
	conn, err := (&mcp.CommandTransport{Command: cmd, TerminateDuration: 2 * time.Second}).Connect(ctx)
	_ = r.Close()
	if err != nil {
		w.Close()
		return nil, err
	}
	return &guardConnection{Connection: conn, lifeline: w}, nil
}

type guardConnection struct {
	mcp.Connection
	lifeline *os.File
	once     sync.Once
	err      error
}

func (c *guardConnection) Close() error {
	c.once.Do(func() { _ = c.lifeline.Close(); c.err = c.Connection.Close() })
	return c.err
}
func runGuard(args []string) int {
	if len(args) == 0 {
		return 2
	}
	life := os.NewFile(3, "bridge-lifeline")
	if life == nil {
		return 2
	}
	defer life.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	gone := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, life); close(gone) }()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	// Own process group (group cleanup covers launcher descendants) plus a
	// kernel lifeline: if the guard itself is SIGKILLed, the server still
	// receives SIGTERM — no orphaned MCP servers in any teardown path.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var err error
	finished := false
	select {
	case err = <-done:
		finished = true
	case <-gone:
	case <-ctx.Done():
	}
	// Even a normally-exited launcher may leave descendants in its group.
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	// Always allow a short grace then kill any surviving descendants.
	<-timer.C
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if !finished {
		err = <-done
	}
	if err != nil {
		return 1
	}
	return 0
}
