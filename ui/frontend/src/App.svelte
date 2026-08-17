<script lang="ts">
  import { onMount } from "svelte";
  import Sessions from "./views/Sessions.svelte";
  import Chat from "./views/Chat.svelte";
  import { online, onStatus, isWails, busUrl } from "./nats";

  let connected = $state<boolean | null>(null);
  let url = $state("");
  let sessionId = $state<string | null>(null);
  let refreshKey = $state(0);

  onMount(async () => {
    if (!isWails()) {
      connected = false;
      return;
    }
    try {
      url = await busUrl();
      connected = await online();
    } catch {
      connected = false;
    }
    onStatus((onlineNow, urlNow) => {
      connected = onlineNow;
      if (urlNow) url = urlNow;
    });
  });

  function selectSession(id: string) {
    sessionId = id;
  }

  function newSession() {
    sessionId = null;
    refreshKey++;
  }
</script>

<div class="flex h-screen">
  <aside class="w-64 shrink-0 border-r border-ink-700 flex flex-col bg-ink-900">
    <div class="px-4 py-3 border-b border-ink-700 flex items-center justify-between">
      <span class="font-semibold text-ink-200">mini Niffler</span>
      <span
        class="w-2 h-2 rounded-full"
        class:bg-accent={connected === true}
        class:bg-red-500={connected === false}
        class:bg-ink-600={connected === null}
        title={connected === null ? "connecting…" : connected ? "bus connected" : "bus unreachable"}
      ></span>
    </div>
    <Sessions {selectSession} {sessionId} {refreshKey} />
    <div class="p-3 border-t border-ink-700">
      <button
        class="w-full rounded-md bg-accent-dim/15 text-accent px-3 py-2 text-sm font-medium hover:bg-accent-dim/25"
        onclick={newSession}
      >
        + New session
      </button>
    </div>
  </aside>

  <main class="flex-1 flex flex-col min-w-0">
    <header class="px-4 py-2 border-b border-ink-700 text-[13px] text-ink-400">
      {sessionId ?? "new session"}
      {#if url}
        <span class="ml-3 font-mono text-ink-600">{url}</span>
      {/if}
    </header>
    {#if !isWails()}
      <div class="mx-6 mt-4 rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-[13px] text-red-300">
        Running in a browser — the bus bridge only exists inside the desktop
        shell. Launch it with <code class="font-mono">./ui/build/bin/niffler-ui</code>
      </div>
    {:else if connected === false}
      <div class="mx-6 mt-4 rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-[13px] text-red-300">
        bus unreachable at <code class="font-mono">{url || "nats://127.0.0.1:4222"}</code>
        — start the harness and keep its terminal open:
        <code class="font-mono">NATS_URL={url || "nats://127.0.0.1:4222"} ./var/bin/niffler</code>
      </div>
    {/if}
    {#key sessionId}
      <Chat {sessionId} />
    {/key}
  </main>
</div>
