<script lang="ts">
  import { send } from "../nats";
  import { t } from "../lib/i18n.svelte";

  // Self-contained slide-over panel for the mcp component's server manager
  // (mcp_servers / mcp_add / mcp_edit / mcp_remove / mcp_refresh). Loads its
  // own list when opened; env/header values are redacted server-side — only
  // keys and counts are shown.
  let {
    open = $bindable(false),
    onSaved,
  }: {
    open?: boolean;
    onSaved?: () => void;
  } = $props();

  interface McpServer {
    name: string;
    type?: "stdio" | "http" | "sse" | "";
    enabled: boolean;
    toolCount: number;
    command?: string;
    args?: string[];
    envKeys?: string[];
    url?: string;
    headerKeys?: string[];
    component?: string;
    live?: boolean;
    registeredTools?: string[];
    approval?: string;
    expose?: string;
    timeoutMs?: number;
    bridge?: Record<string, unknown>;
    error?: string;
  }

  interface EditForm {
    name: string;
    type: "stdio" | "http" | "sse";
    command: string;
    args: string; // one argument per line
    env: string; // KEY=VALUE per line
    cwd: string;
    url: string;
    headers: string; // KEY=VALUE per line
    approval: "" | "always";
    expose: "ondemand" | "direct";
    effect: "read" | "write";
    concurrency: "parallel" | "serial";
    timeoutMs: string;
    idleMs: string;
    enabled: boolean;
    isEdit: boolean;
  }

  let servers = $state<McpServer[]>([]);
  let loading = $state(false);
  let editing = $state<EditForm | null>(null);
  let saving = $state(false);
  let refreshing = $state("");
  let error = $state("");
  let confirmRemove = $state<string | null>(null);

  async function load() {
    loading = true;
    try {
      const resp = await send("mcp", "mcp_servers", {}, 15000);
      servers = (resp.servers ?? []) as McpServer[];
      error = "";
    } catch (e) {
      servers = [];
      error = String(e).replace(/^Error:\s*/, "");
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    if (open && !editing) void load();
  });

  function startAdd() {
    editing = {
      name: "", type: "stdio", command: "", args: "", env: "", cwd: "",
      url: "", headers: "", approval: "", expose: "ondemand", effect: "write",
      concurrency: "parallel", timeoutMs: "", idleMs: "", enabled: true, isEdit: false,
    };
    error = "";
  }

  function startEdit(s: McpServer) {
    editing = {
      name: s.name,
      type: (s.type as EditForm["type"]) || "stdio",
      command: s.command ?? "",
      args: (s.args ?? []).join("\n"),
      env: "", // values are never echoed; leave blank to keep
      cwd: "",
      url: s.url ?? "",
      headers: "", // values are never echoed; leave blank to keep
      approval: (s.approval as EditForm["approval"]) || "",
      expose: (s.expose as EditForm["expose"]) || "ondemand",
      effect: (s.effect as EditForm["effect"]) || "write",
      concurrency: (s.concurrency as EditForm["concurrency"]) || "parallel",
      timeoutMs: s.timeoutMs ? String(s.timeoutMs) : "",
      idleMs: "",
      enabled: s.enabled,
      isEdit: true,
    };
    error = "";
  }

  function lines(text: string): string[] {
    return text
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0);
  }

  function parseKv(text: string): Record<string, string> | undefined {
    const out: Record<string, string> = {};
    for (const line of lines(text)) {
      const eq = line.indexOf("=");
      const colon = line.indexOf(":");
      const sep = eq >= 0 && (colon < 0 || eq < colon) ? eq : colon;
      if (sep <= 0) return undefined; // malformed entry -> signal skip
      out[line.slice(0, sep).trim()] = line.slice(sep + 1).trim();
    }
    return Object.keys(out).length > 0 ? out : undefined;
  }

  async function save() {
    if (!editing) return;
    saving = true;
    error = "";
    try {
      const args: Record<string, unknown> = {
        name: editing.name.trim(),
        type: editing.type,
        approval: editing.approval,
        expose: editing.expose,
        effect: editing.effect,
        concurrency: editing.concurrency,
        enabled: editing.enabled,
      };
      if (editing.type === "stdio") {
        args.command = editing.command.trim();
        const argv = lines(editing.args);
        if (argv.length > 0) args.args = argv;
        const env = parseKv(editing.env);
        if (env) args.env = env;
        if (editing.cwd.trim()) args.cwd = editing.cwd.trim();
      } else {
        args.url = editing.url.trim();
        const headers = parseKv(editing.headers);
        if (headers) args.headers = headers;
      }
      const ms = parseInt(editing.timeoutMs, 10);
      if (!isNaN(ms) && ms > 0) args.timeoutMs = ms;
      if (editing.isEdit) {
        await send("mcp", "mcp_edit", args, 120000);
      } else {
        await send("mcp", "mcp_add", args, 120000);
      }
      editing = null;
      await load();
      onSaved?.();
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    } finally {
      saving = false;
    }
  }

  async function remove(name: string) {
    confirmRemove = null;
    try {
      await send("mcp", "mcp_remove", { name }, 30000);
      await load();
      onSaved?.();
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    }
  }

  async function refresh(name: string) {
    refreshing = name;
    try {
      await send("mcp", "mcp_refresh", { name }, 90000);
      await load();
    } catch (e) {
      error = String(e).replace(/^Error:\s*/, "");
    } finally {
      refreshing = "";
    }
  }

  function close() {
    open = false;
    editing = null;
    error = "";
  }

  function transportLabel(s: McpServer): string {
    if (s.type === "http" || s.type === "sse") return s.url ?? "";
    return [s.command, ...(s.args ?? [])].join(" ");
  }

  function secretLabel(s: McpServer): string {
    const keys = s.type === "http" || s.type === "sse" ? s.headerKeys : s.envKeys;
    if (!keys || keys.length === 0) return "";
    return `${keys.length} secret key${keys.length === 1 ? "" : "s"}: ${keys.join(", ")}`;
  }
