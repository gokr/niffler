// Session subject builders + bus discovery + tool-result conventions —
// the wire-spec helpers shared with the Nim SDK (sdk/subjects.nim) and
// the Go SDK (wire.go). The envelope (docs/WIRE.md) is the artifact;
// these helpers keep the conventions around it identical in every SDK.

/** Make a session id safe as a NATS subject token (svc.session.<id>.call)
 *  and a catalog component name: alnum/-/_ kept, everything else '-'. */
export function sanitizeSessionId(s: string): string {
  return s.replace(/[^a-zA-Z0-9_-]/g, "-");
}

/** Catalog component name of a conversation's session runner process. */
export function runnerName(sessionId: string): string {
  return "session-" + sanitizeSessionId(sessionId);
}

/** Request/reply subject of a session runner (queue "session"). */
export function sessionCallSubject(sessionId: string): string {
  return "svc.session." + sanitizeSessionId(sessionId) + ".call";
}

/** Fire-and-forget channel a client publishes to in order to inject a
 *  message into a RUNNING turn (folded in between LLM rounds). */
export function sessionSteerSubject(sessionId: string): string {
  return "svc.session." + sanitizeSessionId(sessionId) + ".steer";
}

/** Nested-call proxy for session-context tools (fabric, agent). */
export function sessionToolSubject(sessionId: string): string {
  return "svc.session." + sanitizeSessionId(sessionId) + ".tool";
}

/** Turn-bound advisory request/reply subject (expert → runner). */
export function sessionAdviseSubject(sessionId: string): string {
  return "svc.session." + sanitizeSessionId(sessionId) + ".advise";
}

/** Bus address: NIF_NATS_URL env → <root>/var/nats-url discovery file →
 *  the well-known local default. */
export function resolveNatsUrl(root = ""): string {
  if (process.env.NIF_NATS_URL) return process.env.NIF_NATS_URL;
  const r = root || process.env.NIF_ROOT || ".";
  try {
    // Lazy require: keeps this module importable in browser bundles.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const fs = require("fs");
    const url = fs.readFileSync(r + "/var/nats-url", "utf8").trim();
    if (url) return url;
  } catch {
    /* fall through to the default */
  }
  return "nats://127.0.0.1:4222";
}

/**
 * Canonical success tool result: {"ok": true} merged with the extra
 * fields. Tools that report success/failure inside the result JSON
 * (rather than throwing, which becomes a bus-level error envelope) use
 * one canonical shape so the LLM and component callers never hand-roll it.
 */
export function okResult(extra?: Record<string, unknown>): Record<string, unknown> {
  return { ok: true, ...extra };
}

/** Canonical failure tool result: {"ok": false, "error": msg}. */
export function errResult(msg: string): Record<string, unknown> {
  return { ok: false, error: msg };
}

/** errResult plus a machine-readable code (e.g. "not-found"). */
export function errResultCode(
  msg: string,
  code: string
): Record<string, unknown> {
  return { ok: false, error: msg, code };
}
