<script lang="ts">
  import { send } from "../nats";
  import type { ProviderSummary } from "../lib/providers";
  import { hostname } from "../lib/providers";

  let {
    open = $bindable(false),
    providers,
    onSaved,
  }: {
    open?: boolean;
    providers: ProviderSummary[];
    onSaved: () => void;
  } = $props();

  interface EditForm {
    nickname: string;
    apiKey: string;
    baseUrl: string;
    model: string;
    catalog: string;
    context: string;
    stripPrefix: boolean;
    isEdit: boolean;
  }

  let editing = $state<EditForm | null>(null);
  let saving = $state(false);
  let error = $state("");
  let confirmRemove = $state<string | null>(null);

  const TEMPLATES: Record<string, { baseUrl: string; catalog: string }> = {
    deepseek: { baseUrl: "https://api.deepseek.com", catalog: "deepseek" },
    openai: { baseUrl: "https://api.openai.com/v1", catalog: "openai" },
    openrouter: { baseUrl: "https://openrouter.ai/api/v1", catalog: "openrouter" },
    custom: { baseUrl: "", catalog: "" },
  };

  function startAdd() {
    editing = { nickname: "", apiKey: "", baseUrl: "", model: "", catalog: "", context: "", stripPrefix: false, isEdit: false };
    error = "";
  }

  function startEdit(p: ProviderSummary) {
    editing = {
      nickname: p.nickname,
      apiKey: "",
      baseUrl: p.baseUrl,
      model: p.model,
      catalog: p.catalog,
      context: p.context > 0 ? String(p.context) : "",
      stripPrefix: !!p.stripPrefix,
      isEdit: true,
    };
    error = "";
  }

  function applyTemplate(name: string) {
    const t = TEMPLATES[name];
    if (!t || !editing) return;
    if (!editing.baseUrl) editing.baseUrl = t.baseUrl;
    if (!editing.catalog) editing.catalog = t.catalog;
    if (!editing.nickname) editing.nickname = name === "custom" ? "" : name;
  }

  async function save() {
    if (!editing) return;
    saving = true;
    error = "";
    try {
      const args: Record<string, unknown> = {
        nickname: editing.nickname.trim(),
        baseUrl: editing.baseUrl.trim(),
        model: editing.model.trim(),
        catalog: editing.catalog.trim(),
      };
      const ctx = parseInt(editing.context, 10);
      if (!isNaN(ctx) && ctx > 0) args.context = ctx;
      args.stripPrefix = editing.stripPrefix;
      if (editing.isEdit) {
        if (editing.apiKey.trim()) args.apiKey = editing.apiKey.trim();
        await send("provider", "provider_update", args, 30000);
      } else {
        args.apiKey = editing.apiKey.trim();
        await send("provider", "provider_add", args, 30000);
      }
      editing = null;
      onSaved();
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    } finally {
      saving = false;
    }
  }

  async function remove(nickname: string) {
    confirmRemove = null;
    try {
      await send("provider", "provider_remove", { nickname }, 30000);
      onSaved();
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    }
  }

  function close() {
    open = false;
    editing = null;
    error = "";
  }
</script>

