// Built-in slash-command dispatch: the local (UI-side) commands of the web
// client. The registry in slash.ts declares *what* exists (names, params,
// aliases, subcommands) and this module declares *what happens*, keyed by the
// declared names — so `declaredHandlerKeys()` must equal the declared set, and
// the test in tests/slash.test.mjs fails on either drift direction.
//
// Handlers never touch Svelte: they act through SlashContext, a narrow port the
// component implements over its own state (that is what makes them testable —
// previously this logic was a switch inside Chat.svelte with no coverage).

import { builtinSlashCommands, formatSlashResult, parseSlashArgs, subcommandOf } from "./slash.ts";
import type { SlashCommand, SlashSubcommand } from "./slash.ts";
import { slashUserMessage } from "./slashResult.ts";

/** Everything a built-in handler may touch. Chat.svelte passes an adapter over
 * its component state; tests pass a fake. */
export interface SlashContext {
  /** The text after the command name (after the subcommand when dispatched). */
  arg: string;
  /** Append a transcript line. sessionId targets a specific conversation's
   * view (discover may start one); omitted means the current view. */
  meta(text: string, sessionId?: string): void;
  error(text: string): void;
  /** Bus tool call (core/provider/...). */
  send(component: string, tool: string, args: Record<string, unknown>, timeoutMs?: number): Promise<any>;
  /** UI action strings the component switches on (mode changes, pickers). */
  command(action: string): void;
  /** Submit text as a user turn (the userMessage convention, WIRE.md). */
  submit(text: string): Promise<void>;
  /** True while a turn is streaming (explicit discovery must wait). */
  busy(): boolean;
  /** The conversation this input belongs to. */
  session(): string | undefined;
  /** Adopt a conversation id for this view (discover starts one when absent). */
  adoptSession(id: string): void;
  newSessionId(): string;
  locale(): string;
  setLocale(locale: string): void;
  thinkLevel(): string;
  setThinkLevel(level: string): void;
  toolLevel(): string;
  setToolLevel(level: string): void;
  isValidEffort(level: string): boolean;
  profile(): string;
  setProfile(name: string): Promise<void>;
  componentsText(filter: string): Promise<string>;
  statusText(): Promise<string>;
  infoText(sessionId: string): Promise<string>;
  helpText(): string;
  /** Localized chrome string ("chat.slashFailed", …). The key is free-form
   * here so this module stays independent of the i18n dictionary type. */
  t(key: string, vars?: Record<string, string>): string;
}

export type SlashHandler = (ctx: SlashContext) => Promise<void> | void;

/** Keys are declared built-in names (canonical only: an alias resolves through
 * `aliasOf`) or "<command> <subcommand>". */
