<script lang="ts">
  import { onMount } from "svelte";
  import { send } from "../nats";

  interface SessionInfo {
    id: string;
    rev: number;
    value: { createdAt: number; model?: string; title?: string };
  }

  let { selectSession, sessionId, refreshKey = $bindable(0) } = $props<{
    selectSession: (id: string) => void;
    sessionId: string | null;
    refreshKey?: number;
  }>();

  let sessions = $state<SessionInfo[]>([]);

  async function load() {
    try {
      const resp = await send("store", "list", { kind: "conversation" });
      sessions = resp.items ?? [];
    } catch {
      sessions = [];
    }
  }

  onMount(load);

  $effect(() => {
    refreshKey;
    load();
  });

  function short(id: string): string {
    return id.startsWith("conv-") ? id.slice(5, 13) : id.slice(0, 8);
  }

  function when(ts: number): string {
    if (!ts) return "";
    return new Date(ts * 1000).toLocaleDateString();
  }
</script>

<nav class="flex-1 overflow-y-auto p-2 flex flex-col gap-0.5">
  {#each sessions as s (s.id)}
    <button class="session-item" class:active={s.id === sessionId} onclick={() => selectSession(s.id)}>
      {s.value.title || short(s.id)}
      <span class="block text-[11px] text-ink-400">{when(s.value.createdAt)}</span>
    </button>
  {/each}
  {#if sessions.length === 0}
    <p class="px-3 py-2 text-[12px] text-ink-400">no sessions yet</p>
  {/if}
</nav>
