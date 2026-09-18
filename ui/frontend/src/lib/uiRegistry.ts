// Web UI participation in core's UI lease registry (core/uireg.nim).
//
// Identity granularity: one identity per browser tab, minted by the bridge
// (`Bridge.NewUiId`, "ui-<12 hex>") and reused across reloads via
// sessionStorage. The bridge also stamps that identity as the `caller` of the
// tab's session turns (`Bridge.SendAs`), so core routes directed approvals to
// `svc.approval.<caller>.request` and only the tab that drives the turn acts
// on them — the same privacy the TUI gets from its unique "tui-<hex>"
// component name.
//
// Registry calls are ordinary core tool calls (the hidden "ui" tool). This
// module is deliberately bus-agnostic: every function takes a `send` port so
// the ownership rules are unit-testable on plain node
// (tests/uiRegistry.test.mjs) with no Wails shell, NATS or bundle.
//
// Registry semantics and the reference implementation live in core/uireg.nim,
// tests/t_uireg.nim and gokr/niffler-tui (tui/main.go, tui/session_history.go).

/** A bus tool call, matching nats.ts `send` — injected so this module never
 * imports the Wails transport. */
export type SendFn = (
  component: string,
  tool: string,
  args: Record<string, unknown>,
  timeoutMs?: number
) => Promise<any>;

/** Registry calls are core-local and synchronous; a short deadline keeps a
 * wedged bus from stalling the UI's own boot. */
export const UI_REGISTRY_TIMEOUT_MS = 10000;

/** The ~20s lease is renewed every 5s, like the TUI. */
export const UI_LEASE_RENEW_MS = 5000;

export interface AttachResult {
  /** The lease was granted (`register` answered ok). */
  registered: boolean;
  /** Display number ("Niffler N"); 0 when registration failed. */
  number: number;
  /** The conversation is ours (or there was none to claim). */
  claimed: boolean;
  /** When `claimed` is false: the live owner's display number, 0 if unknown. */
  ownerNumber: number;
  /** Set when the registry could not be reached at all (degrade silently). */
  error?: string;
}

/** The pure ownership rule for a refused attach/renew, mirroring the TUI's
 * `uiStartupDecision`: keep the conversation when we own it (or coordination
 * is unavailable); otherwise start a fresh one and report who holds it
 * (`ownerNumber` 0 means an unidentified UI). */
export function uiStartupDecision(
  r: { error?: string; claimed: boolean; ownerNumber?: number },
  freshId: string
): { switchTo: string; ownerNumber: number } {
  if (r.error || r.claimed) return { switchTo: "", ownerNumber: 0 };
  return { switchTo: freshId, ownerNumber: r.ownerNumber ?? 0 };
}

/** One core `ui` registry op; an error payload throws so callers degrade. */
async function uiOp(send: SendFn, args: Record<string, unknown>): Promise<any> {
  const r = await send("core", "ui", args, UI_REGISTRY_TIMEOUT_MS);
  if (r && typeof r.error === "string" && r.error.length > 0) {
    throw new Error(r.error);
  }
  return r ?? {};
}

/** register: a warm lease keeps the number; a lapsed one gets a fresh number,
 * which is the expiry signal the renew loop watches. */
export async function uiRegister(
  send: SendFn,
  uiId: string
): Promise<{ ok: boolean; number: number }> {
  const r = await uiOp(send, { op: "register", ui: uiId });
  return { ok: !!r.ok, number: Number(r.number ?? 0) };
}

/** renew: refreshes an existing lease; `ok: false` means the lease lapsed and
 * the client must re-register (fresh number) and re-claim. */
export async function uiRenew(
  send: SendFn,
  uiId: string
): Promise<{ ok: boolean; number: number }> {
  const r = await uiOp(send, { op: "renew", ui: uiId });
  return { ok: !!r.ok, number: Number(r.number ?? 0) };
}

/** claim: idempotent for the owner, grants a free conversation, and reports
 * the live owner's number on refusal. */
export async function uiClaim(
  send: SendFn,
  uiId: string,
  session: string
): Promise<{ ok: boolean; ownerNumber: number }> {
  const r = await uiOp(send, { op: "claim", ui: uiId, session });
  return { ok: !!r.ok, ownerNumber: Number(r.number ?? 0) };
}

/** release_session: drop one claim the caller owns. */
export async function uiReleaseSession(
  send: SendFn,
  uiId: string,
  session: string
): Promise<void> {
  await uiOp(send, { op: "release_session", ui: uiId, session });
}

/** release: drop the identity, its lease and all of its claims. */
export async function uiRelease(send: SendFn, uiId: string): Promise<void> {
  await uiOp(send, { op: "release", ui: uiId });
}

/** Attach = register (renew/keep the number) then claim the conversation.
 * Any registry failure degrades to uncoordinated: chatting still works and
 * approvals fall back to the broadcast transport. */
export async function uiAttach(
  send: SendFn,
  uiId: string,
  session: string | null
): Promise<AttachResult> {
  const out: AttachResult = {
    registered: false,
    number: 0,
    claimed: false,
    ownerNumber: 0,
  };
  try {
    const reg = await uiRegister(send, uiId);
    out.registered = reg.ok;
    out.number = reg.number;
    if (!session) {
      out.claimed = true;
      return out;
    }
    const c = await uiClaim(send, uiId, session);
    out.claimed = c.ok;
    out.ownerNumber = c.ownerNumber;
    return out;
  } catch (e) {
    out.error = String(e);
    return out;
  }
}
