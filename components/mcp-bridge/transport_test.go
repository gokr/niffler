package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestHeaderTransportOriginOnly(t *testing.T) {
	var got string
	inner := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if next := r.URL.Query().Get("go"); next != "" {
			http.Redirect(w, r, next, http.StatusFound)
			return
		}
		got = r.Header.Get("Authorization")
	}))
	defer inner.Close()
	foreign := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("Authorization")
		http.Error(w, "cross origin", http.StatusUnauthorized)
	}))
	defer foreign.Close()
	target, _ := neturl.Parse(inner.URL)
	client := &http.Client{
		Transport: headerTransport{base: http.DefaultTransport,
			headers: map[string]string{"Authorization": "Bearer PRIVATE"}, origin: target},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if !sameOrigin(target, req.URL) {
				return errors.New("cross-origin MCP redirect refused")
			}
			return nil
		},
	}
	req, _ := http.NewRequest("GET", inner.URL, nil)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got != "Bearer PRIVATE" {
		t.Errorf("same-origin request must carry configured headers, got %q", got)
	}
	got = ""
	redirect, _ := http.NewRequest("GET", inner.URL+"?go="+neturl.QueryEscape(foreign.URL), nil)
	if _, err := client.Do(redirect); err == nil || !strings.Contains(err.Error(), "redirect") {
		t.Errorf("cross-origin redirect must be refused, got %v", err)
	}
	if got != "" {
		t.Errorf("credentials must never reach the redirect target, got %q", got)
	}
	blocked := &http.Client{Transport: headerTransport{base: http.DefaultTransport,
		headers: map[string]string{"Authorization": "Bearer PRIVATE"}, origin: target}}
	req2, _ := http.NewRequest("GET", foreign.URL, nil)
	if _, err := blocked.Do(req2); err == nil || !strings.Contains(err.Error(), "origin") {
		t.Errorf("requests to a different origin must be refused, got %v", err)
	}
}

func TestMergedEnvAllowlist(t *testing.T) {
	t.Setenv("NIF_OPENAI_API_KEY", "leak")
	t.Setenv("NIF_NATS_URL", "nats://127.0.0.1:4222")
	env := mergedEnv(map[string]string{"APP_TOKEN": "app"})
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "leak") || strings.Contains(joined, "NIF_OPENAI_API_KEY") || strings.Contains(joined, "NIF_NATS_URL") {
		t.Errorf("harness secrets must not reach external MCP servers: %s", joined)
	}
	if !strings.Contains(joined, "APP_TOKEN=app") {
		t.Errorf("configured env must be passed through: %s", joined)
	}
	if !strings.Contains(joined, "PATH=") {
		t.Errorf("runtime essentials must be inherited: %s", joined)
	}
}

func TestIdleDurationUnits(t *testing.T) {
	if got := (&serverConfig{}).idle(); got != 5*time.Minute {
		t.Errorf("default idle = %s, want 5m", got)
	}
	if got := (&serverConfig{IdleMs: 1500}).idle(); got != 1500*time.Millisecond {
		t.Errorf("idle = %s, want 1.5s", got)
	}
	if got := (&serverConfig{}).timeout(); got != 120*time.Second {
		t.Errorf("default call timeout = %s, want 120s", got)
	}
}

func TestProjectResultKeepsStructuredDataVisible(t *testing.T) {
	out := projectResult(&mcp.CallToolResult{
		StructuredContent: map[string]any{"answer": 42},
	}).(map[string]any)
	text, _ := out["text"].(string)
	if !strings.Contains(text, "42") {
		t.Errorf("structured-only results must surface in text: %#v", out)
	}
	if out["structured"] == nil {
		t.Errorf("structured content must stay machine-readable: %#v", out)
	}
}

func TestBoundSpillsOversizedResults(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NIF_ROOT", root)
	small, err := bound(map[string]any{"text": "tiny"})
	if err != nil {
		t.Fatal(err)
	}
	if _, spilled := small.(map[string]any)["spill"]; spilled {
		t.Errorf("small results must stay inline: %#v", small)
	}
	big := map[string]any{"text": strings.Repeat("x", 80*1024)}
	out, err := bound(big)
	if err != nil {
		t.Fatal(err)
	}
	spill, ok := out.(map[string]any)["spill"].(map[string]any)
	if !ok {
		t.Fatalf("oversized results must spill: %#v", out)
	}
	path, _ := spill["path"].(string)
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("spilled result must be readable: %v", readErr)
	}
	if p, e := filepath.Abs(path); e != nil || !strings.HasPrefix(p, filepath.Join(root, "var")) {
		t.Errorf("spill must live under NIF_ROOT/var: %q", path)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Errorf("spilled file must hold the complete JSON result: %v", err)
	}
}

func TestCaptureTransportAbortBeforeConnect(t *testing.T) {
	started := make(chan struct{})
	wire := &captureTransport{Transport: failingTransport{started}}
	wire.abort()
	if _, err := wire.Connect(context.Background()); !errors.Is(err, context.Canceled) {
		t.Errorf("aborted transport must refuse late connections, got %v", err)
	}
	select {
	case <-started:
		t.Error("aborted transport must not start the underlying transport")
	default:
	}
}

type failingTransport struct{ started chan struct{} }

func (f failingTransport) Connect(context.Context) (mcp.Connection, error) {
	close(f.started)
	return nil, errors.New("must not be reached")
}
