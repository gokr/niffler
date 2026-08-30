// Slash-command registry and parsing — the web twin of niffler-tui's
// tui/slash.go. Built-in commands are local to the UI; plugin commands come
// from the declarative registry components publish at registration
// (docs/WIRE.md): core validates the spec, checkpoints the merged table to
// the store (kind "slash", id "slash") and announces ev.catalog.updated on
// every change. Built-ins shadow same-named registrations.

import { send } from "../nats";

export interface SlashSource {
  tool: string;
  args?: Record<string, unknown>;
  /** Field selects the completion value inside each result item (e.g.
   * "nickname" for provider_list). Defaults to "id". */
  field?: string;
}

export interface SlashParam {
  name: string;
  kind?: string; // "string" | "bool" | "int" | "enum"
  description?: string;
  source?: SlashSource;
  default?: unknown;
  values?: string[];
}

export interface SlashCommand {
  name: string;
  description?: string;
  /** Component the target tool lives on; absent for built-ins. */
  component?: string;
  tool?: string;
  params?: SlashParam[];
  builtin?: boolean;
}

export function builtinSlashCommands(): SlashCommand[] {
  const providerSrc: SlashSource = {
    tool: "provider.provider_list",
    args: {},
    field: "nickname",
  };
  const sessionSrc: SlashSource = {
    tool: "store.list",
    args: { kind: "conversation" },
    field: "id",
  };
  return [
    {
      name: "provider",
      description: "choose the global provider",
      builtin: true,
      params: [
        {
          name: "nickname",
          kind: "string",
          description: "provider nickname, 'environment' or 'strip [on|off]'",
          source: providerSrc,
        },
      ],
    },
    { name: "providers", description: "choose the global provider", builtin: true, params: [{ name: "nickname", kind: "string", source: providerSrc }] },
    {
      name: "model",
      description: "choose this conversation's model",
      builtin: true,
      params: [{ name: "id", kind: "string", description: "model id or 'default'" }],
    },
    { name: "models", description: "choose this conversation's model", builtin: true, params: [{ name: "id", kind: "string" }] },
    {
      name: "effort",
      description: "thinking effort for this conversation",
      builtin: true,
      params: [{ name: "level", kind: "enum", values: ["auto", "low", "medium", "high"], description: "empty = provider default (auto)" }],
    },
    { name: "connect", description: "open provider setup", builtin: true },
    { name: "status", description: "show provider/model/context details", builtin: true },
    { name: "new", description: "start a new conversation", builtin: true, params: [{ name: "id", kind: "string", description: "optional conversation id" }] },
    { name: "newsession", description: "start a new conversation", builtin: true, params: [{ name: "id", kind: "string" }] },
    {
      name: "session",
      description: "switch conversation",
      builtin: true,
      params: [{ name: "id", kind: "string", description: "conversation id", source: sessionSrc }],
    },
    { name: "sessions", description: "switch conversation", builtin: true, params: [{ name: "id", kind: "string", source: sessionSrc }] },
    { name: "think", description: "reasoning display: full, brief or off", builtin: true, params: [{ name: "level", kind: "enum", values: ["full", "brief", "off"] }] },
    { name: "tools", description: "tool card display: brief, full or off", builtin: true, params: [{ name: "level", kind: "enum", values: ["brief", "full", "off"] }] },
    { name: "locale", description: "switch the UI language", builtin: true, params: [{ name: "lang", kind: "enum", values: ["en", "zh", "zh-TW"] }] },
    { name: "help", description: "show this help", builtin: true },
    { name: "?", description: "show this help", builtin: true },
  ];
}

/** Merge plugin commands under the built-ins (built-ins win on name
 * collision). Invalid registrations are dropped: never trust the wire. */
