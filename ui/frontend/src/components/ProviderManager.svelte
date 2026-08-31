<script lang="ts">
  import { openExternal, send } from "../nats";
  import type { ProviderProtocol, ProviderSummary } from "../lib/providers";
  import { hostname } from "../lib/providers";
  import { t } from "../lib/i18n.svelte";

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
    protocol: ProviderProtocol;
    authType: "api_key" | "oauth";
    baseUrl: string;
    model: string;
    catalog: string;
    context: string;
    stripPrefix: boolean;
    isEdit: boolean;
  }

  interface OAuthLogin {
    flowId: string;
    protocol: "openai-codex" | "anthropic";
    provider: string;
    method: "browser" | "device";
    url: string;
    userCode: string;
    callbackAvailable: boolean;
    retryAfterMs: number;
    manualCode: string;
    manualPending: string;
    status: string;
  }

  let editing = $state<EditForm | null>(null);
  let login = $state<OAuthLogin | null>(null);
  let saving = $state(false);
  let loggingIn = $state(false);
  let error = $state("");
  let confirmRemove = $state<string | null>(null);

  const TEMPLATES: Record<string, { baseUrl: string; catalog: string; protocol: ProviderProtocol }> = {
    deepseek: { baseUrl: "https://api.deepseek.com", catalog: "deepseek", protocol: "openai-chat" },
    openai: { baseUrl: "https://api.openai.com/v1", catalog: "openai", protocol: "openai-chat" },
    anthropic: { baseUrl: "https://api.anthropic.com", catalog: "anthropic", protocol: "anthropic" },
    openrouter: { baseUrl: "https://openrouter.ai/api/v1", catalog: "openrouter", protocol: "openai-chat" },
    custom: { baseUrl: "", catalog: "", protocol: "openai-chat" },
  };

  function startAdd() {
    editing = {
      nickname: "", apiKey: "", protocol: "openai-chat", authType: "api_key",
      baseUrl: "", model: "", catalog: "", context: "", stripPrefix: false, isEdit: false,
    };
    error = "";
  }

  function startEdit(p: ProviderSummary) {
    editing = {
      nickname: p.nickname,
      apiKey: "",
      protocol: p.protocol || "openai-chat",
      authType: p.authType || "api_key",
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
    editing.protocol = t.protocol;
    if (!editing.nickname) editing.nickname = name === "custom" ? "" : name;
  }

  function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function startOAuth(protocol: "openai-codex" | "anthropic", method: "browser" | "device") {
    if (login) await cancelOAuth();
    loggingIn = true;
    error = "";
    try {
      const response = await send("provider", "provider_oauth_start", { protocol, method }, 30000);
      login = {
        flowId: response.flowId,
        protocol,
        provider: response.provider,
        method,
        url: response.url,
        userCode: response.userCode ?? "",
        callbackAvailable: !!response.callbackAvailable,
        retryAfterMs: response.intervalMs ?? 1000,
        manualCode: "",
        manualPending: "",
        status: "Waiting for browser authorization…",
      };
      openExternal(response.url);
      void pollOAuth(response.flowId);
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    } finally {
      loggingIn = false;
    }
  }

  async function pollOAuth(flowId: string) {
    while (login?.flowId === flowId) {
      await sleep(Math.max(500, login.retryAfterMs));
      if (login?.flowId !== flowId) return;
      const code = login.manualPending;
      login.manualPending = "";
      try {
        const response = await send(
          "provider", "provider_oauth_complete",
          code ? { flowId, code } : { flowId },
          30000,
        );
        if (!response.pending) {
          login.status = "Signed in successfully.";
          await sleep(500);
          if (login?.flowId === flowId) login = null;
          onSaved();
          return;
        }
        login.retryAfterMs = response.retryAfterMs ?? 1000;
      } catch (e) {
        if (login?.flowId !== flowId) return;
        login.status = "";
        error = String(e).replace(/^Error:\s*/, "");
        return;
      }
    }
  }

  function submitManualCode() {
    if (!login || !login.manualCode.trim()) return;
    login.manualPending = login.manualCode.trim();
    login.manualCode = "";
    login.retryAfterMs = 0;
    login.status = "Completing authorization…";
  }

  async function cancelOAuth() {
    const flowId = login?.flowId;
    login = null;
    if (!flowId) return;
    try {
      await send("provider", "provider_oauth_cancel", { flowId }, 10000);
    } catch {
      // The flow may already have completed or expired.
    }
  }

  async function save() {
    if (!editing) return;
    saving = true;
    error = "";
    try {
      const args: Record<string, unknown> = {
        nickname: editing.nickname.trim(),
        protocol: editing.protocol,
        baseUrl: editing.baseUrl.trim(),
        model: editing.model.trim(),
        catalog: editing.catalog.trim(),
      };
      const ctx = parseInt(editing.context, 10);
      if (!isNaN(ctx) && ctx > 0) args.context = ctx;
      args.stripPrefix = editing.stripPrefix;
      if (editing.isEdit) {
        if (editing.authType === "api_key" && editing.apiKey.trim()) args.apiKey = editing.apiKey.trim();
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
    void cancelOAuth();
    error = "";
  }
</script>

{#if open}
  <div class="fixed inset-0 z-50 flex justify-end">
    <button class="absolute inset-0 bg-black/50" onclick={close} aria-label="Close"></button>
    <div class="relative w-full max-w-md bg-ink-950 border-l border-ink-700 flex flex-col h-full">
      <div class="flex items-center justify-between px-4 py-3 border-b border-ink-700">
        <span class="text-[14px] font-semibold text-ink-200">{t("pm.title")}</span>
        <button class="text-ink-400 hover:text-ink-200 text-lg" onclick={close}>×</button>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        {#if login}
          <div class="space-y-4">
            <div>
              <div class="text-[14px] font-medium text-ink-200">Sign in to {login.provider}</div>
              <div class="mt-1 text-[12px] text-ink-400">
                Complete authorization in your system browser. Tokens are stored in Niffler's provider store and refreshed automatically.
              </div>
            </div>
            <div class="rounded-lg border border-ink-600 bg-ink-900 p-3">
              <button
                class="break-all text-left font-mono text-[11px] text-accent hover:underline"
                onclick={() => openExternal(login!.url)}
              >{login.url}</button>
              {#if login.userCode}
                <div class="mt-3 text-[11px] text-ink-400">Enter this device code:</div>
                <div class="mt-1 select-all font-mono text-2xl tracking-widest text-ink-100">{login.userCode}</div>
              {/if}
              {#if !login.callbackAvailable && login.method === "browser"}
                <div class="mt-3 text-[11px] text-warn">
                  The local callback port is unavailable. After login, paste the final redirect URL below.
                </div>
              {/if}
            </div>
            <div>
              <label for="pm-oauth-code" class="block text-[11px] text-ink-400 mb-0.5">
                Authorization code or redirect URL (optional)
              </label>
              <div class="flex gap-2">
                <input
                  id="pm-oauth-code"
                  class="min-w-0 flex-1 rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={login.manualCode}
                  placeholder="http://localhost/…?code=…"
                  onkeydown={(event) => { if (event.key === "Enter") submitManualCode(); }}
                />
                <button
                  class="rounded-md border border-ink-600 px-3 py-1.5 text-[12px] text-accent hover:bg-ink-800 disabled:opacity-40"
                  disabled={!login.manualCode.trim()}
                  onclick={submitManualCode}
                >Submit</button>
              </div>
            </div>
            {#if login.status}
              <div class="text-[12px] text-ink-300">{login.status}</div>
            {/if}
            {#if error}
              <div class="text-[12px] text-danger">{error}</div>
            {/if}
            <button
              class="rounded-lg border border-ink-600 px-4 py-1.5 text-[13px] text-ink-300 hover:bg-ink-800"
              onclick={() => void cancelOAuth()}
            >Cancel</button>
          </div>
        {:else if editing}
          <div class="space-y-3">
            <div class="text-[13px] font-medium text-ink-200">
              {editing.isEdit ? t("pm.editProvider") : t("pm.addProvider")}
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
              <label for="pm-protocol" class="block text-[11px] text-ink-400 mb-0.5">API protocol</label>
              <select
                id="pm-protocol"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                bind:value={editing.protocol}
                disabled={editing.authType === "oauth"}
              >
                <option value="openai-chat">OpenAI-compatible Chat Completions</option>
                <option value="anthropic">Anthropic Messages</option>
              </select>
            </div>
            {#if editing.authType === "oauth"}
              <div class="rounded-md border border-ink-600 bg-ink-900 px-3 py-2 text-[12px] text-ink-400">
                OAuth credential · use Sign in again to replace or refresh it.
              </div>
            {:else}
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
            {/if}
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
                {saving ? t("pm.saving") : t("pm.save")}
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
            <div class="rounded-lg border border-ink-600 bg-ink-900 p-3">
              <div class="text-[12px] font-medium text-ink-200">Subscription login</div>
              <div class="mt-1 text-[11px] text-ink-400">Use your existing ChatGPT Plus/Pro or Claude Pro/Max subscription.</div>
              <div class="mt-2 grid grid-cols-2 gap-2">
                <button
                  class="rounded-md border border-ink-600 px-2 py-2 text-[11px] text-accent hover:bg-ink-800 disabled:opacity-40"
                  disabled={loggingIn}
                  onclick={() => startOAuth("openai-codex", "browser")}
                >OpenAI · browser</button>
                <button
                  class="rounded-md border border-ink-600 px-2 py-2 text-[11px] text-accent hover:bg-ink-800 disabled:opacity-40"
                  disabled={loggingIn}
                  onclick={() => startOAuth("openai-codex", "device")}
                >OpenAI · device code</button>
                <button
                  class="col-span-2 rounded-md border border-ink-600 px-2 py-2 text-[11px] text-accent hover:bg-ink-800 disabled:opacity-40"
                  disabled={loggingIn}
                  onclick={() => startOAuth("anthropic", "browser")}
                >Anthropic · browser</button>
              </div>
            </div>
            {#each providers as p (p.nickname)}
              <div class="rounded-lg border border-ink-600 bg-ink-900 px-3 py-2.5">
                <div class="flex items-center justify-between">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-1.5">
                      <span class="text-[13px] font-medium text-ink-200">{p.nickname}</span>
                      {#if p.active}
                        <span class="rounded-full bg-accent-dim/20 px-1.5 py-0.5 text-[10px] text-accent">{t("pm.active")}</span>
                      {/if}
                      {#if p.authType === "oauth"}
                        <span class="rounded-full bg-accent-dim/20 px-1.5 py-0.5 text-[10px] text-accent">OAuth</span>
                      {:else if !p.hasKey}
                        <span class="rounded-full bg-warn/20 px-1.5 py-0.5 text-[10px] text-warn">{t("pm.noKey")}</span>
                      {/if}
                    </div>
                    <div class="mt-0.5 text-[11px] text-ink-400 truncate font-mono">
                      {hostname(p.baseUrl)} · {p.protocol || "openai-chat"} · {p.model || "no model"}
                      {#if p.context > 0} · ctx {p.context.toLocaleString()}{/if}
                    </div>
                  </div>
                  <div class="flex gap-1 shrink-0 ml-2">
                    <button
                      class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-300 hover:bg-ink-800"
                      onclick={() => startEdit(p)}
                    >{t("pm.edit")}</button>
                    {#if confirmRemove === p.nickname}
                      <button
                        class="rounded-md border border-danger/50 px-2 py-1 text-[11px] text-danger hover:bg-danger/10"
                        onclick={() => remove(p.nickname)}
                      >{t("pm.sure")}</button>
                    {:else}
                      <button
                        class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-400 hover:bg-ink-800"
                        onclick={() => { confirmRemove = p.nickname; setTimeout(() => { if (confirmRemove === p.nickname) confirmRemove = null; }, 2500); }}
                      >{t("pm.remove")}</button>
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
