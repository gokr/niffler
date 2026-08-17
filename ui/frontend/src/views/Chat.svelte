<script lang="ts">
  import { onMount, tick } from "svelte";
  import { send, on } from "../nats";
  import { renderMarkdown } from "$lib/markdown";
  import ToolCall from "./ToolCall.svelte";

  interface Msg {
    role: "user" | "assistant" | "tool";
    content?: string;
    tool?: string;
    args?: any;
    result?: any;
    error?: string;
    pending?: boolean;
  }

  let { sessionId = $bindable(null) } = $props<{ sessionId: string | null }>();

  let messages = $state<Msg[]>([]);
  let input = $state("");
  let busy = $state(false);
  let scrollEl: HTMLDivElement | undefined = $state();

  function push(msg: Msg) {
    messages = [...messages, msg];
    tick().then(() => {
      scrollEl?.scrollTo({ top: scrollEl.scrollHeight });
    });
  }

  // ---- load history from the store --------------------------------------
  onMount(async () => {
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
        push({ role: "assistant", content: p.content });
      } else if (kind === "done") {
        busy = false;
        if (p.error) push({ role: "assistant", content: "⚠ " + p.error });
        else if (p.reply && messages.at(-1)?.content !== p.reply) {
          push({ role: "assistant", content: p.reply });
        }
      }
    });

    if (sessionId) {
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
            stored.push({ role: "assistant", content: v.content ?? "" });
          } else {
            stored.push({ role: "user", content: v.content ?? "" });
          }
        }
        messages = stored;
        tick().then(() => scrollEl?.scrollTo({ top: scrollEl.scrollHeight }));
      } catch {
        /* store unavailable — start empty */
      }
    }
    return off;
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
      sessionId = sid;
    }
    push({ role: "user", content: text });
    push({ role: "assistant", content: "", pending: true });

    try {
      await send("core", "session", { sessionId: sid, content: text }, 600000);
    } catch (e) {
      push({ role: "assistant", content: "⚠ " + String(e) });
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
          {#if m.pending && !m.content}
            <span class="text-ink-400 animate-pulse">thinking…</span>
          {:else}
            {@html renderMarkdown(m.content ?? "")}
          {/if}
        </div>
      {/if}
    {/each}
  </div>

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
      placeholder="Ask mini Niffler to do something…"
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