export function mergeSlashCommands(pluginCmds: SlashCommand[]): SlashCommand[] {
  const map = new Map<string, SlashCommand>();
  for (const c of builtinSlashCommands()) map.set(c.name, c);
  for (const c of pluginCmds) {
    if (!c?.name || !c.component || !c.tool) continue;
    if (map.has(c.name)) continue;
    map.set(c.name, c);
  }
  return [...map.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/** Load the merged slash registry store-first (kind "slash", id "slash"),
 * falling back to the live catalog snapshot when the checkpoint is missing
 * (older core). Plugin commands only; mergeSlashCommands adds built-ins. */
export async function loadPluginSlashCommands(): Promise<SlashCommand[]> {
  try {
    const r = await send("store", "get", { kind: "slash", id: "slash" });
    if (r?.ok && Array.isArray(r.value?.commands)) {
      return r.value.commands as SlashCommand[];
    }
  } catch {
    // checkpoint missing — fall through to the catalog snapshot
  }
  try {
    const snap = await send("core", "catalog", { op: "snapshot" });
    const out: SlashCommand[] = [];
    for (const comp of snap.components ?? []) {
      for (const cmd of comp.slash ?? []) {
        out.push({ ...cmd, component: comp.name });
      }
    }
    return out;
  } catch {
    return [];
  }
}

// ---- parsing ----------------------------------------------------------------

/** Build tool-call arguments from a command line: positional values fill
 * non-bool params in declaration order, name=value sets params by name, a
 * bare bool-param name is a true flag. Declared defaults apply to params
 * the user omitted. */
export function parseSlashArgs(cmd: SlashCommand, rawArgs: string): { args: Record<string, unknown>; error?: string } {
  const params = cmd.params ?? [];
  const byName = new Map(params.map((p) => [p.name, p]));
  const args: Record<string, unknown> = {};
  let positional = 0;
  const nextPositional = (): SlashParam | undefined => {
    while (positional < params.length) {
      const p = params[positional++];
      if (p.kind !== "bool") return p;
    }
    return undefined;
  };
  for (const tok of rawArgs.trim().split(/\s+/).filter(Boolean)) {
    let name: string;
    let val: string;
    const eq = tok.indexOf("=");
    if (eq >= 0) {
      name = tok.slice(0, eq);
      val = tok.slice(eq + 1);
      if (!byName.has(name)) return { args: {}, error: `unknown argument "${name}"` };
    } else if (byName.get(tok)?.kind === "bool") {
      name = tok;
      val = "true";
    } else {
      const p = nextPositional();
      if (!p) return { args: {}, error: `too many arguments (declared: ${params.length})` };
      name = p.name;
      val = tok;
    }
    const p = byName.get(name)!;
    const coerced = coerce(p, val);
    if (coerced.error) return { args: {}, error: `${p.name}: ${coerced.error}` };
    args[p.name] = coerced.value;
  }
  for (const p of params) {
    if (p.name in args || p.default === undefined) continue;
    args[p.name] = p.default;
  }
  return { args };
}

function coerce(p: SlashParam, val: string): { value?: unknown; error?: string } {
  switch (p.kind) {
    case "bool":
      switch (val.toLowerCase()) {
        case "true":
        case "on":
        case "yes":
        case "1":
          return { value: true };
        case "false":
        case "off":
        case "no":
        case "0":
          return { value: false };
      }
      return { error: "expected on/off" };
    case "int": {
      const n = Number(val);
      if (!Number.isInteger(n)) return { error: "expected a number" };
      return { value: n };
    }
    default:
      if (p.values && p.values.length > 0 && !p.values.includes(val)) {
        return { error: `expected one of ${p.values.join(", ")}` };
      }
      return { value: val };
  }
}

// ---- completion -------------------------------------------------------------

/** What a completion popup should offer for the current input. */
export interface CompletionState {
  /** Input text before the token being completed (e.g. "/" or "/provider "). */
  prefix: string;
  /** The partial token being completed ("" when the user just typed a space). */
  token: string;
  /** Inline candidates from the param's declared values, if any. */
  values?: string[];
  /** Fetch candidates from this tool via core.invoke when set. */
  source?: SlashSource;
}

/** Compute what the completion popup should show for a slash-command input.
 * Null when the input is not completable (not a command, unknown command,
 * or a positional with no declared source/values). */
export function slashCompletion(value: string, commands: SlashCommand[]): CompletionState | null {
  if (!value.startsWith("/")) return null;
  const trailingSpace = /\s$/.test(value);
  const parts = value.slice(1).split(" ");
  const first = parts[0] ?? "";

  // Completing the command name itself.
  if (parts.length <= 1 && !trailingSpace) {
    return { prefix: "/", token: first };
  }

  const cmd = commands.find((c) => c.name === first);
  if (!cmd) return null;

  // Walk the preceding fields to find which declared param the current
  // token addresses (same walk as the TUI).
  const consumed = new Set<string>();
  let positional = 0;
  for (const f of parts.slice(1, -1)) {
    if (!f) continue;
    if (f.includes("=")) {
      consumed.add(f.slice(0, f.indexOf("=")));
      continue;
    }
    const p = cmd.params?.find((x) => x.name === f);
    if (p && p.kind === "bool") consumed.add(f);
    else positional++;
  }
  const token = parts[parts.length - 1] ?? "";
  const prefix = value.slice(0, value.length - token.length);
  if (token === "" && trailingSpace) positional++;

  // The n-th (1-based) non-bool param decides the candidates.
  for (const p of cmd.params ?? []) {
    if (p.kind === "bool") continue;
    if (positional === 1) {
      if (p.source) return { prefix, token, source: p.source };
      if (p.values && p.values.length > 0) return { prefix, token, values: p.values };
      return null;
    }
    positional--;
  }
  return null;
}

/** Turn a source tool's result into candidate strings: an array of strings
 * or {id}-objects, an {items: [...]} wrapper, or a plain value. */
export function extractCompletionValues(raw: unknown, field?: string): string[] {
  const out: string[] = [];
  const add = (v: unknown) => {
    if (typeof v === "string" && v !== "") out.push(v);
  };
  const walk = (node: unknown) => {
    if (Array.isArray(node)) {
      for (const item of node) {
        if (typeof item === "string") add(item);
        else if (item && typeof item === "object") {
          const obj = item as Record<string, unknown>;
          if (field) add(obj[field]);
          else add(obj["id"]);
        }
      }
      return;
    }
    if (node && typeof node === "object") {
      const obj = node as Record<string, unknown>;
      if (Array.isArray(obj["items"])) return walk(obj["items"]);
      if (field) add(obj[field]);
      else add(obj["id"]);
      return;
    }
    add(node);
  };
  walk(raw);
  out.sort();
  return out;
}

/** Fetch a completion source's values through core.invoke (so no client-side
 * tool index is needed) and extract the candidate strings. */
export async function fetchCompletionValues(source: SlashSource): Promise<string[]> {
  const raw = await send("core", "invoke", {
    tool: source.tool,
    arguments: source.args ?? {},
  });
  return extractCompletionValues(raw, source.field);
}

// ---- suggestions ------------------------------------------------------------

/** A "did you mean" hint for an unknown command: prefix matches first, then
 * near-misses by edit distance (typos like /deply). Empty when nothing is
 * close. */
export function suggestSlash(commands: SlashCommand[], name: string): string {
  const names = commands.map((c) => c.name);
  const matches: string[] = [];
  const seen = new Set<string>();
  const add = (c: string) => {
    if (!seen.has(c) && matches.length < 3) {
      seen.add(c);
      matches.push("/" + c);
    }
  };
  for (const candidate of names) if (candidate.startsWith(name)) add(candidate);
  if (matches.length < 3) {
    for (const candidate of names) {
      if (candidate !== name && editDistance(candidate, name) <= 2) add(candidate);
    }
  }
  if (matches.length === 0) return "";
  return ` — did you mean ${matches.join(", ")}?`;
}

/** Classic Levenshtein distance (insert/delete/substitute at cost 1). */
export function editDistance(a: string, b: string): number {
  const prev = new Array(b.length + 1);
  for (let j = 0; j <= b.length; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    const cur = new Array(b.length + 1);
    cur[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      cur[j] = Math.min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
    }
    for (let j = 0; j <= b.length; j++) prev[j] = cur[j];
  }
  return prev[b.length];
}
