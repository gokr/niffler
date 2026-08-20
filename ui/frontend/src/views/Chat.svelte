<script lang="ts">
  import { onMount, tick } from "svelte";
  import { send, on } from "../nats";
  import { renderMarkdown } from "$lib/markdown";
  import ToolRun from "./ToolRun.svelte";

  interface Usage {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  }

  interface Msg {
    role: "user" | "assistant" | "tool";
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

  let { sessionId = $bindable(null) } = $props<{ sessionId: string | null }>();

  // Per-session live state, keyed by the session the EVENT carries (not by
  // the prop — events self-route, so a turn that keeps streaming after a
  // sidebar switch stays in its own session's buffer and can never bleed
  // into the view of another session).
  interface Live {
    messages: Msg[];
    liveIdx: number | null;
    roundDone: boolean;
    busy: boolean;
    ctxNote: string;
  }
  const sessions = $state<Record<string, Live>>({});
  // Read-only fallback for renders that run before the session's entry has
  // been created (the effect creates it on the same flush). Never mutated.
  const EMPTY_LIVE: Live = { messages: [], liveIdx: null, roundDone: false, busy: false, ctxNote: "" };

  function liveOf(sid: string | null): Live {
    return sessions[sid ?? ""] ?? EMPTY_LIVE;
  }

  // Mutation path: creates the session's live entry on first touch. Never
  // called from a $derived — only from effects and event handlers.
  function ensureLive(sid: string | null): Live {
    const key = sid ?? "";
    let l = sessions[key];
    if (!l) {
      l = { messages: [], liveIdx: null, roundDone: false, busy: false, ctxNote: "" };
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
        l.liveIdx = null;
        l.roundDone = false;
        if (p.error) resolvePending(l, { content: "⚠ " + p.error });
        else if (p.reply) resolvePending(l, { content: p.reply });
      } else if (kind === "context") {
        if (p.trimmed) {
          l.ctxNote = `context trimmed — dropped ${p.trimmed} earlier messages`;
        } else if (p.warning) {
          const pct = p.context ? Math.round((p.promptTokens / p.context) * 100) : 0;
          l.ctxNote = `context at ${pct}% — will trim soon`;
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

  // ---- send ---------------------------------------------------------------
  async function sendMsg() {
    const text = input.trim();
    if (!text || view.busy) return;
    input = "";
    if (history[history.length - 1] !== text) {
      history = [...history.slice(-99), text];
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
    const l = ensureLive(sid);
    l.busy = true;
    push(l, { role: "user", content: text });
    push(l, { role: "assistant", content: "", pending: true });
    l.liveIdx = l.messages.length - 1;

    try {
      await send("core", "session", { sessionId: sid, content: text }, 600000);
      if (createdHere === sid) {
        createdHere = null;
        await titleSession(sid, createdTitle);
      }
    } catch (e) {
      l.busy = false;
      l.liveIdx = null;
      resolvePending(l, { content: "⚠ " + String(e) });
    }
  }

  // Name a brand-new session after its first message so the sidebar shows
  // something readable instead of a UUID fragment.
  async function titleSession(sid: string, title: string) {
    try {
      const g = await send("store", "get", { kind: "conversation", id: sid });
      const v = g.value ?? {};
      if (v.title) return; // someone renamed it meanwhile — keep theirs
      const t = title.length > 60 ? title.slice(0, 60) + "…" : title;
      await send("store", "put", { kind: "conversation", id: sid, value: { ...v, title: t } });
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
      {:else}
        <div class="msg-assistant">
          {#if g.m.pending && !g.m.content && !g.m.reasoning}
            <span class="text-ink-400 animate-pulse">thinking…</span>
          {:else}
            {#if g.m.reasoning}
              <div class="msg-reasoning">{g.m.reasoning}</div>
            {/if}
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
    <textarea
      class="flex-1 resize-none rounded-lg bg-ink-800 border border-ink-600 px-3 py-2 text-[14px] text-ink-200 outline-none focus:border-accent-dim"
      rows="2"
      placeholder="Ask Niffler to do something…"
      bind:value={input}
      onkeydown={(e) => {
        if (e.key === "Enter" && !e.shiftKey) {
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
    ></textarea>
    <button
      type="submit"
      disabled={view.busy || !input.trim()}
      class="rounded-lg bg-accent-dim/20 text-accent px-4 font-medium hover:bg-accent-dim/30 disabled:opacity-40"
    >
      Send
    </button>
  </form>
</div>
