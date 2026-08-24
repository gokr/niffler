// Package sdk is the Niffler component SDK (Go).
//
// Mirrors sdk/niffler.nim 1:1 — the envelope (docs/WIRE.md) is the artifact.
// The Go port uses nats.go callbacks (goroutines) serialized with a mutex,
// where the Nim port polls subscriptions on the main thread.
package sdk

import (
	"encoding/json"
	"fmt"
	"os"
	"sync/atomic"
	"time"
)

// Kind is the envelope kind ("call" | "result" | "event" | "error").
type Kind string

const (
	KindCall   Kind = "call"
	KindResult Kind = "result"
	KindEvent  Kind = "event"
	KindError  Kind = "error"
)

// ErrorInfo is the stable machine error carried by error envelopes.
type ErrorInfo struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Envelope is the wire message (docs/WIRE.md).
type Envelope struct {
	V       int             `json:"v"`
	ID      string          `json:"id"`
	Kind    Kind            `json:"kind"`
	Tool    string          `json:"tool,omitempty"`
	Args    json.RawMessage `json:"args,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	Error   *ErrorInfo      `json:"error,omitempty"`
}

// Marshal renders the envelope as JSON.
func (e Envelope) Marshal() ([]byte, error) { return json.Marshal(e) }

// ParseEnvelope decodes an envelope from wire bytes; malformed input
// becomes an error envelope rather than a crash.
func ParseEnvelope(data []byte) *Envelope {
	var e Envelope
	if err := json.Unmarshal(data, &e); err != nil {
		return &Envelope{V: 1, ID: NewID(), Kind: KindError,
			Error: &ErrorInfo{Code: "bad-envelope", Message: fmt.Sprintf("%v", err)}}
	}
	if e.Kind == "" {
		e.Kind = KindEvent
	}
	if e.V == 0 {
		e.V = 1
	}
	return &e
}

var idCounter int64

// NewID returns a cheap unique bus id (time + pid + counter).
func NewID() string {
	sequence := atomic.AddInt64(&idCounter, 1)
	return fmt.Sprintf("%d-%d-%d", time.Now().UnixNano(), os.Getpid(), sequence)
}
