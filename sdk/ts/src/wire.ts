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

// ---------------------------------------------------------------------------
// Tool-produced images
//
// A tool result may carry an `images` array beside its `text` (docs/WIRE.md
// "Tool results"): the one channel by which a component returns something the
// model SEES rather than reads — a screenshot, a rendered chart, an image the
// agent was asked to inspect. `text` stays the model's only text channel, so
// use it as the caption: what the image is, plus the facts a later request
// cannot recover from the pixels alone.
//
// Core, not the component, owns the bound, so a component cannot widen it:
//   - the image is validated against a byte-sniffed MIME allowlist
//     (png/jpeg/gif/webp/bmp) — mimeType is a hint and the BYTES decide, so a
//     wrong (but allowlisted) claim is corrected rather than honored;
//   - at most 4 images per result, 4 MB each, 4.5 MB per result;
//   - a refusal never fails the turn: the reason is appended to the tool's
//     text ("[images from this result were not attached: ...]"), which still
//     answers the call;
//   - core never re-encodes. An oversized capture is reported, not silently
//     resized — shrink it in the component (or return the path and let the
//     model `read` it) rather than shipping something unsendable.
//
// `data` is the RAW base64 of the file, with no "data:...;base64," prefix: the
// prefix belongs to the provider projection core builds, not to this field.

/** One image for a result's `images` array. `mimeType` must name an
 *  allowlisted image type; `name`, `width` and `height` are advisory (they
 *  caption the image and feed the token estimate). */
export function resultImage(
  data: string,
  mimeType: string,
  options: { name?: string; width?: number; height?: number } = {}
): Record<string, unknown> {
  const image: Record<string, unknown> = { type: "image", data, mimeType };
  if (options.name) image.name = options.name;
  if (options.width && options.width > 0) image.width = options.width;
  if (options.height && options.height > 0) image.height = options.height;
  return image;
}

/** Attach images to a result object. The result's `text` is what the model
 *  reads, so a result carrying images should still describe them there. */
export function withImages(
  result: Record<string, unknown>,
  images: readonly Record<string, unknown>[]
): Record<string, unknown> {
  return { ...(result ?? {}), images: [...images] };
}
