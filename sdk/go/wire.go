package sdk

// Wire conventions shared with the Nim SDK (sdk/subjects.nim +
// sdk/niffler/sdk.nim result helpers): session subject builders, bus
// discovery, and the {ok, error} tool-result shape. The envelope
// (envelope.go + docs/WIRE.md) is the artifact; these helpers keep the
// conventions around it identical in every SDK.

import (
	"os"
	"strings"
)

// SanitizeSessionID makes a session id safe as a NATS subject token
// (svc.session.<id>.call) and a catalog component name: alnum/-/_ kept,
// everything else replaced with '-'.
func SanitizeSessionID(s string) string {
	var b strings.Builder
	for _, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z',
			c >= '0' && c <= '9', c == '-', c == '_':
			b.WriteRune(c)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}

// RunnerName is the catalog component name of a conversation's session
// runner process.
func RunnerName(sessionID string) string {
	return "session-" + SanitizeSessionID(sessionID)
}

// SessionCallSubject is the request/reply subject of a session runner
// (queue "session").
func SessionCallSubject(sessionID string) string {
	return "svc.session." + SanitizeSessionID(sessionID) + ".call"
}

// SessionSteerSubject is the fire-and-forget channel a client publishes
// to in order to inject a message into a RUNNING turn.
func SessionSteerSubject(sessionID string) string {
	return "svc.session." + SanitizeSessionID(sessionID) + ".steer"
}

// SessionToolSubject is the nested-call proxy for session-context tools
// (fabric, agent): generated programs route every tool call here.
func SessionToolSubject(sessionID string) string {
	return "svc.session." + SanitizeSessionID(sessionID) + ".tool"
}

// ResolveNATSURL is the bus address: NIF_NATS_URL env →
// <root>/var/nats-url discovery file → the well-known local default.
func ResolveNATSURL(root string) string {
	if url := os.Getenv("NIF_NATS_URL"); url != "" {
		return url
	}
	r := root
	if r == "" {
		r = os.Getenv("NIF_ROOT")
	}
	if r == "" {
		r = "."
	}
	if data, err := os.ReadFile(r + "/var/nats-url"); err == nil {
		if url := strings.TrimSpace(string(data)); url != "" {
			return url
		}
	}
	return "nats://127.0.0.1:4222"
}

// OK is the canonical success tool result: {"ok": true} merged with the
// extra fields. Tools that report success/failure inside the result JSON
// (rather than returning an error, which becomes a bus-level error
// envelope) use one canonical shape so the LLM and component callers
// never hand-roll it.
func OK(extra map[string]any) map[string]any {
	result := map[string]any{"ok": true}
	for k, v := range extra {
		result[k] = v
	}
	return result
}

// Err is the canonical failure tool result: {"ok": false, "error": msg}.
func Err(msg string) map[string]any {
	return map[string]any{"ok": false, "error": msg}
}

// ErrCode is Err plus a machine-readable code (e.g. "not-found",
// "rev-conflict").
func ErrCode(msg, code string) map[string]any {
	return map[string]any{"ok": false, "error": msg, "code": code}
}
