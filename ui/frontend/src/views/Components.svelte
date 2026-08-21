<script lang="ts">
  import { onMount } from "svelte";
  import { send } from "../nats";

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
    tools?: { name: string }[];
    lang?: string;
    src?: string;
    size?: number;
    mtime?: number;
  }

  let components = $state<Record<string, StatusComp>>({});
  let openName = $state<string | null>(null);

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
  async function sync() {
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
    sync();
    // Refresh the component list every 5s; the 30s tick only bumps the
    // clock so uptime/modified labels stay fresh in between.
    const poll = setInterval(sync, 5000);
    const t = setInterval(() => tick++, 30000);
    return () => {
      clearInterval(poll);
      clearInterval(t);
    };
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
    {#if Object.keys(components).length === 0}
      <p class="text-[11px] text-ink-400">none seen yet</p>
    {:else}
      {#each Object.entries(components) as [name, c]}
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
                  {#each c.tools ?? [] as t}
                    <span class="tool-chip">{t.name}</span>
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
