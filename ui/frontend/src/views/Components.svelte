<script lang="ts">
  import { onMount } from "svelte";
  import { on, onStatus, send } from "../nats";

  interface HarnessMetadata {
    hidden?: boolean;
    onDemand?: boolean;
  }

  interface ToolSchema {
    description?: string;
    "x-harness"?: HarnessMetadata;
    [key: string]: unknown;
  }

  interface StatusTool {
    name: string;
    schema: ToolSchema;
  }

  interface StatusComp {
    name: string;
    version?: string;
    binary?: string;
    running?: boolean;
    wanted?: boolean;
    policy?: string;
    restarts?: number;
    pid?: number;
    registeredAt?: number;
    tools?: StatusTool[];
    lang?: string;
    src?: string;
    size?: number;
    mtime?: number;
  }

  interface ToolRef {
    component: string;
    name: string;
    schema?: ToolSchema;
  }

  interface ToolExposure {
    version: number;
    direct: ToolRef[];
    discovered: ToolRef[];
  }

  type ExposureState = "direct" | "discovered" | "on-demand" | "hidden" | "unknown";

  let { sessionId }: { sessionId: string | null } = $props();

  let components = $state.raw<Record<string, StatusComp>>({});
  let exposure = $state.raw<ToolExposure | null>(null);
  let exposureSession = $state<string | null>(null);
  let openName = $state<string | null>(null);
  let exposureRequest = 0;

  // Collapse state is sticky: localStorage so the panel stays the way you
  // left it. Default collapsed (the panel should not eat sidebar space).
  let collapsed = $state(localStorage.getItem("niffler-components-collapsed") !== "0");
  // Bumped every 30s so uptime/modified labels stay fresh.
  let tick = $state(0);
  // Reactive clock: re-evaluates whenever tick changes.
  const nowSec = $derived.by(() => {
    tick;
    return Date.now() / 1000;
  });

  // Source of truth lives in core: `core.status` reports the supervisor's
  // live set (authoritative process state) cross-referenced with the catalog
  // and manifest. We just poll it — no local event store to drift or miss
  // registrations, and crashes vanish on the next poll.
  const componentEntries = $derived.by(() =>
    Object.entries(components).sort(([a], [b]) => a.localeCompare(b))
  );

  const directKeys = $derived.by(() => {
    if (exposureSession !== sessionId) return [];
    return (exposure?.direct ?? []).map((tool) => toolKey(tool.component, tool.name));
  });

  const discoveredKeys = $derived.by(() => {
    if (exposureSession !== sessionId) return [];
    return (exposure?.discovered ?? []).map((tool) => toolKey(tool.component, tool.name));
  });

  async function syncStatus() {
    try {
      const resp = await send("core", "status", {});
      const next: Record<string, StatusComp> = {};
      for (const c of resp.components ?? []) {
        if (c?.name) next[c.name] = c;
      }
      components = next;
    } catch {
      // core unreachable — keep whatever we have
    }
  }

  async function syncExposure(id: string | null, reset = false) {
    const request = ++exposureRequest;
    if (reset) {
      exposure = null;
      exposureSession = id;
    }
    if (!id) return;
    try {
      const resp = await send("store", "get", { kind: "session", id: id + ":tools" });
      if (request !== exposureRequest || sessionId !== id) return;
      const value = resp.value;
      exposure = value?.version === 1 && Array.isArray(value.direct)
        ? { version: 1, direct: value.direct, discovered: value.discovered ?? [] }
        : null;
      exposureSession = id;
    } catch {
      if (request === exposureRequest && sessionId === id && reset) exposure = null;
    }
  }

  function toolKey(component: string, tool: string): string {
    return component + "\u0000" + tool;
  }

  function toolState(component: string, tool: StatusTool): ExposureState {
    if (tool.schema?.["x-harness"]?.hidden) return "hidden";
    if (!sessionId || !exposure || exposureSession !== sessionId) return "unknown";
    const key = toolKey(component, tool.name);
    if (directKeys.includes(key)) return "direct";
    if (discoveredKeys.includes(key)) return "discovered";
    return "on-demand";
  }

  function stateLabel(state: ExposureState): string {
    if (state === "discovered") return "seen";
    if (state === "on-demand") return "demand";
    if (state === "hidden") return "internal";
    return state;
  }

  function sortedTools(component: StatusComp): StatusTool[] {
    return [...(component.tools ?? [])].sort((a, b) => a.name.localeCompare(b.name));
  }


  function humanBytes(n?: number): string {
    if (n == null || isNaN(n)) return "?";
    if (n < 1024) return n + " B";
    const units = ["KB", "MB", "GB"];
    let v = n;
    let i = -1;
    do {
      v /= 1024;
      i++;
    } while (v >= 1024 && i < units.length - 1);
    return v.toFixed(1) + " " + units[i];
  }

  function relativeTime(ts?: number): string {
    if (!ts) return "?";
    const s = Math.max(0, Math.round(nowSec - ts));
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.round(s / 60) + "m ago";
    if (s < 86400) return Math.round(s / 3600) + "h ago";
    return Math.round(s / 86400) + "d ago";
  }

  function uptime(ts?: number): string {
    if (!ts) return "?";
    const s = Math.max(0, Math.round(nowSec - ts));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (h > 0) return h + "h " + m + "m";
    if (m > 0) return m + "m " + sec + "s";
    return sec + "s";
  }

  onMount(() => {
    // Source of truth lives in core: `core.status` reports the supervisor's
    // live set (authoritative process state), so we just poll it — no local
    // event store to drift, and dead components vanish on the next poll.
    syncStatus();
    // Refresh the component list every 5s; the 30s tick only bumps the
    // clock so uptime/modified labels stay fresh in between.
    const poll = setInterval(() => {
      syncStatus();
      syncExposure(sessionId);
    }, 5000);
    const t = setInterval(() => tick++, 30000);
    const offCatalog = on("ev.catalog.updated", syncStatus);
    const offSession = on("ev.session.", (event) => {
      const payload = event.payload ?? {};
      if (payload.sessionId !== sessionId) return;
      const kind = event.subject.slice("ev.session.".length);
      if (kind === "toolcall" || kind === "done") syncExposure(sessionId);
    });
    const offStatus = onStatus((online) => {
      if (!online) return;
      syncStatus();
      syncExposure(sessionId);
    });
    return () => {
      clearInterval(poll);
      clearInterval(t);
      offCatalog();
      offSession();
      offStatus();
    };
  });

  $effect(() => {
    syncExposure(sessionId, true);
  });

  function toggleCollapsed(e: Event) {
    collapsed = !(e.currentTarget as HTMLDetailsElement).open;
    localStorage.setItem("niffler-components-collapsed", collapsed ? "1" : "0");
  }