</script>

{#if open}
  <div class="fixed inset-0 z-50 flex justify-end">
    <button class="absolute inset-0 bg-black/50" onclick={close} aria-label="Close"></button>
    <div class="relative w-full max-w-md bg-ink-950 border-l border-ink-700 flex flex-col h-full">
      <div class="flex items-center justify-between px-4 py-3 border-b border-ink-700">
        <span class="text-[14px] font-semibold text-ink-200">{t("mcp.title")}</span>
        <button class="text-ink-400 hover:text-ink-200 text-lg" onclick={close}>×</button>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        {#if editing}
          <div class="space-y-3">
            <div class="text-[13px] font-medium text-ink-200">
              {editing.isEdit ? t("mcp.editServer") : t("mcp.addServer")}
            </div>
            <div>
              <label for="mcp-name" class="block text-[11px] text-ink-400 mb-0.5">Name</label>
              <input
                id="mcp-name"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                bind:value={editing.name}
                disabled={editing.isEdit}
                placeholder="e.g. github"
              />
            </div>
            <div>
              <label for="mcp-type" class="block text-[11px] text-ink-400 mb-0.5">Transport</label>
              <select
                id="mcp-type"
                class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                bind:value={editing.type}
              >
                <option value="stdio">stdio (local command)</option>
                <option value="http">http (streamable endpoint)</option>
                <option value="sse">sse (event endpoint)</option>
              </select>
            </div>
            {#if editing.type === "stdio"}
              <div>
                <label for="mcp-command" class="block text-[11px] text-ink-400 mb-0.5">Command</label>
                <input
                  id="mcp-command"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.command}
                  placeholder="npx / uvx / /path/to/server"
                />
              </div>
              <div>
                <label for="mcp-args" class="block text-[11px] text-ink-400 mb-0.5">Arguments (one per line)</label>
                <textarea
                  id="mcp-args"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  rows="3"
                  bind:value={editing.args}
                  placeholder={"-y\n@modelcontextprotocol/server-github"}
                ></textarea>
              </div>
              <div>
                <label for="mcp-env" class="block text-[11px] text-ink-400 mb-0.5">
                  Env {editing.isEdit ? t("mcp.keepBlank") : ""} (KEY=VALUE per line)
                </label>
                <textarea
                  id="mcp-env"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  rows="2"
                  bind:value={editing.env}
                  placeholder="GITHUB_TOKEN=…"
                ></textarea>
              </div>
              <div>
                <label for="mcp-cwd" class="block text-[11px] text-ink-400 mb-0.5">Working directory (optional)</label>
                <input
                  id="mcp-cwd"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.cwd}
                />
              </div>
            {:else}
              <div>
                <label for="mcp-url" class="block text-[11px] text-ink-400 mb-0.5">Endpoint URL</label>
                <input
                  id="mcp-url"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.url}
                  placeholder="https://example.com/mcp"
                />
              </div>
              <div>
                <label for="mcp-headers" class="block text-[11px] text-ink-400 mb-0.5">
                  Headers {editing.isEdit ? t("mcp.keepBlank") : ""} (KEY=VALUE per line)
                </label>
                <textarea
                  id="mcp-headers"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  rows="2"
                  bind:value={editing.headers}
                  placeholder="Authorization=Bearer …"
                ></textarea>
              </div>
            {/if}
            <div class="grid grid-cols-2 gap-2">
              <div>
                <label for="mcp-expose" class="block text-[11px] text-ink-400 mb-0.5">Exposure</label>
                <select
                  id="mcp-expose"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                  bind:value={editing.expose}
                >
                  <option value="ondemand">on-demand (discover + invoke)</option>
                  <option value="direct">direct (in every conversation)</option>
                </select>
              </div>
              <div>
                <label for="mcp-effect" class="block text-[11px] text-ink-400 mb-0.5">Effect hint</label>
                <select
                  id="mcp-effect"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                  bind:value={editing.effect}
                >
                  <option value="write">write</option>
                  <option value="read">read</option>
                </select>
              </div>
              <div>
                <label for="mcp-approval" class="block text-[11px] text-ink-400 mb-0.5">Approval</label>
                <select
                  id="mcp-approval"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                  bind:value={editing.approval}
                >
                  <option value="">none</option>
                  <option value="always">always ask</option>
                </select>
              </div>
              <div>
                <label for="mcp-concurrency" class="block text-[11px] text-ink-400 mb-0.5">Concurrency</label>
                <select
                  id="mcp-concurrency"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[13px] text-ink-200 outline-none focus:border-accent-dim"
                  bind:value={editing.concurrency}
                >
                  <option value="parallel">parallel</option>
                  <option value="serial">serial</option>
                </select>
              </div>
              <div>
                <label for="mcp-timeout" class="block text-[11px] text-ink-400 mb-0.5">Timeout (ms)</label>
                <input
                  id="mcp-timeout"
                  class="w-full rounded-md bg-ink-800 border border-ink-600 px-2.5 py-1.5 text-[12px] text-ink-200 outline-none focus:border-accent-dim font-mono"
                  bind:value={editing.timeoutMs}
                  placeholder="0"
                />
              </div>
              <label class="flex items-center gap-2 text-[12px] text-ink-300 self-end pb-1.5">
                <input type="checkbox" class="accent-accent" bind:checked={editing.enabled} />
                {editing.isEdit ? t("mcp.enabled") : t("mcp.validateNow")}
              </label>
            </div>
            {#if error}
              <div class="text-[12px] text-danger">{error}</div>
            {/if}
            <div class="flex gap-2 pt-1">
              <button
                class="rounded-lg bg-accent px-4 py-1.5 text-[13px] font-semibold text-ink-950 hover:opacity-90 disabled:opacity-40"
                onclick={save}
                disabled={saving
                  || !editing.name.trim()
                  || (editing.type === "stdio" ? !editing.command.trim() : !editing.url.trim())}
              >
                {saving ? t("mcp.saving") : t("mcp.save")}
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
            {#each servers as s (s.name)}
              <div class="rounded-lg border border-ink-600 bg-ink-900 px-3 py-2.5">
                <div class="flex items-center justify-between gap-2">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-1.5 flex-wrap">
                      <span class="text-[13px] font-medium text-ink-200">{s.name}</span>
                      {#if s.enabled}
                        {#if s.live}
                          <span class="rounded-full bg-accent-dim/20 px-1.5 py-0.5 text-[10px] text-accent">{t("mcp.live")}</span>
                        {:else}
                          <span class="rounded-full bg-warn/20 px-1.5 py-0.5 text-[10px] text-warn">{t("mcp.notRunning")}</span>
                        {/if}
                      {:else}
                        <span class="rounded-full bg-ink-700 px-1.5 py-0.5 text-[10px] text-ink-400">{t("mcp.disabled")}</span>
                      {/if}
                      {#if s.expose === "direct"}
                        <span class="rounded-full bg-accent-dim/20 px-1.5 py-0.5 text-[10px] text-accent">direct</span>
                      {/if}
                      {#if s.approval === "always"}
                        <span class="rounded-full bg-warn/20 px-1.5 py-0.5 text-[10px] text-warn">approval</span>
                      {/if}
                    </div>
                    <div class="mt-0.5 text-[11px] text-ink-400 truncate font-mono">
                      {s.type || "stdio"} · {transportLabel(s)}
                    </div>
                    <div class="mt-0.5 text-[11px] text-ink-500">
                      {t("mcp.tools", { n: String(s.toolCount) })}{#if secretLabel(s)} · {secretLabel(s)}{/if}
                    </div>
                    {#if s.error}
                      <div class="mt-0.5 text-[11px] text-danger">{s.error}</div>
                    {/if}
                  </div>
                  <div class="flex gap-1 shrink-0 flex-wrap justify-end">
                    {#if s.enabled && s.live}
                      <button
                        class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-300 hover:bg-ink-800 disabled:opacity-40"
                        disabled={refreshing === s.name}
                        onclick={() => refresh(s.name)}
                      >{refreshing === s.name ? "…" : t("mcp.refresh")}</button>
                    {/if}
                    <button
                      class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-300 hover:bg-ink-800"
                      onclick={() => startEdit(s)}
                    >{t("mcp.edit")}</button>
                    {#if confirmRemove === s.name}
                      <button
                        class="rounded-md border border-danger/50 px-2 py-1 text-[11px] text-danger hover:bg-danger/10"
                        onclick={() => remove(s.name)}
                      >{t("mcp.sure")}</button>
                    {:else}
                      <button
                        class="rounded-md border border-ink-600 px-2 py-1 text-[11px] text-ink-400 hover:bg-ink-800"
                        onclick={() => { confirmRemove = s.name; setTimeout(() => { if (confirmRemove === s.name) confirmRemove = null; }, 2500); }}
                      >{t("mcp.remove")}</button>
                    {/if}
                  </div>
                </div>
              </div>
            {/each}
            {#if loading}
              <div class="text-[12px] text-ink-400 py-2 text-center">{t("mcp.loading")}</div>
            {:else if servers.length === 0}
              <div class="text-[12px] text-ink-400 py-4 text-center">{t("mcp.none")}</div>
            {/if}
            {#if error}
              <div class="text-[12px] text-danger">{error}</div>
            {/if}
            <button
              class="w-full rounded-lg border border-ink-600 px-3 py-2 text-[13px] text-accent hover:bg-ink-800"
              onclick={startAdd}
            >
              + {t("mcp.addServer")}
            </button>
            <div class="text-[11px] text-ink-500 leading-relaxed pt-1">
              {t("mcp.hint")}
            </div>
          </div>
        {/if}
      </div>
    </div>
  </div>
{/if}
