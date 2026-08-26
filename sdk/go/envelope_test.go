package sdk

import (
	"encoding/json"
	"testing"
)

func TestEnvelopeCallerRoundTrip(t *testing.T) {
	env := Envelope{V: 1, ID: NewID(), Kind: KindCall, Tool: "session",
		Args: json.RawMessage(`{"sessionId":"game"}`), Caller: "tui"}
	data, err := env.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	parsed := ParseEnvelope(data)
	if parsed.Caller != "tui" {
		t.Fatalf("Caller after round trip = %q, want tui", parsed.Caller)
	}
	// Unknown-field tolerance: a caller-less envelope from an older peer
	// still parses with an empty caller (forward compat, docs/WIRE.md).
	legacy := []byte(`{"v":1,"id":"x","kind":"call","tool":"bash","args":{"cmd":"ls"}}`)
	p2 := ParseEnvelope(legacy)
	if p2.Caller != "" {
		t.Fatalf("legacy envelope caller = %q, want empty", p2.Caller)
	}
}