{#if open}
  <div class="fixed inset-0 z-50 flex justify-end">
    <button class="absolute inset-0 bg-black/50" onclick={close} aria-label="Close"></button>
    <div class="relative w-full max-w-md bg-ink-950 border-l border-ink-700 flex flex-col h-full">
      <div class="flex items-center justify-between px-4 py-3 border-b border-ink-700">
        <span class="text-[14px] font-semibold text-ink-200">Providers</span>
        <button class="text-ink-400 hover:text-ink-200 text-lg" onclick={close}>×</button>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        {#if editing}
          <div class="space-y-3">
            <div class="text-[13px] font-medium text-ink-200">
              {editing.isEdit ? "Edit" : "Add"} provider
            </div>
            {#if !editing.isEdit}
              <div class="flex flex-wrap gap-1.5">
                {#each Object.keys(TEMPLATES) as t (t)}
                  <button
                    class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-300 hover:bg-ink-800"
                    onclick={() => applyTemplate(t)}
                  >
                    {t}
                  </button>
                {/each}
              </div>
            {/if}
            <div>
              <label for="pm-nick" class="block text-[11px] text-ink-400 mb-0.5">Nickname</label>
              <input
                id="pm-nick"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                bind:value={editing.nickname}
                disabled={editing.isEdit}
                placeholder="e.g. deepseek"
              />
            </div>
            <div>
              <label for="pm-key" class="block text-[11px] text-ink-400 mb-0.5">API key {editing.isEdit ? "(leave blank to keep)" : ""}</label>
              <input
                id="pm-key"
                type="password"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                bind:value={editing.apiKey}
                placeholder={editing.isEdit ? "••••••" : "sk-…"}
                autocomplete="off"
              />
            </div>
            <div>
              <label for="pm-url" class="block text-[11px] text-ink-400 mb-0.5">Base URL</label>
              <input
                id="pm-url"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                bind:value={editing.baseUrl}
                placeholder="https://api.example.com/v1"
              />
            </div>
            <div>
              <label for="pm-model" class="block text-[11px] text-ink-400 mb-0.5">Default model</label>
              <input
                id="pm-model"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                bind:value={editing.model}
                placeholder="e.g. deepseek-chat"
              />
            </div>
            <div class="grid grid-cols-2 gap-2">
              <div>
                <label for="pm-catalog" class="block text-[11px] text-ink-400 mb-0.5">Catalog ID</label>
                <input
                  id="pm-catalog"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.catalog}
                  placeholder="models.dev provider id"
                />
              </div>
              <div>
                <label for="pm-context" class="block text-[11px] text-ink-400 mb-0.5">Context (tokens)</label>
                <input
                  id="pm-context"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.context}
                  placeholder="auto"
                />
              </div>
              <label class="flex items-center gap-2 text-[12px] text-ink-300">
                <input type="checkbox" class="accent-accent" bind:checked={editing.stripPrefix} />
                Strip vendor/ prefix from model ids
                <span class="text-ink-500" title="For gateways that route on the canonical id (e.g. devpass): send glm-5.2 instead of alibaba/glm-5.2">(?)</span>
              </label>
            </div>
            {#if error}
              <div class="text-[12px] text-danger">{error}</div>
            {/if}
            <div class="flex gap-2 pt-1">
              <button
                class="rounded-lg bg-accent px-4 py-1.5 text-[13px] font-semibold text-ink-950 hover:opacity-90 disabled:opacity-40"
                onclick={save}
                disabled={saving || (!editing.isEdit && (!editing.nickname.trim() || !editing.apiKey.trim()))}
              >
                {saving ? "Saving…" : "Save"}
              </button>
              <button
                class="rounded-lg border border-ink-600 px-4 py-1.5 text-[13px] text-ink-300 hover:bg-ink-800"
                onclick={() => { editing = null; error = ""; }}
              >
                Cancel
              </button>
            </div>
          </div>
        {:else}
          <div class="space-y-2">
            {#each providers as p (p.nickname)}
              <div class="rounded-lg border border-ink-600 bg-ink-900 px-3 py-2.5">
                <div class="flex items-center justify-between">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-1.5">
                      <span class="text-[13px] font-medium text-ink-200">{p.nickname}</span>
                      {#if p.active}
                        <span class="rounded-full bg-accent-dim/20 px-1.5 py-0.5 text-[10px] text-accent">active</span>
                      {/if}
                      {#if !p.hasKey}
                        <span class="rounded-full bg-warn/20 px-1.5 py-0.5 text-[10px] text-warn">no key</span>
                      {/if}
                    </div>
                    <div class="mt-0.5 text-[11px] text-ink-400 truncate font-mono">
                      {hostname(p.baseUrl)} · {p.model || "no model"}
                      {#if p.context > 0} · ctx {p.context.toLocaleString()}{/if}
                    </div>
                  </div>
                  <div class="flex gap-1 shrink-0 ml-2">
                    <button
                      class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-300 hover:bg-ink-800"
                      onclick={() => startEdit(p)}
                    >Edit</button>
                    {#if confirmRemove === p.nickname}
                      <button
                        class="rounded-md border border-danger/50 px-2 py-1 text-[11px] text-danger hover:bg-danger/10"
                        onclick={() => remove(p.nickname)}
                      >Sure?</button>
                    {:else}
                      <button
                        class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-400 hover:bg-ink-800"
                        onclick={() => { confirmRemove = p.nickname; setTimeout(() => { if (confirmRemove === p.nickname) confirmRemove = null; }, 2500); }}
                      >Remove</button>
                    {/if}
                  </div>
                </div>
              </div>
            {/each}
            {#if providers.length === 0}
              <div class="text-[12px] text-ink-400 py-4 text-center">No providers configured yet</div>
            {/if}
            {#if error}
              <div class="text-[12px] text-danger">{error}</div>
            {/if}
            <button
              class="w-full rounded-lg border border-ink-600 px-3 py-2 text-[13px] text-accent hover:bg-ink-800"
              onclick={startAdd}
            >
              + Add provider
            </button>
          </div>
        {/if}
      </div>
    </div>
  </div>
{/if}
