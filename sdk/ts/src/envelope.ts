// Niffler envelope codec — the wire protocol (docs/WIRE.md).
//
// Mirrors sdk/envelope.nim and sdk/go/envelope.go 1:1 — pure JSON runtime
// data, so it stays trivially portable. The envelope is the artifact.

export type EnvelopeKind = "call" | "result" | "event" | "error";

export interface ErrorInfo {
  code: string;
  message: string;
}

export interface Envelope {
  v: number;
  id: string;
  kind: EnvelopeKind;
  tool?: string;
  args?: unknown;
  payload?: unknown;
  error?: ErrorInfo;
  /** Component name of the call originator (call only; self-declared
   *  routing hint, not an auth claim). */
  caller?: string;
}

let idCounter = 0;

/** Cheap unique bus id (ns timestamp + pid + counter). */
export function newId(): string {
  idCounter++;
  return `${Date.now() * 1_000_000}-${process.pid}-${idCounter}`;
}

function parseKind(s: string): EnvelopeKind {
  switch (s) {
    case "call":
      return "call";
    case "result":
      return "result";
    case "event":
      return "event";
    default:
      return "error";
  }
}

export function toJson(e: Envelope): Record<string, unknown> {
  const out: Record<string, unknown> = { v: e.v, id: e.id, kind: e.kind };
  if (e.tool) out.tool = e.tool;
  if (e.args !== undefined) out.args = e.args;
  if (e.payload !== undefined) out.payload = e.payload;
  if (e.error !== undefined) out.error = e.error;
  if (e.caller) out.caller = e.caller;
  return out;
}

export function fromJson(node: Record<string, unknown>): Envelope {
  return {
    v: (node.v as number) ?? 1,
    id: (node.id as string) ?? "",
    kind: parseKind((node.kind as string) ?? "event"),
    tool: (node.tool as string) ?? "",
    args: node.args,
    payload: node.payload,
    error: node.error as ErrorInfo | undefined,
    caller: (node.caller as string) ?? "",
  };
}

export function encode(e: Envelope): string {
  return JSON.stringify(toJson(e));
}

/** Decode an envelope; malformed input becomes an error envelope, never a crash. */
export function decode(data: string): Envelope {
  try {
    return fromJson(JSON.parse(data) as Record<string, unknown>);
  } catch (err) {
    return {
      v: 1,
      id: newId(),
      kind: "error",
      error: { code: "bad-envelope", message: String(err) },
    };
  }
}

export function errorEnvelope(id: string, code: string, message: string): Envelope {
  return { v: 1, id, kind: "error", error: { code, message } };
}

export function resultEnvelope(id: string, value: unknown): Envelope {
  return { v: 1, id, kind: "result", args: value };
}

export function callEnvelope(tool: string, args: unknown): Envelope {
  return { v: 1, id: newId(), kind: "call", tool, args };
}