export const slashHandlers: Record<string, SlashHandler> = {
  new: (ctx) => ctx.command(ctx.arg ? "new-session:" + ctx.arg.trim() : "new-session"),
  session: async (ctx) => {
    if (ctx.arg) return void ctx.command("switch-session:" + ctx.arg.trim());
    ctx.command("sessions");
  },
  provider: async (ctx) => {
    const [first, ...rest] = ctx.arg.split(/\s+/).filter(Boolean);
    if (first) {
      const cmd = commandNamed("provider");
      const sub = cmd && subcommandOf(cmd, first);
      if (sub) return runSubcommand(cmd!, sub, ctx, rest.join(" "));
    }
    if (!ctx.arg) return void ctx.command("providers");
    ctx.command("provider-switch:" + ctx.arg);
  },
  "provider environment": (ctx) => ctx.command("provider-env"),
  "provider strip": (ctx) => {
    const mode = ctx.arg.split(/\s+/).filter(Boolean)[0];
    ctx.command("provider-strip:" + (mode !== "off"));
  },
  model: (ctx) => {
    if (!ctx.arg) return void ctx.command("model");
    ctx.command("model-set:" + (ctx.arg === "default" ? "" : ctx.arg));
  },
  effort: (ctx) => {
    const level = ctx.arg.toLowerCase();
    if (level && !ctx.isValidEffort(level)) {
      return void ctx.error("effort: expected one of auto, low, medium, high");
    }
    ctx.command("effort-set:" + (level === "auto" ? "" : level));
  },
  think: (ctx) => {
    const level = ctx.arg.toLowerCase();
    if (level && ["full", "brief", "off"].includes(level)) ctx.setThinkLevel(level);
    else if (!level) {
      const current = ctx.thinkLevel();
      ctx.setThinkLevel(current === "full" ? "brief" : current === "brief" ? "off" : "full");
    }
    ctx.meta(ctx.t("chat.thinkLevel", { level: ctx.thinkLevel() }));
  },
  tools: (ctx) => {
    const level = ctx.arg.toLowerCase();
    if (level && ["brief", "full", "off"].includes(level)) ctx.setToolLevel(level);
    else if (!level) {
      const current = ctx.toolLevel();
      ctx.setToolLevel(current === "brief" ? "full" : current === "full" ? "off" : "brief");
    }
    ctx.meta(ctx.t("chat.toolLevel", { level: ctx.toolLevel() }));
  },
  connect: (ctx) => ctx.command("connect"),
  status: async (ctx) => ctx.meta(await ctx.statusText()),
  components: async (ctx) => ctx.meta(await ctx.componentsText(ctx.arg || "all")),
  profile: async (ctx) => {
    if (ctx.arg) await ctx.setProfile(ctx.arg);
    const listing = await ctx.send("core", "profile", { op: "list" });
    const lines = (listing?.profiles ?? [])
      .map((p: any) => `${p.name}: ${p.toolCount} tools, ~${p.estTokens} tokens`)
      .join("\n");
    ctx.meta(`Profile for new chats: ${ctx.profile() || "default"}\n` + lines);
  },
  discover: async (ctx) => {
    if (ctx.busy()) throw new Error("Wait for the current turn to finish before explicit discovery.");
    if (!ctx.arg) throw new Error("Usage: /discover COMPONENT or /discover tool=NAME");
    const sid = ctx.session() ?? ctx.newSessionId();
    ctx.adoptSession(sid);
    const discovery = ctx.arg.startsWith("tool=") ? { tools: [ctx.arg.slice(5)] } : { component: ctx.arg };
    const result = await ctx.send("core", "session", { sessionId: sid, profile: ctx.profile(), discovery }, 60000);
    ctx.meta(JSON.stringify(result?.discovery, null, 2), sid);
  },
  locale: (ctx) => {
    const lang = ctx.arg || ctx.locale();
    if (lang === "en" || lang === "zh" || lang === "zh-TW") ctx.setLocale(lang);
    else ctx.error(`unknown locale "${lang}" (en, zh, zh-TW)`);
  },
  info: async (ctx) => {
    const sid = (ctx.arg || ctx.session() || "").trim();
    if (!sid) return void ctx.error(ctx.t("info.noSession"));
    ctx.meta(await ctx.infoText(sid));
  },
  help: (ctx) => ctx.meta(ctx.helpText()),
};

/** Installable plugin command (any name that is not a declared built-in):
 * parse against the declared params and issue the target tool call. */
export async function runPluginCommand(cmd: SlashCommand, rawArgs: string, ctx: SlashContext): Promise<void> {
  const parsed = parseSlashArgs(cmd, rawArgs);
  if (parsed.error) return void ctx.error(`/${cmd.name}: ${parsed.error}`);
  ctx.meta(ctx.t("chat.slashExec", { name: cmd.name, args: rawArgs.trim() }));
  const invocationSession = ctx.session();
  const result = await ctx.send(cmd.component!, cmd.tool!, parsed.args);
  const message = slashUserMessage(result);
  if (message !== undefined) {
    if (ctx.session() !== invocationSession) {
      throw new Error("Conversation changed while rendering; run the command again in the intended conversation");
    }
    await ctx.submit(message);
  } else {
    ctx.meta(formatSlashResult(result));
  }
}

/** True when the name is a declared built-in (alias included). */
export function isBuiltinCommand(name: string): boolean {
  return builtinSlashCommands().some((c) => c.name === name);
}

/** The declared built-in entry for a name. */
export function commandNamed(name: string): SlashCommand | undefined {
  return builtinSlashCommands().find((c) => c.name === name);
}

/** Run a declared subcommand (already resolved through its aliases). */
export function runSubcommand(cmd: SlashCommand, sub: SlashSubcommand, ctx: SlashContext, arg = ""): Promise<void> | void {
  const handler = slashHandlers[`${cmd.name} ${sub.name}`];
  if (!handler) throw new Error(`/${cmd.name} ${sub.name} is declared without a handler`);
  return handler({ ...ctx, arg });
}

/** Dispatch a built-in command line. `name` is the typed name (alias allowed),
 * `rawArgs` everything after it. */
export async function runBuiltinCommand(name: string, rawArgs: string, ctx: SlashContext): Promise<void> {
  const canonical = builtinSlashCommands().find((c) => c.name === name)?.aliasOf ?? name;
  const handler = slashHandlers[canonical];
  if (!handler) throw new Error(`/${name} is declared without a handler`);
  await handler({ ...ctx, arg: rawArgs });
}

/** The keys the handler table must cover: canonical built-in names plus one
 * per declared subcommand. tests/slash.test.mjs compares this with the table. */
export function declaredHandlerKeys(): string[] {
  const keys: string[] = [];
  for (const cmd of builtinSlashCommands()) {
    if (cmd.aliasOf) continue;
    keys.push(cmd.name);
    for (const sub of cmd.subcommands ?? []) keys.push(`${cmd.name} ${sub.name}`);
  }
  return keys;
}
