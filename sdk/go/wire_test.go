package sdk

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSanitizeSessionID(t *testing.T) {
	cases := map[string]string{
		"conv-123":      "conv-123",
		"a b/c!":        "a-b-c-",
		"agent-x_1.y":   "agent-x_1-y",
		"":              "",
		"emoji😀suffix": "emoji-suffix",
	}
	for in, want := range cases {
		if got := SanitizeSessionID(in); got != want {
			t.Errorf("SanitizeSessionID(%q) = %q, want %q", in, got, want)
		}
	}
	if got := RunnerName("conv:1"); got != "session-conv-1" {
		t.Errorf("RunnerName = %q", got)
	}
	if got := SessionCallSubject("conv:1"); got != "svc.session.conv-1.call" {
		t.Errorf("SessionCallSubject = %q", got)
	}
	if got := SessionSteerSubject("conv:1"); got != "svc.session.conv-1.steer" {
		t.Errorf("SessionSteerSubject = %q", got)
	}
	if got := SessionToolSubject("conv:1"); got != "svc.session.conv-1.tool" {
		t.Errorf("SessionToolSubject = %q", got)
	}
}

func TestResolveNATSURL(t *testing.T) {
	t.Setenv("NIF_NATS_URL", "")
	t.Setenv("NIF_ROOT", "")
	if got := ResolveNATSURL(""); got != "nats://127.0.0.1:4222" {
		t.Errorf("default = %q", got)
	}
	root := t.TempDir()
	dir := filepath.Join(root, "var")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "nats-url"),
		[]byte("nats://127.0.0.1:9999\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ResolveNATSURL(root); got != "nats://127.0.0.1:9999" {
		t.Errorf("discovery = %q", got)
	}
	t.Setenv("NIF_NATS_URL", "nats://example:4222")
	if got := ResolveNATSURL(root); got != "nats://example:4222" {
		t.Errorf("env wins = %q", got)
	}
}

func TestResultConventions(t *testing.T) {
	ok, _ := json.Marshal(OK(map[string]any{"rev": 3}))
	if string(ok) != `{"ok":true,"rev":3}` {
		t.Errorf("OK = %s", ok)
	}
	errBody, _ := json.Marshal(Err("nope"))
	if string(errBody) != `{"error":"nope","ok":false}` {
		t.Errorf("Err = %s", errBody)
	}
	errCode, _ := json.Marshal(ErrCode("nope", "not-found"))
	var parsed map[string]any
	if err := json.Unmarshal(errCode, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed["code"] != "not-found" || parsed["ok"] != false {
		t.Errorf("ErrCode = %s", errCode)
	}
}
