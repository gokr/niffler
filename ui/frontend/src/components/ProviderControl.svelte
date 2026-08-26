<script lang="ts">
  import type { ProviderSummary, ResolvedConfig } from "../lib/providers";
  import { hostname } from "../lib/providers";

  let {
    providers,
    effective,
    onSwitch,
    onManage,
  }: {
    providers: ProviderSummary[];
    effective: ResolvedConfig | null;
    onSwitch: (nickname: string) => void;
    onManage: () => void;
  } = $props();

  let open = $state(false);
  let btnEl: HTMLButtonElement | undefined = $state();

  function toggle() {
    open = !open;
  }

  function pick(nickname: string) {
    open = false;
    onSwitch(nickname);
  }

  function onWindowClick(e: MouseEvent) {
    if (!open) return;
    if (btnEl && !btnEl.contains(e.target as Node)) {
      const pop = btnEl.nextElementSibling;
      if (!pop || !pop.contains(e.target as Node)) open = false;
    }
  }
</script>

<svelte:window onclick={onWindowClick} />

<div class="relative">
  <button
    bind:this={btnEl}
    class="rounded-md border border-ink-600 px-2 py-1 text-[12px] hover:bg-ink-800 flex items-center gap-1.5"
    onclick={toggle}
    title={effective ? `Provider: ${effective.provider} (${effective.providerSource})` : "Provider"}
  >
    {#if effective}
      <span class="text-ink-400">Global:</span>
      <span class="text-ink-200 font-medium">{effective.provider}</span>
    {:else}
      <span class="text-ink-400">no provider</span>
    {/if}
    <span class="text-ink-600 text-[10px]">{open ? "▴" : "▾"}</span>
  </button>

  {#if open}
    <div class="absolute top-full left-0 mt-1 z-40 w-72 rounded-lg border border-ink-600 bg-ink-900 shadow-xl">
      <div class="max-h-80 overflow-y-auto py-1">
        {#if providers.length === 0 && (!effective || effective.providerSource !== "environment")}
          <div class="px-3 py-2 text-[12px] text-ink-400">No providers configured</div>
        {/if}
        {#if effective?.providerSource === "environment" || (providers.length === 0 && effective?.hasKey)}
          <button
            class="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-ink-800 text-[12px]"
            class:text-accent={!providers.some(p => p.active)}
            onclick={() => pick("__env__")}
          >
            <span class="w-4 text-center">{!providers.some(p => p.active) ? "✓" : ""}</span>
            <span class="flex-1">
              <span class="block text-ink-200">Environment</span>
              <span class="block text-[10px] text-ink-400">NIF_OPENAI_*</span>
            </span>
          </button>
        {/if}
        {#each providers as p (p.nickname)}
          <button
            class="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-ink-800 text-[12px]"
            onclick={() => pick(p.nickname)}
          >
            <span class="w-4 text-center">{p.active ? "✓" : ""}</span>
            <span class="flex-1 min-w-0">
              <span class="block text-ink-200 truncate">{p.nickname}</span>
              <span class="block text-[10px] text-ink-400 truncate">
                {hostname(p.baseUrl)}
                {#if !p.hasKey} · <span class="text-warn">no key</span>{/if}
              </span>
            </span>
          </button>
        {/each}
      </div>
      <div class="border-t border-ink-700 px-3 py-2">
        <button
          class="text-[12px] text-accent hover:underline"
          onclick={() => { open = false; onManage(); }}
        >
          Manage providers…
        </button>
      </div>
    </div>
  {/if}
</div>
