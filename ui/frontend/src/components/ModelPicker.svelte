<script lang="ts">
  import { send } from "../nats";
  import type { CatalogModel } from "../lib/providers";
  import { fmtContext } from "../lib/providers";
  import { t } from "../lib/i18n.svelte";

  let {
    open = $bindable(false),
    catalog,
    currentModel,
    onSelect,
  }: {
    open?: boolean;
    catalog: string;
    currentModel: string;
    onSelect: (model: string) => void;
  } = $props();

  let query = $state("");
  let models = $state<CatalogModel[]>([]);
  let total = $state(0);
  let loading = $state(false);
  let customId = $state("");
  let showCustom = $state(false);
  let searchEl: HTMLInputElement | undefined = $state();

  async function search() {
    loading = true;
    try {
      const args: Record<string, unknown> = { limit: 100 };
      if (catalog) args.provider = catalog;
      const q = query.trim();
      if (q) args.query = q;
      const resp = await send("models", "models_list", args, 10000);
      models = (resp.models ?? []) as CatalogModel[];
      total = resp.total ?? 0;
    } catch {
      models = [];
      total = 0;
    } finally {
      loading = false;
    }
  }

  let prevOpen = false;
  $effect(() => {
    if (open && !prevOpen) {
      query = "";
      customId = "";
      showCustom = false;
      search();
      requestAnimationFrame(() => searchEl?.focus());
    }
    prevOpen = open;
  });

  function pick(model: string) {
    open = false;
    onSelect(model);
  }

  function clearOverride() {
    open = false;
    onSelect("");
  }

  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape") open = false;
  }
</script>

{#if open}
  <div class="fixed inset-0 z-50 bg-black/50" onclick={() => (open = false)} onkeydown={onKey} role="presentation">
    <div class="flex items-start justify-center pt-[8vh] h-full" onclick={(e) => e.stopPropagation()} onkeydown={onKey} role="dialog" aria-modal="true" tabindex="-1">
    <div class="w-full max-w-lg mx-4 rounded-xl border border-ink-600 bg-ink-900 shadow-2xl">
      <div class="flex items-center gap-2 px-4 py-3 border-b border-ink-700">
        <input
          bind:this={searchEl}
          class="flex-1 rounded-md bg-ink-800 border border-ink-600 px-3 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
          placeholder={t("model.search")}
          bind:value={query}
          oninput={() => search()}
        />
        <button class="text-ink-400 hover:text-ink-200 text-lg" onclick={() => (open = false)}>×</button>
      </div>

      <div class="max-h-[50vh] overflow-y-auto">
        {#if currentModel}
          <button
            class="w-full flex items-center gap-2 px-4 py-2 text-left hover:bg-ink-800 border-b border-ink-700/50"
            onclick={clearOverride}
          >
            <span class="text-[12px] text-ink-400">✓</span>
            <span class="text-[13px] text-ink-400">{t("model.useDefault")}</span>
            <span class="ml-auto text-[10px] text-ink-600">{t("model.clearsOverride")}</span>
          </button>
        {/if}

        {#if loading}
          <div class="px-4 py-6 text-center text-[13px] text-ink-400">{t("model.searching")}</div>
        {:else if models.length === 0}
          <div class="px-4 py-6 text-center text-[13px] text-ink-400">
            {catalog ? t("model.noneFoundFor", { catalog }) : t("model.noneFound")}
          </div>
        {:else}
          {#each models as m (m.reference)}
            <button
              class="w-full flex items-center gap-2 px-4 py-2 text-left hover:bg-ink-800 {currentModel === m.id ? 'bg-accent-dim/10' : ''}"
              onclick={() => pick(m.id)}
            >
              <span class="w-4 text-center text-[12px]">{currentModel === m.id ? "✓" : ""}</span>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-1.5">
                  <span class="text-[13px] text-ink-200 truncate">{m.name || m.id}</span>
                  {#if m.reasoning}
                    <span class="rounded bg-accent-dim/15 px-1 text-[9px] text-accent">{t("model.reason")}</span>
                  {/if}
                  {#if m.tool_call !== false}
                    <span class="rounded bg-ink-700 px-1 text-[9px] text-ink-400">{t("model.tools")}</span>
                  {/if}
                </div>
                <div class="text-[10px] text-ink-400 font-mono truncate">{m.id}</div>
              </div>
              <span class="shrink-0 text-[10px] text-ink-400 font-mono">
                {#if m.limit?.context}{fmtContext(m.limit.context)}{/if}
              </span>
            </button>
          {/each}
          {#if total > models.length}
            <div class="px-4 py-2 text-[11px] text-ink-400 text-center border-t border-ink-700/50">
              {t("model.showing", { n: String(models.length), total: String(total) })}
            </div>
          {/if}
        {/if}
      </div>

      <div class="border-t border-ink-700 px-4 py-2.5">
        {#if showCustom}
          <div class="flex gap-2">
            <input
              class="flex-1 rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
              placeholder={t("model.customId")}
              bind:value={customId}
              onkeydown={(e) => { if (e.key === "Enter" && customId.trim()) pick(customId.trim()); }}
            />
            <button
              class="rounded-md bg-accent px-3 py-1.5 text-[12px] font-semibold text-ink-950 hover:opacity-90"
              onclick={() => { if (customId.trim()) pick(customId.trim()); }}
            >{t("model.set")}</button>
          </div>
        {:else}
          <button
            class="text-[12px] text-ink-400 hover:text-accent"
            onclick={() => (showCustom = true)}
          >
            Use custom model id…
          </button>
        {/if}
      </div>
    </div>
    </div>
  </div>
{/if}
