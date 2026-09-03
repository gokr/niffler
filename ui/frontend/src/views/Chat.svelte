<script lang="ts">
  import { onMount, tick } from "svelte";
  import { send, on, emit } from "../nats";
  import { renderMarkdown } from "$lib/markdown";
  import ToolRun from "./ToolRun.svelte";
  import Thinking from "../components/Thinking.svelte";
  import { t } from "$lib/i18n.svelte";
  import { thinkLevel, toolLevel, setThinkLevel, setToolLevel, type ThinkLevel, type ToolLevel } from "../lib/prefs.svelte";
  import {
    mergeSlashCommands,
    loadPluginSlashCommands,
    parseSlashArgs,
    slashCompletion,
    fetchCompletionValues,
    suggestSlash,
    type SlashCommand,
    type CompletionState,
  } from "../lib/slash";
  import { effortLabel, nextEffort, isValidEffort, saveThinkingEffort, type EffortLevel } from "../lib/effort";
  import { setLocale, locale } from "../lib/i18n.svelte";

  interface Usage {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
    prompt_tokens_details?: { cached_tokens?: number };
  }

  interface Msg {
    role: "user" | "assistant" | "tool" | "meta" | "error";
    content?: string;
    reasoning?: string;
    tool?: string;
    args?: any;
    result?: any;
    error?: string;
    pending?: boolean;
    model?: string;
    context?: number;
    usage?: Usage;
  }

  let { sessionId = $bindable(null), onCommand = () => {} }: { sessionId: string | null; onCommand?: (cmd: string) => void } = $props();

  // Per-session live state, keyed by the session the EVENT carries (not by
  // the prop — events self-route, so a turn that keeps streaming after a
  // sidebar switch stays in its own session's buffer and can never bleed
  // into the view of another session).
  interface Live {
    messages: Msg[];
    liveIdx: number | null;
    roundDone: boolean;
    busy: boolean;
    stopping: boolean;
    stopArmed: boolean;
    ctxNote: string;
  }
  const sessions = $state<Record<string, Live>>({});
  // Read-only fallback for renders that run before the session's entry has
  // been created (the effect creates it on the same flush). Never mutated.
  const EMPTY_LIVE: Live = { messages: [], liveIdx: null, roundDone: false, busy: false, stopping: false, stopArmed: false, ctxNote: "" };

  function liveOf(sid: string | null): Live {
    return sessions[sid ?? ""] ?? EMPTY_LIVE;
  }

  // Mutation path: creates the session's live entry on first touch. Never
  // called from a $derived — only from effects and event handlers.
  function ensureLive(sid: string | null): Live {
    const key = sid ?? "";
    let l = sessions[key];
    if (!l) {
      l = { messages: [], liveIdx: null, roundDone: false, busy: false, stopping: false, stopArmed: false, ctxNote: "" };
      sessions[key] = l;
    }
    return l;
  }

  // What the chat pane shows: the buffer of the selected session.
  const view = $derived(liveOf(sessionId));

  let input = $state("");
  let scrollEl: HTMLDivElement | undefined = $state();
  // Bash-style command history: ArrowUp/ArrowDown walk past submissions,
  // editing without navigating keeps the draft safe for ArrowDown to return.
  let history = $state<string[]>([]);
  let histIdx = $state(-1);
  let histDraft = $state("");
  // The id we minted ourselves this turn (a brand-new session). While set,
  // session switches initiated by our own send must not reload history —
  // those messages are live and must not be replaced by an empty read.
  let createdHere = $state<string | null>(null);
  let createdTitle = $state("");

  // ---- slash command registry ----------------------------------------------
  let slashCmds = $state<SlashCommand[]>(mergeSlashCommands([]));
  let complete = $state<(CompletionState & { candidates?: string[]; index?: number; loading?: boolean }) | null>(null);

  onMount(() => {
    loadPluginSlashCommands().then((cmds) => {
      slashCmds = mergeSlashCommands(cmds);
    });
    const off = on("ev.catalog.updated", () => {
      // Components registered or departed: the slash registry changed.
      // Core checkpoints the merged table to the store before announcing.
      loadPluginSlashCommands().then((cmds) => {
        slashCmds = mergeSlashCommands(cmds);
      });
    });
    return off;
  });

  // Tab completion: fetch source-tool candidates lazily. Stale results (the
  // user kept typing, or restarted completion) are dropped by matching the
  // token they were requested for.
  let completeToken = 0;
  async function openCompletion() {
    const c = slashCompletion(input, slashCmds);
    if (!c) {
      complete = null;
      return;
    }
    if (c.source) {
      complete = { ...c, loading: true };
      const myToken = ++completeToken;
      try {
        const values = await fetchCompletionValues(c.source);
        if (myToken !== completeToken || !complete?.loading) return; // stale
        const filtered = values.filter((v) => v.startsWith(c.token));
        if (filtered.length === 0) {
          complete = null;
          return;
        }
        if (filtered.length === 1) {
          input = c.prefix + filtered[0];
          complete = null;
          return;
        }
        complete = { ...c, candidates: filtered, index: 0 };
      } catch {
        complete = null;
      }
      return;
    }
    if (c.values) {
      const filtered = c.values.filter((v) => v.startsWith(c.token));
      if (filtered.length === 0) {
        complete = null;
        return;
      }
      if (filtered.length === 1) {
        input = c.prefix + filtered[0];
        complete = null;
        return;
      }
      complete = { ...c, candidates: filtered, index: 0 };
      return;
    }
    // Command-name completion: cycle directly, no popup needed for one hit.
    const names = slashCmds.map((x) => x.name).filter((n) => n.startsWith(c.token));
    if (names.length === 1) {
      input = "/" + names[0] + " ";
      complete = null;
      return;
    }
    if (names.length === 0) {
      complete = null;
      return;
    }
    // Candidates are bare names; the fill concatenates prefix ("/") + name.
    complete = { ...c, candidates: names, index: 0 };
  }

  function cycleCompletion(backward: boolean) {
    if (!complete?.candidates || complete.candidates.length === 0) return;
    const n = complete.candidates.length;
    const i = complete.index ?? 0;
    complete = { ...complete, index: (i + (backward ? -1 : 1) + n) % n };
    input = complete.prefix + complete.candidates[(complete.index ?? 0)];
  }

  function acceptCompletion() {
    // The highlighted candidate is already filled into the input; dismiss.
    complete = null;
  }

  // ---- transcript meta blocks ------------------------------------------------
  function addMeta(l: Live, text: string) {
    l.messages = [...l.messages, { role: "meta", content: text }];
    scroll();
  }

  function addError(l: Live, text: string) {
    l.messages = [...l.messages, { role: "error", content: text }];
    scroll();
  }

  // ---- local slash command execution ------------------------------------------
  // Returns true when the input was consumed as a command.
  async function handleSlash(l: Live, line: string): Promise<boolean> {
    const parts = line.trim().split(/\s+/);
    const name = (parts[0] ?? "").slice(1).toLowerCase();
    const arg = parts.slice(1).join(" ");
    const cmd = slashCmds.find((c) => c.name === name);
    if (!cmd) {
      addError(l, t("chat.unknownCommand", { name }) + suggestSlash(slashCmds, name));
      return true;
    }

    switch (name) {
      case "provider":
      case "providers":
        if (!arg) {
          onCommand("providers");
          return true;
        }
        if (arg === "environment" || arg === "env") onCommand("provider-env");
        else if (arg === "strip" || arg.startsWith("strip ")) onCommand("provider-strip:" + (arg.split(/\s+/)[1] !== "off"));
        else onCommand("provider-switch:" + arg);
        return true;
      case "model":
      case "models":
        if (!arg) {
          onCommand("model");
          return true;
        }
        onCommand("model-set:" + (arg === "default" ? "" : arg));
        return true;
      case "effort": {
        const level = (arg || "").toLowerCase();
        if (level && !isValidEffort(level)) {
          addError(l, "effort: expected one of auto, low, medium, high");
          return true;
        }
        onCommand("effort-set:" + (level === "auto" ? "" : level));
        return true;
      }
      case "think": {
        const level = (arg || "").toLowerCase() as ThinkLevel;
        if (level && ["full", "brief", "off"].includes(level)) setThinkLevel(level);
        else if (!level) setThinkLevel(thinkLevel() === "full" ? "brief" : thinkLevel() === "brief" ? "off" : "full");
        addMeta(l, t("chat.thinkLevel", { level: thinkLevel() }));
        return true;
      }
      case "tools": {
        const level = (arg || "").toLowerCase() as ToolLevel;
        if (level && ["brief", "full", "off"].includes(level)) setToolLevel(level);
        else if (!level) setToolLevel(toolLevel() === "brief" ? "full" : toolLevel() === "full" ? "off" : "brief");
        addMeta(l, t("chat.toolLevel", { level: toolLevel() }));
        return true;
      }
      case "connect":
        onCommand("connect");
        return true;
      case "status":
        addMeta(l, await buildStatusText());
        return true;
      case "new":
      case "newsession":
        onCommand("new-session" + (arg ? ":" + arg.trim() : ""));
        return true;
      case "session":
      case "sessions":
        if (arg) {
          onCommand("switch-session:" + arg.trim());
          return true;
        }
        onCommand("sessions");
        return true;
      case "locale": {
        const lang = arg || locale();
        if (lang === "en" || lang === "zh" || lang === "zh-TW") setLocale(lang);
        else addError(l, `unknown locale "${lang}" (en, zh, zh-TW)`);
        return true;
      }
      case "help":
      case "?":
        addMeta(l, helpText());
        return true;
      default: {
        // Registered plugin command: parse against the declared params and
        // issue the target tool call; the result lands as a meta block.
        const parsed = parseSlashArgs(cmd, arg);
        if (parsed.error) {
          addError(l, `/${cmd.name}: ${parsed.error}`);
          return true;
        }
        addMeta(l, t("chat.slashExec", { name: cmd.name, args: arg.trim() }));
        try {
          const result = await send(cmd.component!, cmd.tool!, parsed.args);
          addMeta(l, t("chat.slashResult", { name: cmd.name, result: compactJSON(result) }));
        } catch (e) {
          addError(l, t("chat.slashFailed", { name: cmd.name, err: String(e) }));
        }
        return true;
      }
    }
  }

  function compactJSON(v: unknown): string {
    try {
      const s = JSON.stringify(v);
      return s.length > 400 ? s.slice(0, 400) + "…" : s;
    } catch {
      return "";
    }
  }

  function helpText(): string {
    const lines = [
      t("help.title"),
      t("help.new"),
      t("help.session"),
      t("help.provider"),
      t("help.model"),
      t("help.effort"),
      t("help.connect"),
      t("help.status"),
      t("help.think"),
      t("help.tools"),
      t("help.help"),
      "",
      t("help.keys"),
    ];
    const plugins = slashCmds.filter((c) => !c.builtin);
    if (plugins.length > 0) {
      lines.push("", t("help.pluginTitle"));
      for (const c of plugins) lines.push(`  /${c.name}${c.description ? " — " + c.description : ""} (${c.component})`);
    }
    return lines.join("\n");
  }

  async function buildStatusText(): Promise<string> {
    try {
      const [runtime, conv] = await Promise.all([
        sessionId ? send("llm", "llm_resolve", sessionModel ? { model: sessionModel } : {}) : Promise.resolve(null),
        sessionId
          ? send("store", "get", { kind: "conversation", id: sessionId }).catch(() => null)
          : Promise.resolve(null),
      ]);
      const lines: string[] = [];
      if (runtime) {
        lines.push(t("status.detailProvider", { provider: runtime.provider || t("status.unknown"), source: runtime.providerSource || t("status.unknownSource") }));
        lines.push(t("status.detailModel", { model: runtime.model || t("status.unknown") }));
        lines.push(t("status.detailCatalog", { catalog: runtime.catalog || t("status.none") }));
        lines.push(t("status.detailContext", { context: fmtK(runtime.context), source: runtime.contextSource || t("status.unknownSource") }));
        lines.push(t("status.detailOutput", { output: fmtK(runtime.output), source: runtime.outputSource || t("status.unknownSource") }));
        const used = conv?.value?.contextUsed ?? 0;
        const pct = runtime.context > 0 ? Math.round((used / runtime.context) * 100) : 0;
        lines.push(t("status.detailUsed", { used: fmtK(used), pct: String(pct) }));
        const cp = conv?.value?.cachePrompt ?? 0;
        const cr = conv?.value?.cacheRead ?? 0;
        if (cp > 0) {
          const rate = typeof conv?.value?.cacheHitRate === "number"
            ? conv.value.cacheHitRate
            : Math.round((cr / cp) * 1000) / 10;
          lines.push(t("status.detailCache", { read: fmtK(cr), prompt: fmtK(cp), rate: String(rate) }));
        }
      }
      const v = conv?.value ?? {};
      if (v.modelOverride) lines.push(t("status.detailOverride", { model: v.modelOverride }));
      return lines.join("\n") || t("status.unknown");
    } catch {
      return t("status.unknown");
    }
  }

  function fmtK(n?: number): string {
    if (!n) return "—";
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
    if (n >= 1000) return (n / 1000).toFixed(1) + "k";
    return String(n);
  }

  // Session-scoped model override, kept in sync with App.svelte's picker.
  let sessionModel = $state("");

  /** Called by App.svelte when the model override changes for this session. */
  export function setSessionModel(model: string) {
    sessionModel = model;
  }

  // ---- send / steer / stop -----------------------------------------------------

  async function sendMsg() {
    const text = input.trim();
    if (!text) return;

    // A slash command line is local — never sent to the model, never
    // recorded in sent-message history or the transcript.
    if (text.startsWith("/")) {
      input = "";
      histIdx = -1;
      await handleSlash(ensureLive(sessionId), text);
      return;
    }

    const l = ensureLive(sessionId);
    if (l.busy) {
      // Steer the running turn (Pi/TUI-style): fold into the live
      // conversation; busy stays true until the turn completes.
      input = "";
      histIdx = -1;
      push(l, { role: "user", content: "Steer: " + text });
      try {
        emit(`svc.session.${sanitize(sessionId ?? "")}.steer`, { sessionId, content: text });
      } catch {
        addError(l, "steer failed");
      }
      return;
    }

    input = "";
    if (history[history.length - 1] !== text) {
      history = [...history.slice(-199), text];
    }
    histIdx = -1;
    histDraft = "";

    let sid = sessionId;
    if (!sid) {
      sid = crypto.randomUUID();
      createdHere = sid;
      createdTitle = text;
      sessionId = sid;
    }
    const live = ensureLive(sid);
    live.busy = true;
    live.stopping = false;
    live.stopArmed = false;
    push(live, { role: "user", content: text });
    push(live, { role: "assistant", content: "", pending: true });
    live.liveIdx = live.messages.length - 1;

    try {
      await send("core", "session", { sessionId: sid, content: text, model: sessionModel }, 600000);
      if (createdHere === sid) {
        createdHere = null;
        await titleSession(sid, createdTitle);
      }
    } catch (e) {
      live.busy = false;
      live.liveIdx = null;
      resolvePending(live, { content: "⚠ " + String(e) });
    }
  }

  function sanitize(id: string): string {
    return id.replace(/[^A-Za-z0-9_-]/g, "-");
  }

  /** Two-stage stop: first click arms, second force-cancels the running
   * LLM stream via llm.cancel.<sessionId>. */
  function stopClicked() {
    const l = ensureLive(sessionId);
    if (!l.busy) return;
    if (!l.stopArmed) {
      l.stopArmed = true;
      return;
    }
    l.stopping = true;
    l.stopArmed = false;
    try {
      emit(`llm.cancel.${sanitize(sessionId ?? "")}`, { sessionId });
    } catch {
      /* the turn will end on its own */
    }
  }

  // Consecutive tool messages render as one card (a "run") so a multi-step
  // turn doesn't fill the chat with individual tool cards. Message indexes
  // are stable (messages only ever append), so each group's key — the index
  // of its first message — is stable too.
  type Group =
    | { kind: "run"; key: string; items: Msg[] }
    | { kind: "single"; key: string; m: Msg };
  const groups = $derived.by(() => {
    const msgs = view.messages;
    const out: Group[] = [];
    for (let i = 0; i < msgs.length; i++) {
      const m = msgs[i];
      if (m.role === "tool") {
        const last = out[out.length - 1];
        if (last?.kind === "run") last.items.push(m);
        else out.push({ kind: "run", key: "run-" + i, items: [m] });
      } else {
        out.push({ kind: "single", key: "single-" + i, m });
      }
    }
    return out;
  });

  // Update the in-flight turn's assistant bubble in place, or append one if
  // there is no live turn (e.g. events arriving after a session switch).
  // If the turn's anchor was lost (done resets liveIdx), fall back to the
  // most recent assistant message so a finalize never spawns a duplicate bubble.
  function resolvePending(l: Live, update: Partial<Msg>) {
    let target: Msg | null = null;
    if (l.liveIdx != null && l.liveIdx < l.messages.length && l.messages[l.liveIdx]) {
      target = l.messages[l.liveIdx];
    } else {
      for (let i = l.messages.length - 1; i >= 0; i--) {
        if (l.messages[i].role === "assistant") {
          target = l.messages[i];
          break;
        }
      }
    }
    if (target) {
      Object.assign(target, update, { pending: false });
      scroll();
    } else {
      push(l, { role: "assistant", ...update });
    }
  }

  function push(l: Live, msg: Msg) {
    l.messages = [...l.messages, msg];
    scroll();
  }

  function scroll() {
    tick().then(() => scrollEl?.scrollTo({ top: scrollEl.scrollHeight }));
  }

  // Live LLM deltas (ev.session.token): append to the current round's
  // assistant bubble. When the previous round was committed (assistant
  // event) the next round gets its own bubble — otherwise a multi-round
  // turn would keep overwriting the same div with each round's text.
  function appendToken(l: Live, content: string, reasoning: string) {
    if (l.roundDone) {
      l.roundDone = false;
      push(l, { role: "assistant", content: "" });
      l.liveIdx = l.messages.length - 1;
    }
    let target: Msg | null = null;
    if (l.liveIdx != null && l.liveIdx < l.messages.length && l.messages[l.liveIdx]) {
      target = l.messages[l.liveIdx];
    } else {
      for (let i = l.messages.length - 1; i >= 0; i--) {
        if (l.messages[i].role === "assistant") {
          target = l.messages[i];
          break;
        }
      }
    }
    if (!target) return;
    if (content) target.content = (target.content ?? "") + content;
    if (reasoning) target.reasoning = (target.reasoning ?? "") + reasoning;
    scroll();
  }

  async function loadHistory(l: Live, sid: string | null) {
    if (!sid) return;
    try {
      const resp = await send("store", "list", {
        kind: "message",
        idPrefix: sid + ":",
      });
      const stored: Msg[] = [];
      for (const item of resp.items ?? []) {
        const v = item.value ?? {};
        if (v.role === "tool") {
          stored.push({ role: "tool", content: v.content, tool: v.name });
        } else if (v.role === "assistant") {
          stored.push({
            role: "assistant",
            content: v.content ?? "",
            reasoning: v.reasoning ?? "",
            model: v.model,
            context: v.context,
            usage: v.usage,
          });
        } else {
          stored.push({ role: "user", content: v.content ?? "" });
        }
      }
      l.messages = stored;
      l.liveIdx = null;
      scroll();
    } catch {
      /* store unavailable — start empty */
    }
  }

  onMount(() => {
    const off = on("ev.session.", (ev) => {
      const p = ev.payload ?? {};
      const l = ensureLive(p.sessionId ?? null);
      const kind = ev.subject.slice("ev.session.".length);
      if (kind === "toolcall") {
        const existing = l.messages.find(
          (m) => m.role === "tool" && m.pending && m.tool === p.tool
        );
        if (existing) {
          existing.pending = false;
          existing.result = p.result;
          existing.error = p.error;
        } else {
          push(l, {
            role: "tool",
            tool: p.tool,
            args: p.args,
            result: p.result,
            error: p.error,
          });
        }
      } else if (kind === "assistant") {
        resolvePending(l, {
          content: p.content,
          model: p.model,
          context: p.context,
          usage: p.usage,
        });
        // Round committed: the next streamed round starts a fresh bubble.
        l.roundDone = true;
      } else if (kind === "token") {
        appendToken(l, p.content ?? "", p.reasoning ?? "");
      } else if (kind === "done") {
        l.busy = false;
        l.stopping = false;
        l.stopArmed = false;
        l.liveIdx = null;
        l.roundDone = false;
        if (p.error) resolvePending(l, { content: "⚠ " + p.error });
        else if (p.reply) resolvePending(l, { content: p.reply });
      } else if (kind === "context") {
        if (p.trimmed) {
          l.ctxNote = t("chat.contextTrimmed", { n: String(p.trimmed) });
        } else if (p.warning) {
          const pct = p.context ? Math.round((p.promptTokens / p.context) * 100) : 0;
          l.ctxNote = t("chat.contextAt", { pct: String(pct) });
        }
      }
    });
    const l = ensureLive(sessionId);
    if (l.messages.length === 0) loadHistory(l, sessionId);
    return off;
  });

  // Session changed from outside (sidebar click, "+ New session"): show that
  // session's live buffer, loading its history only on first visit — a turn
  // still streaming after a switch is not disturbed by the reload.
  $effect(() => {
    if (createdHere && sessionId === createdHere) return;
    createdHere = null;
    const l = ensureLive(sessionId);
    if (l.messages.length === 0) loadHistory(l, sessionId);
  });

  // Name a brand-new session after its first message so the sidebar shows
  // something readable instead of a UUID fragment.
  async function titleSession(sid: string, title: string) {
    try {
      const g = await send("store", "get", { kind: "conversation", id: sid });
      const v = g.value ?? {};
      if (v.title) return; // someone renamed it meanwhile — keep theirs
      const title2 = title.length > 60 ? title.slice(0, 60) + "…" : title;
      await send("store", "put", { kind: "conversation", id: sid, value: { ...v, title: title2 } });
    } catch {
      /* store unreachable — title stays empty */
    }
  }
