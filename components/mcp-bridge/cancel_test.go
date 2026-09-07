package main

import (
	"encoding/json"
	"testing"

	sdk "niffler.dev/sdk"
)

func TestBeginTracksAndStrips(t *testing.T) {
	b := newBridge(&serverConfig{Name: "x"}, nil, true)
	ctx, clean, end, err := b.begin("mcp_x_slow", json.RawMessage(`{"ms":8000,"__session":{"session":"s1"}}`))
	if err != nil {
		t.Fatal(err)
	}
	defer end()
	var forwarded map[string]any
	if err := json.Unmarshal(clean, &forwarded); err != nil {
		t.Fatal(err)
	}
	if _, ok := forwarded["__session"]; ok {
		t.Errorf("__session must not reach the MCP server: %v", forwarded)
	}
	if forwarded["ms"].(float64) != 8000 {
		t.Errorf("application args must survive: %v", forwarded)
	}
	b.mu.Lock()
	if len(b.active) != 1 {
		t.Fatalf("active call not tracked: %v", b.active)
	}
	for _, call := range b.active {
		if call.session != "s1" || call.tool != "mcp_x_slow" {
			t.Errorf("tracked call = %+v", call)
		}
	}
	b.mu.Unlock()
	b.cancelCalls("cancel.x", json.RawMessage(`{"sessionId":"s1","tool":"mcp_x_slow","ts":1}`))
	select {
	case <-ctx.Done():
	default:
		t.Fatal("cancel event must cancel the tracked call")
	}
}

func TestCancelEventEnvelopePayload(t *testing.T) {
	// The Nim test publishes this exact wire shape; ParseEnvelope must yield
	// the payload cancelCalls expects.
	env := sdk.ParseEnvelope([]byte(`{"v":1,"id":"cancel-probe","kind":"event","payload":{"sessionId":"s1","tool":"t"}}`))
	if string(env.Kind) != "event" {
		t.Fatalf("kind = %v", env.Kind)
	}
	b := newBridge(&serverConfig{Name: "x"}, nil, true)
	ctx, _, end, err := b.begin("t", json.RawMessage(`{"__session":{"session":"s1"}}`))
	if err != nil {
		t.Fatal(err)
	}
	defer end()
	b.cancelCalls("cancel.x", env.Payload)
	select {
	case <-ctx.Done():
	default:
		t.Fatal("envelope payload must drive cancellation")
	}
}
