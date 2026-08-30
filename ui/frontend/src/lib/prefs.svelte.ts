// Display preferences shared across chat views: how much of the reasoning
// (think) and of the tool-run cards (tools) to render. Display-side only —
// the transcript always receives full data from the bus; these toggles only
// change how much of it shows. Persisted to localStorage like the locale.
//
// Module-level $state (Svelte 5 runes in .svelte.ts): every component that
// reads these in its template re-renders when they change.

export type ThinkLevel = "full" | "brief" | "off";
export type ToolLevel = "brief" | "full" | "off";

const THINK_KEY = "niffler-think";
const TOOL_KEY = "niffler-tools";

function load(key: string, fallback: string, allowed: string[]): string {
  try {
    const v = localStorage.getItem(key);
    if (v && allowed.includes(v)) return v;
  } catch {
    // non-fatal: the choice just won't survive a reload
  }
  return fallback;
}

function save(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // non-fatal
  }
}

const state = $state({
  think: load(THINK_KEY, "full", ["full", "brief", "off"]) as ThinkLevel,
  tools: load(TOOL_KEY, "brief", ["brief", "full", "off"]) as ToolLevel,
});

export function thinkLevel(): ThinkLevel {
  return state.think;
}

export function toolLevel(): ToolLevel {
  return state.tools;
}

export function setThinkLevel(v: ThinkLevel): void {
  state.think = v;
  save(THINK_KEY, v);
}

export function setToolLevel(v: ToolLevel): void {
  state.tools = v;
  save(TOOL_KEY, v);
}

/** Cycle reasoning display: full → brief → off → full. Returns the new level. */
export function cycleThinkLevel(): ThinkLevel {
  const next: ThinkLevel = state.think === "full" ? "brief" : state.think === "brief" ? "off" : "full";
  setThinkLevel(next);
  return next;
}

/** Cycle tool-card display: brief → full → off → brief. Returns the new level. */
export function cycleToolLevel(): ToolLevel {
  const next: ToolLevel = state.tools === "brief" ? "full" : state.tools === "full" ? "off" : "brief";
  setToolLevel(next);
  return next;
}