</script>

<div class="flex-1 flex flex-col min-h-0">
  <div bind:this={scrollEl} class="flex-1 overflow-y-auto px-6 py-4 flex flex-col gap-3">
    {#each groups as g (g.key)}
      {#if g.kind === "run"}
        <ToolRun items={g.items} />
      {:else if g.m.role === "user"}
        <div class="msg-user">{g.m.content}</div>
      {:else if g.m.role === "meta"}
        <div class="msg-meta-block">{g.m.content}</div>
      {:else if g.m.role === "error"}
        <div class="msg-error-block">{g.m.content}</div>
      {:else}
        <div class="msg-assistant">
          {#if g.m.pending && !g.m.content && !g.m.reasoning}
            <span class="text-ink-400 animate-pulse">thinking…</span>
          {:else}
            <Thinking text={g.m.reasoning ?? ""} />
            {@html renderMarkdown(g.m.content ?? "")}
          {/if}
          {#if g.m.model || g.m.usage}
            <div class="msg-meta">
              {#if g.m.model}
                <span class="msg-meta-item">{g.m.model}</span>
              {/if}
              {#if g.m.usage?.prompt_tokens != null || g.m.usage?.completion_tokens != null}
                <span class="msg-meta-item">
                  ⤴ {g.m.usage?.prompt_tokens ?? 0} · ⤵ {g.m.usage?.completion_tokens ?? 0}
                </span>
              {/if}
              {#if (g.m.usage?.prompt_tokens_details?.cached_tokens ?? 0) > 0}
                <span class="msg-meta-item" title="provider prompt-cache hits (A3)">
                  ⚡ {g.m.usage?.prompt_tokens_details?.cached_tokens}/{g.m.usage?.prompt_tokens} cached
                </span>
              {/if}
              {#if g.m.usage?.total_tokens != null}
                <span class="msg-meta-item">Σ {g.m.usage.total_tokens}</span>
              {/if}
              {#if g.m.model && g.m.context}
                <span class="msg-meta-item">ctx {g.m.context.toLocaleString()}</span>
              {/if}
            </div>
          {/if}
        </div>
      {/if}
    {/each}
  </div>

  {#if view.ctxNote}
    <div class="px-6 pb-1 text-[12px] text-warn">{view.ctxNote}</div>
  {/if}

  <form
    class="px-6 py-4 border-t border-ink-700 flex gap-2"
    onsubmit={(e) => {
      e.preventDefault();
      sendMsg();
    }}
  >
    <div class="flex-1 flex flex-col gap-1">
      {#if complete}
        <div class="text-[12px] text-ink-400 flex flex-wrap gap-2 items-center">
          {#if complete.loading}
            <span class="animate-pulse">{t("chat.completing", { token: complete.token })}</span>
          {:else}
            {#each complete.candidates ?? [] as cand, i (cand)}
              <button
                type="button"
                class="rounded px-1.5 py-0.5 {i === complete.index ? 'bg-accent-dim/30 text-accent' : 'hover:bg-ink-800'}"
                onclick={() => {
                  complete = { ...complete!, index: i };
                  input = complete!.prefix + complete!.candidates![i];
                  acceptCompletion();
                }}
              >
                {cand}
              </button>
            {/each}
            <span class="text-ink-600">Tab cycles · Enter/Esc dismisses</span>
          {/if}
        </div>
      {/if}
      <textarea
        class="w-full resize-none rounded-lg bg-ink-800 border border-ink-600 px-3 py-2 text-[14px] text-ink-200 outline-none focus:border-accent-dim"
        rows="2"
        placeholder={view.busy ? t("chat.sendWhileBusy") : t("chat.placeholder")}
        bind:value={input}
        onkeydown={(e) => {
          if (e.key === "Tab" && input.startsWith("/")) {
            e.preventDefault();
            if (complete && !complete.loading && (complete.candidates?.length ?? 0) > 0) {
              // Popup already open: Tab/Shift+Tab cycle the highlighted
              // candidate (TUI behavior).
              cycleCompletion(e.shiftKey);
            } else {
              openCompletion();
            }
            return;
 }
          if ((e.key === "Enter" && !e.shiftKey) || e.key === "Escape") {
            if (complete && e.key === "Enter") {
              e.preventDefault();
              acceptCompletion();
              return;
            }
            if (complete && e.key === "Escape") {
              complete = null;
              return;
            }
            e.preventDefault();
            sendMsg();
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            if (history.length === 0) return;
            if (histIdx === -1) {
              histDraft = input;
              histIdx = history.length - 1;
            } else if (histIdx > 0) {
              histIdx--;
            }
            input = history[histIdx];
          } else if (e.key === "ArrowDown") {
            e.preventDefault();
            if (histIdx === -1) return;
            if (histIdx === history.length - 1) {
              histIdx = -1;
              input = histDraft;
            } else {
              histIdx++;
              input = history[histIdx];
            }
          }
        }}
        oninput={() => {
          // User typing dismisses an open popup (TUI behavior); cycling
          // fills the input programmatically, which does not fire input
          // events, so the popup survives Tab cycling.
          complete = null;
        }}
      ></textarea>
    </div>
    {#if view.busy}
      <button
        type="button"
        onclick={stopClicked}
        class="self-start rounded-lg border px-4 py-2 font-medium {view.stopping
          ? 'border-ink-600 text-ink-400'
          : view.stopArmed
            ? 'border-danger text-danger'
            : 'border-danger/50 text-danger hover:bg-danger/10'}"
      >
        {view.stopping ? t("app.stopping") : view.stopArmed ? t("app.stopConfirm") : t("app.stop")}
      </button>
    {:else}
      <button
        type="submit"
        disabled={!input.trim()}
        class="self-start rounded-lg bg-accent-dim/20 text-accent px-4 py-2 font-medium hover:bg-accent-dim/30 disabled:opacity-40"
      >
        {t("chat.send")}
      </button>
    {/if}
  </form>
</div>
