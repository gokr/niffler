// Per-conversation LLM thinking-effort selection, the web twin of the TUI's
// ctrl+g: "" (provider default, shown as "auto") | low | medium | high | max.
// Persisted per conversation through core's session tool
// (`core.session {sessionId, thinking}`, a model-only call: no inference),
// applied by the session runner on the next turn and forwarded to the LLM
// as reasoning_effort only when set — providers without support never see it.

import { send } from "../nats";

export type EffortLevel = "" | "low" | "medium" | "high" | "max";

export const EFFORT_CYCLE: EffortLevel[] = ["", "low", "medium", "high", "max"];

export function effortLabel(effort: EffortLevel): string {
  return effort === "" ? "auto" : effort;
}

export function nextEffort(current: EffortLevel): EffortLevel {
  const idx = EFFORT_CYCLE.indexOf(current);
  return EFFORT_CYCLE[(idx + 1) % EFFORT_CYCLE.length];
}

export function isValidEffort(v: unknown): v is EffortLevel {
  return typeof v === "string" && EFFORT_CYCLE.includes(v as EffortLevel);
}

/** Persist the conversation's thinking effort. Returns the effective value
 * stored server-side. */
export async function saveThinkingEffort(sessionId: string, effort: EffortLevel): Promise<void> {
  const resp = await send("core", "session", { sessionId, thinking: effort }, 30000);
  if (resp && resp.error) throw new Error(resp.error);
}

/** Read the persisted effort from the conversation header (store). */
export async function loadThinkingEffort(sessionId: string): Promise<EffortLevel> {
  try {
    const resp = await send("store", "get", { kind: "conversation", id: sessionId });
    const v = resp?.value ?? {};
    return isValidEffort(v.thinkingEffort) ? v.thinkingEffort : "";
  } catch {
    return "";
  }
}
