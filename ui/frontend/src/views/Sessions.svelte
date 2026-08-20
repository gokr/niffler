<script lang="ts">
  import { onMount } from "svelte";
  import { send } from "../nats";

  interface SessionInfo {
    id: string;
    rev: number;
    value: { createdAt: number; model?: string; title?: string };
  }

  let { selectSession, sessionId, onDelete, refreshKey = $bindable(0) } = $props<{
    selectSession: (id: string) => void;
    sessionId: string | null;
    onDelete: (id: string) => void;
    refreshKey?: number;
  }>();

  let sessions = $state<SessionInfo[]>([]);
  let confirmId = $state<string | null>(null);
  let editingId = $state<string | null>(null);
  let editTitle = $state("");
  let confirmTimer: ReturnType<typeof setTimeout> | undefined = $state();

  async function load() {
    try {
      const resp = await send("store", "list", { kind: "conversation" });
      const items: SessionInfo[] = resp.items ?? [];
      items.sort((a, b) => (b.value?.createdAt ?? 0) - (a.value?.createdAt ?? 0));
      sessions = items;
    } catch {
      sessions = [];
    }
  }

  onMount(() => {
    load();
    // sessions materialize in the store when their first message is sent —
    // poll so new ones appear without any manual refresh.
    const t = setInterval(load, 3000);
    return () => clearInterval(t);
  });

  $effect(() => {
    refreshKey;
    load();
  });

  function askDelete(s: SessionInfo) {
    confirmId = s.id;
    clearTimeout(confirmTimer);
    confirmTimer = setTimeout(() => (confirmId = null), 2500);
  }

  async function removeSession(s: SessionInfo) {
    confirmId = null;
    try {
      const resp = await send("store", "list", { kind: "message", idPrefix: s.id + ":" });
      for (const item of resp.items ?? []) {
        await send("store", "del", { kind: "message", id: item.id });
      }
      await send("store", "del", { kind: "conversation", id: s.id });
    } catch {
      /* store unreachable — drop the row anyway */
    }
    sessions = sessions.filter((x) => x.id !== s.id);
    onDelete(s.id);
  }

  function startEdit(s: SessionInfo) {
    editingId = s.id;
    editTitle = s.value.title || short(s.id);
  }

  function saveTitle(s: SessionInfo) {
    if (editingId !== s.id) return;
    const title = editTitle.trim();
    editingId = null;
    if (!title || title === (s.value.title || "")) return;
    const value = { ...s.value, title };
    s.value = value;
    send("store", "put", { kind: "conversation", id: s.id, value }).catch(() => {});
  }

  function short(id: string): string {
    return id.startsWith("conv-") ? id.slice(5, 13) : id.slice(0, 8);
  }

  function when(ts: number): string {
    if (!ts) return "";
    return new Date(ts * 1000).toLocaleDateString();
  }
</script>

<nav class="flex-1 overflow-y-auto p-2 flex flex-col gap-0.5">
  {#if sessionId === null}
    <div class="session-item active opacity-70 cursor-default">
      New session
      <span class="block text-[11px] text-ink-400">not started yet</span>
    </div>
  {/if}
  {#each sessions as s (s.id)}
    <div
      class="session-item group"
      class:active={s.id === sessionId}
      onclick={() => selectSession(s.id)}
    >
      {#if editingId === s.id}
        <input
          class="w-full rounded bg-ink-800 border border-accent-dim px-1.5 py-0.5 text-[12px] text-ink-200 outline-none"
          bind:value={editTitle}
          autofocus
          onclick={(e) => e.stopPropagation()}
          onkeydown={(e) => {
            if (e.key === "Enter") saveTitle(s);
            else if (e.key === "Escape") editingId = null;
          }}
          onblur={() => saveTitle(s)}
        />
      {:else}
        <span class="block truncate">{s.value.title || short(s.id)}</span>
        <span class="flex items-center justify-between text-[11px] text-ink-400">
          {when(s.value.createdAt)}
          <span class="flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
            <button
              class="rounded px-1 hover:bg-ink-600 hover:text-ink-200"
              title="Rename"
              onclick={(e) => {
                e.stopPropagation();
                startEdit(s);
              }}
            >
              ✎
            </button>
            <button
              class="rounded px-1 hover:bg-ink-600"
              class:text-danger={confirmId === s.id}
              class:text-ink-400={confirmId !== s.id}
              title={confirmId === s.id ? "Click again to delete" : "Delete session"}
              onclick={(e) => {
                e.stopPropagation();
                if (confirmId === s.id) removeSession(s);
                else askDelete(s);
              }}
            >
              {confirmId === s.id ? "sure?" : "×"}
            </button>
          </span>
        </span>
      {/if}
    </div>
  {/each}
  {#if sessions.length === 0 && sessionId !== null}
    <p class="px-3 py-2 text-[12px] text-ink-400">no sessions yet</p>
  {/if}
</nav>
