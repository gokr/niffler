<script lang="ts">
  import { onMount, tick } from "svelte";
  import { send, on } from "../nats";
  import { renderMarkdown } from "$lib/markdown";
  import ToolCall from "./ToolCall.svelte";

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

  let messages = $state<Msg[]>([]);
  let input = $state("");
  let busy = $state(false);
  let ctxNote = $state("");
  let scrollEl: HTMLDivElement | undefined = $state();
  // Index of this turn's live assistant bubble. Core emits one assistant
  // event per LLM round — after the first one the pending bubble is no
  // longer pending, so finding it by `m.pending` would push a new bubble
  // per round (duplicate/intermediate bubbles). Update the same bubble in
  // place instead; a turn has exactly one assistant bubble.
  let liveIdx = $state<number | null>(null);
  // The id we minted ourselves this turn (a brand-new session). While set,
  // session switches initiated by our own send must not clobber live messages.
  let createdHere = $state<string | null>(null);
  let createdTitle = $state("");

  // Update the in-flight turn's assistant bubble in place, or append one if
  // there is no live turn (e.g. events arriving after a session switch).
  // If the turn's anchor was lost (done resets liveIdx), fall back to the
  // most recent assistant message so a finalize never spawns a duplicate bubble.
  function resolvePending(update: Partial<Msg>) {
    let target: Msg | null = null;
    if (liveIdx != null && liveIdx < messages.length && messages[liveIdx]) {
      target = messages[liveIdx];
    } else {
      for (let i = messages.length - 1; i >= 0; i--) {
        if (messages[i].role === "assistant") {
          target = messages[i];
          break;
        }
      }
    }
    if (target) {
      Object.assign(target, update, { pending: false });
      tick().then(() => scrollEl?.scrollTo({ top: scrollEl.scrollHeight }));
    } else {
      push({ role: "assistant", ...update });
    }
  }


  function push(msg: Msg) {
    messages = [...messages, msg];
    tick().then(() => {
      scrollEl?.scrollTo({ top: scrollEl.scrollHeight });
    });
  }

  // Live LLM deltas (ev.session.token): append to the turn's assistant
  // bubble without resolving it — "done" finalizes. Same anchor fallback
  // as resolvePending so a late frame never spawns a duplicate bubble.
  function appendToken(content: string, reasoning: string) {
    let target: Msg | null = null;
    if (liveIdx != null && liveIdx < messages.length && messages[liveIdx]) {
      target = messages[liveIdx];
    } else {
      for (let i = messages.length - 1; i >= 0; i--) {
        if (messages[i].role === "assistant") {
          target = messages[i];
          break;
        }
      }
    }
    if (!target) return;
    if (content) target.content = (target.content ?? "") + content;
    if (reasoning) target.reasoning = (target.reasoning ?? "") + reasoning;
    tick().then(() => scrollEl?.scrollTo({ top: scrollEl.scrollHeight }));
  }

  async function loadHistory() {
    if (!sessionId) return;
    try {
      const resp = await send("store", "list", {
        kind: "message",
        idPrefix: sessionId + ":",
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
      messages = stored;
      liveIdx = null;
      tick().then(() => scrollEl?.scrollTo({ top: scrollEl.scrollHeight }));
    } catch {
      /* store unavailable — start empty */
    }
  }

  onMount(() => {
    const off = on("ev.session.", (ev) => {
      const p = ev.payload ?? {};
      if (p.sessionId !== sessionId) return;
      const kind = ev.subject.slice("ev.session.".length);
      if (kind === "toolcall") {
        const existing = messages.find(
          (m) => m.role === "tool" && m.pending && m.tool === p.tool
        );
        if (existing) {
          existing.pending = false;
          existing.result = p.result;
          existing.error = p.error;
        } else {
          push({
            role: "tool",
            tool: p.tool,
            args: p.args,
            result: p.result,
            error: p.error,
          });
        }
      } else if (kind === "assistant") {
        resolvePending({
          content: p.content,
          model: p.model,
          context: p.context,
          usage: p.usage,
        });
      } else if (kind === "token") {
        appendToken(p.content ?? "", p.reasoning ?? "");
      } else if (kind === "done") {
        busy = false;
        liveIdx = null;
        if (p.error) resolvePending({ content: "⚠ " + p.error });
        else if (p.reply) resolvePending({ content: p.reply });
      } else if (kind === "context") {
        if (p.trimmed) {
          ctxNote = `context trimmed — dropped ${p.trimmed} earlier messages`;
        } else if (p.warning) {
          const pct = p.context ? Math.round((p.promptTokens / p.context) * 100) : 0;
          ctxNote = `context at ${pct}% — will trim soon`;
        }
      }
    });
    loadHistory();
    return off;
  });

  // Session changed from outside (sidebar click, "+ New session"): reload.
  // Skipped when the change is our own new-session mint — those messages are
  // still live and must not be replaced by an empty history read.
  $effect(() => {
    if (createdHere && sessionId === createdHere) return;
    createdHere = null;
    messages = [];
    liveIdx = null;
    ctxNote = "";
    loadHistory();
  });

  // ---- send ---------------------------------------------------------------
  async function sendMsg() {
    const text = input.trim();
    if (!text || busy) return;
    input = "";
    busy = true;

    let sid = sessionId;
    if (!sid) {
      sid = crypto.randomUUID();
      createdHere = sid;
      createdTitle = text;
      sessionId = sid;
    }
    push({ role: "user", content: text });
    push({ role: "assistant", content: "", pending: true });
    liveIdx = messages.length - 1;

    try {
      await send("core", "session", { sessionId: sid, content: text }, 600000);
      if (createdHere === sid) {
        createdHere = null;
        await titleSession(sid, createdTitle);
      }
    } catch (e) {
      busy = false;
      liveIdx = null;
      resolvePending({ content: "⚠ " + String(e) });
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
    {#each messages as m, i (i)}
      {#if m.role === "tool"}
        <ToolCall {m} />
      {:else if m.role === "user"}
        <div class="msg-user">{m.content}</div>
      {:else}
        <div class="msg-assistant">
          {#if m.pending && !m.content && !m.reasoning}
            <span class="text-ink-400 animate-pulse">thinking…</span>
          {:else}
            {#if m.reasoning}
              <div class="msg-reasoning">{m.reasoning}</div>
            {/if}
            {@html renderMarkdown(m.content ?? "")}
          {/if}
          {#if m.model || m.usage}
            <div class="msg-meta">
              {#if m.model}
                <span class="msg-meta-item">{m.model}</span>
              {/if}
              {#if m.usage?.prompt_tokens != null || m.usage?.completion_tokens != null}
                <span class="msg-meta-item">
                  ⤴ {m.usage?.prompt_tokens ?? 0} · ⤵ {m.usage?.completion_tokens ?? 0}
                </span>
              {/if}
              {#if m.usage?.total_tokens != null}
                <span class="msg-meta-item">Σ {m.usage.total_tokens}</span>
              {/if}
              {#if m.model && m.context}
                <span class="msg-meta-item">ctx {m.context.toLocaleString()}</span>
              {/if}
            </div>
          {/if}
        </div>
      {/if}
    {/each}
  </div>

  {#if ctxNote}
    <div class="px-6 pb-1 text-[12px] text-amber-400/90">{ctxNote}</div>
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
        }
      }}
    ></textarea>
    <button
      type="submit"
      disabled={busy || !input.trim()}
      class="rounded-lg bg-accent-dim/20 text-accent px-4 font-medium hover:bg-accent-dim/30 disabled:opacity-40"
    >
      Send
    </button>
  </form>
</div>
