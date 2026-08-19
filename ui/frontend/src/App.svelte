<script lang="ts">
  import { onMount } from "svelte";
  import Sessions from "./views/Sessions.svelte";
  import Chat from "./views/Chat.svelte";
  import { online, onStatus, isWails, busUrl, on, emit } from "./nats";

  interface ApprovalReq {
    id: string;
    tool: string;
    args: any;
  }

  let connected = $state<boolean | null>(null);
  let url = $state("");
  let sessionId = $state<string | null>(null);
  let refreshKey = $state(0);
  let approvals = $state<ApprovalReq[]>([]);

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

  // Approval gate: core publishes ev.approval.request for tools with
  // x-harness.approval; our answer goes back on ev.approval.reply.
  onMount(() =>
    on("ev.approval.request", (ev) => {
      const p = ev.payload ?? {};
      if (p.id && p.tool) {
        approvals = [...approvals, { id: p.id, tool: p.tool, args: p.args }];
      }
    })
  );

  function prettyArgs(args: any): string {
    const s = JSON.stringify(args ?? {}, null, 2);
    return s.length > 3000 ? s.slice(0, 3000) + "…" : s;
  }

  function answerApproval(ok: boolean) {
    const req = approvals[0];
    if (!req) return;
    emit("ev.approval.reply", { id: req.id, ok });
    approvals = approvals.slice(1);
  }

  function selectSession(id: string) {
    sessionId = id;
  }

  function newSession() {
    sessionId = null;
    refreshKey++;
  }

  function handleDelete(id: string) {
    if (sessionId === id) newSession();
  }

  function short(id: string): string {
    return id.startsWith("conv-") ? id.slice(5, 13) : id.slice(0, 8);
  }
</script>

<div class="flex h-screen">
  <aside class="w-64 shrink-0 border-r border-ink-700 flex flex-col bg-ink-900">
    <div class="px-4 py-3 border-b border-ink-700 flex items-center justify-between">
      <span class="font-semibold text-ink-200">Niffler</span>
      <span
        class="w-2 h-2 rounded-full"
        class:bg-accent={connected === true}
        class:bg-red-500={connected === false}
        class:bg-ink-600={connected === null}
        title={connected === null ? "connecting…" : connected ? "bus connected" : "bus unreachable"}
      ></span>
    </div>
    <Sessions {selectSession} {sessionId} {refreshKey} onDelete={handleDelete} />
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
      {sessionId ? "session " + short(sessionId) : "new session"}
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
    <Chat bind:sessionId={sessionId} />
  </main>
</div>

{#if approvals.length > 0}
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
    <div class="w-[520px] max-w-[92vw] rounded-xl border border-ink-600 bg-ink-900 p-5 shadow-2xl">
      <div class="text-[15px] font-semibold text-ink-200">Approval required</div>
      <div class="mt-1 text-[13px] text-ink-400">
        A tool call with <code class="font-mono text-ink-300">x-harness.approval</code> is
        waiting for your ok:
      </div>
      <div class="mt-3 rounded-lg border border-ink-600 bg-ink-800 p-3">
        <div class="font-mono text-[13px] text-accent">{approvals[0].tool}</div>
        <pre class="mt-2 max-h-52 overflow-y-auto whitespace-pre-wrap font-mono text-[12px] text-ink-300">{prettyArgs(approvals[0].args)}</pre>
      </div>
      {#if approvals.length > 1}
        <div class="mt-2 text-[12px] text-ink-500">+ {approvals.length - 1} more waiting</div>
      {/if}
      <div class="mt-4 flex justify-end gap-2">
        <button
          class="rounded-lg border border-ink-600 px-4 py-1.5 text-[13px] text-ink-300 hover:bg-ink-800"
          onclick={() => answerApproval(false)}
        >
          Deny
        </button>
        <button
          class="rounded-lg bg-accent px-4 py-1.5 text-[13px] font-semibold text-ink-950 hover:opacity-90"
          onclick={() => answerApproval(true)}
        >
          Approve
        </button>
      </div>
    </div>
  </div>
{/if}