</script>

<details class="border-t border-ink-700 px-3 pt-2 pb-3" open={!collapsed} ontoggle={toggleCollapsed}>
  <summary class="cursor-pointer select-none list-none mb-1 flex items-center justify-between">
    <span class="text-[11px] font-semibold uppercase tracking-wide text-ink-400">
      <span class="text-ink-400">▸</span> Live components
    </span>
    <span class="rounded-full bg-ink-700 px-1.5 text-[10px] font-mono text-ink-300">
      {Object.keys(components).length}
    </span>
  </summary>
  <div class="flex flex-col gap-1">
    {#if sessionId && exposure}
      <div class="mb-1 flex flex-wrap gap-x-2 gap-y-0.5 px-2 text-[9px] uppercase tracking-wide">
        <span class="text-accent">direct</span>
        <span class="text-ok">seen</span>
        <span class="text-warn">demand</span>
        <span class="text-ink-400">internal</span>
      </div>
    {:else}
      <p class="mb-1 px-2 text-[10px] text-ink-400">
        {sessionId ? "tool exposure initializes with the first turn" : "start or select a session to see tool exposure"}
      </p>
    {/if}
    {#if componentEntries.length === 0}
      <p class="text-[11px] text-ink-400">none seen yet</p>
    {:else}
      {#each componentEntries as [name, c] (name)}
        <div>
          <button
            class="flex w-full items-center gap-2 rounded-md px-2 py-1 text-left hover:bg-ink-800"
            onclick={() => (openName = openName === name ? null : name)}
          >
            <span class="h-1.5 w-1.5 shrink-0 rounded-full {c.running === false ? 'bg-red-500' : 'bg-accent'}"></span>
            <span class="min-w-0 flex-1">
              <span class="block truncate font-mono text-[12px] text-ink-200">{c.name}</span>
              <span class="block truncate text-[10px] text-ink-400">
                v{c.version ?? "?"}
                {#if c.pid} · pid {c.pid}{/if}
                {#if (c.tools ?? []).length} · {(c.tools ?? []).length} tools{/if}
              </span>
            </span>
            <span class="text-[10px] text-ink-400">{openName === name ? "▾" : "▸"}</span>
          </button>
          {#if openName === name}
            <div class="mx-2 mb-1.5 rounded-md border border-ink-600 bg-ink-800/50 px-2.5 py-2 text-[11px]">
              {#if (c.tools ?? []).length}
                <div class="text-[10px] uppercase tracking-wide text-ink-400">tools</div>
                <div class="mt-1 flex flex-wrap gap-1">
                  {#each sortedTools(c) as t (t.name)}
                    {@const state = toolState(name, t)}
                    <span
                      class="tool-chip exposure-chip"
                      data-exposure={state}
                      title={(t.schema?.description ?? t.name) + " · " + stateLabel(state)}
                    >
                      {t.name}<span class="exposure-label">{stateLabel(state)}</span>
                    </span>
                  {/each}
                </div>
              {/if}
              <div class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
                {#if c.lang}
                  <span class="text-ink-400">lang</span><span class="truncate font-mono text-ink-300">{c.lang}</span>
                {/if}
                {#if c.src}
                  <span class="text-ink-400">source</span><span class="truncate font-mono text-ink-300" title={c.src}>{c.src}</span>
                {/if}
                {#if c.binary}
                  <span class="text-ink-400">binary</span><span class="truncate font-mono text-ink-300" title={c.binary}>{c.binary}</span>
                {/if}
                {#if c.size != null}
                  <span class="text-ink-400">size</span><span class="font-mono text-ink-300">{humanBytes(c.size)}</span>
                {/if}
                {#if c.mtime != null}
                  <span class="text-ink-400">modified</span><span class="font-mono text-ink-300">{relativeTime(c.mtime)}</span>
                {/if}
                {#if c.pid}
                  <span class="text-ink-400">uptime</span><span class="font-mono text-ink-300">{uptime(c.registeredAt)}</span>
                {/if}
              </div>
            </div>
          {/if}
        </div>
      {/each}
    {/if}
  </div>
</details>
