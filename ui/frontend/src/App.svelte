<script lang="ts">
  import { onMount } from "svelte";
  import Sessions from "./views/Sessions.svelte";
  import Chat from "./views/Chat.svelte";
  import { send, online, onStatus, isWails, busUrl, on, emit } from "./nats";
  import Components from "./views/Components.svelte";
  import { initTheme, toggleTheme } from "./lib/theme";
  import { t, cycleLocale, locale } from "./lib/i18n.svelte";
  import ProviderControl from "./components/ProviderControl.svelte";
  import ProviderManager from "./components/ProviderManager.svelte";
  import ModelPicker from "./components/ModelPicker.svelte";
  import type { ProviderSummary, ResolvedConfig, SessionStatus } from "./lib/providers";
  import { fmtContext, contextPct } from "./lib/providers";

  interface ApprovalReq {
    id: string;
    tool: string;
    args: any;
    sessionId: string;
  }

  let connected = $state<boolean | null>(null);
  let url = $state("");
  let sessionId = $state<string | null>(null);
  let refreshKey = $state(0);
  let approvals = $state<ApprovalReq[]>([]);
  let theme = $state<"light" | "dark">(initTheme());
  let autoApproved = $state<Record<string, string[]>>({});

  // Provider/model state
  let providers = $state<ProviderSummary[]>([]);
  let effective = $state<ResolvedConfig | null>(null);
  let sessionModels = $state<Record<string, string>>({});
  let sessionStatus = $state<Record<string, SessionStatus>>({});
  let managerOpen = $state(false);
  let modelPickerOpen = $state(false);

  function isAutoApproved(sid: string, tool: string): boolean {
    return (autoApproved[sid] ?? []).includes(tool);
  }

  async function loadProviders() {
    try {
      const resp = await send("provider", "provider_list", {});
      providers = (resp.providers ?? []) as ProviderSummary[];
    } catch {
      providers = [];
    }
  }

  async function loadEffective(model?: string) {
    try {
      const args: Record<string, unknown> = {};
      if (model) args.model = model;
      const resp = await send("llm", "llm_resolve", args, 10000);
      effective = resp as ResolvedConfig;
    } catch {
      effective = null;
    }
  }

  async function loadSessionModel(sid: string) {
    try {
      const resp = await send("store", "get", { kind: "conversation", id: sid });
      const v = resp.value ?? {};
      sessionModels[sid] = v.modelOverride ?? "";
    } catch {
      // store unreachable
    }
  }

  async function switchProvider(nickname: string) {
    try {
      if (nickname === "__env__") {
        await send("provider", "provider_use_environment", {}, 30000);
      } else {
        await send("provider", "provider_switch", { nickname }, 30000);
      }
    } catch {
      // approval denied or error — keep current state
    }
    await loadProviders();
    await loadEffective(sessionModels[sessionId ?? ""] || undefined);
  }

  async function pickModel(model: string) {
    const sid = sessionId;
    if (!sid) return;
    sessionModels[sid] = model;
    try {
      await send("core", "session", { sessionId: sid, model }, 30000);
    } catch {
      // approval denied or llm unavailable
    }
    await loadEffective(model || undefined);
  }

  // What the header shows for "model": session override if set, else effective.
  const headerModel = $derived.by(() => {
    const sid = sessionId;
    if (sid && sessionModels[sid]) return sessionModels[sid];
    return effective?.model ?? "";
  });

  const headerCatalog = $derived(effective?.catalog ?? "");

  const headerStatus = $derived.by(() => {
    const sid = sessionId;
    if (sid && sessionStatus[sid]) return sessionStatus[sid];
    return null;
  });

  const headerContext = $derived(
    headerStatus?.context ?? effective?.context ?? 0
  );
  const headerUsed = $derived(headerStatus?.usedTokens ?? 0);
  const ctxPct = $derived(contextPct(headerUsed, headerContext));

  // The UI's own bus identity (see ui/bridge.go: sdk.New("ui", ...)).
  // Directed approval requests arrive on this component's private subject;
  // core derives the subject from the call envelope's caller field and
  // never hardcodes component names.
  const UI_NAME = "ui";

  onMount(() =>
    on(`svc.approval.${UI_NAME}.request`, (ev) => {
      const p = ev.payload ?? {};
      if (!p.id || !p.tool) return;
      const sid = p.sessionId ?? "";
      if (isAutoApproved(sid, p.tool)) {
        // Decision alone resolves the gate; no ack needed.
        emit("ev.approval.reply", { id: p.id, ok: true });
        return;
      }
      // Ack so the runner knows a human is being asked; then show the modal.
      emit("ev.approval.reply", { id: p.id, ack: true });
      approvals = [...approvals, { id: p.id, tool: p.tool, args: p.args, sessionId: sid }];
    })
  );

  onMount(() =>
    on("ev.approval.request", (ev) => {
      // Broadcast requests (direct calls, or fallbacks whose driver is
      // gone): any interactive client may answer, first reply wins.
      const p = ev.payload ?? {};
      if (p.id && p.tool) {
        const sid = p.sessionId ?? "";
        if (isAutoApproved(sid, p.tool)) {
          emit("ev.approval.reply", { id: p.id, ok: true });
        } else {
          approvals = [...approvals, { id: p.id, tool: p.tool, args: p.args, sessionId: sid }];
        }
      }
    })
  );

  onMount(() =>
    on("ev.approval.resolved", (ev) => {
      // The gate reached a verdict (possibly via another client): drop the
      // matching modal instead of leaving a stale prompt open.
      const p = ev.payload ?? {};
      if (p.id) approvals = approvals.filter((r) => r.id !== p.id);
    })
  );

  onMount(() => {
    const onKey = (e: KeyboardEvent) => {
      if (approvals.length === 0) return;
      if (e.key === "Enter") {
        e.preventDefault();
        answerApproval(true);
      } else if (e.key === "Escape") {
        e.preventDefault();
        answerApproval(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // Provider/model event subscriptions
  onMount(() => on("ev.provider.changed", () => {
    loadProviders();
    loadEffective(sessionModels[sessionId ?? ""] || undefined);
  }));

  onMount(() => on("ev.models.updated", () => {
    loadEffective(sessionModels[sessionId ?? ""] || undefined);
  }));

  onMount(() => on("ev.session.status", (ev) => {
    const p = ev.payload ?? {};
    if (p.sessionId) {
      sessionStatus = { ...sessionStatus, [p.sessionId]: p };
    }
  }));

  // Initial load + connection state
  onMount(() =>
    onStatus((online, u) => {
      connected = online;
      url = u;
      if (online) {
        loadProviders();
        loadEffective();
      }
    })
  );

  // Load session model when session changes
  let prevSession: string | null = null;
  $effect(() => {
    if (sessionId !== prevSession) {
      prevSession = sessionId;
      if (sessionId) {
        loadSessionModel(sessionId);
        loadEffective(sessionModels[sessionId] || undefined);
      } else {
        loadEffective();
      }
    }
  });

  function prettyArgs(args: any): string {
    const s = JSON.stringify(args ?? {}, null, 2);
    return s.length > 3000 ? s.slice(0, 3000) + "…" : s;
  }

  function answerApproval(ok: boolean, auto = false) {
    const req = approvals[0];
    if (!req) return;
    if (auto) rememberAutoApprove(req.sessionId, req.tool);
    emit("ev.approval.reply", { id: req.id, ok });
    approvals = approvals.slice(1);
  }

  function rememberAutoApprove(sid: string, tool: string) {
    if (!sid) return;
    const list = autoApproved[sid] ?? [];
    if (!list.includes(tool)) autoApproved[sid] = [...list, tool];
    // Persist so the core's gate honors it for every client (no dialog at
    // all, not even a flash). Best effort: the in-memory list still covers
    // this session if the store is unreachable.
    send("store", "put", {
      kind: "approval",
      id: sid + ":" + tool,
      value: { tool, sessionId: sid },
    }, 5000).catch(() => {});
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
        class:bg-danger={connected === false}
        class:bg-ink-600={connected === null}
        title={connected === null ? t("app.connecting") : (connected ? t("app.busConnected") : t("app.busUnreachable")) + (url ? " · " + url : "")}
      ></span>
    </div>
    <Sessions {selectSession} {sessionId} {refreshKey} onDelete={handleDelete} />
    <div class="p-3 border-t border-ink-700">
      <button
        class="w-full rounded-md bg-accent-dim/15 text-accent px-3 py-2 text-sm font-medium hover:bg-accent-dim/25"
        onclick={newSession}
      >
        {t("app.newSession")}
      </button>
    </div>
    <Components {sessionId} />
  </aside>

  <main class="flex-1 flex flex-col min-w-0">
    <header class="flex items-center gap-2 px-4 py-2 border-b border-ink-700 text-[13px] text-ink-400">
      <span>{sessionId ? t("app.session", { id: short(sessionId) }) : t("app.newSessionLabel")}</span>
      {#if url}
        <span class="font-mono text-ink-600 hidden sm:inline">{url}</span>
      {/if}

      <div class="ml-auto flex items-center gap-1.5">
        <ProviderControl {providers} {effective} onSwitch={switchProvider} onManage={() => (managerOpen = true)} />

        <button
          class="rounded-md border border-ink-600 px-2 py-1 text-[12px] hover:bg-ink-800 max-w-[160px] truncate"
          title={headerModel ? t("app.model") + " " + headerModel : t("app.selectModel")}
          onclick={() => (modelPickerOpen = true)}
          disabled={!sessionId}
        >
          <span class="text-ink-400">{t("app.model")}</span>
          <span class="text-ink-200 ml-1">{headerModel || "—"}</span>
        </button>

        {#if headerContext > 0}
          <span
            class="font-mono text-[11px] px-1.5 py-0.5 rounded"
            class:text-ink-400={ctxPct < 75}
            class:text-warn={ctxPct >= 75 && ctxPct < 90}
            class:text-danger={ctxPct >= 90}
            title={t("app.tokens", { used: headerUsed.toLocaleString(), context: headerContext.toLocaleString() })}
          >
            {fmtContext(headerUsed)} / {fmtContext(headerContext)}
          </span>
        {/if}

        <button
          class="rounded-md border border-ink-600 px-2 py-1 text-[13px] hover:bg-ink-700"
          title={theme === "dark" ? t("app.switchLight") : t("app.switchDark")}
          aria-label={theme === "dark" ? t("app.switchLight") : t("app.switchDark")}
          onclick={() => (theme = toggleTheme())}
        >
          {theme === "dark" ? "☀" : "☾"}
        </button>
        <button
          class="rounded-md border border-ink-600 px-2 py-1 text-[12px] hover:bg-ink-700"
          title={t("app.switchLanguage")}
          aria-label={t("app.switchLanguage")}
          onclick={cycleLocale}
        >
          {locale() === "en" ? "EN" : locale() === "zh" ? "中文" : "繁中"}
        </button>
      </div>
    </header>
    {#if !isWails()}
      <div class="mx-6 mt-4 rounded-lg border border-danger/40 bg-danger/10 px-4 py-3 text-[13px] text-danger">
        {t("app.browserNotice")} <code class="font-mono">./ui/build/bin/niffler-ui</code>
      </div>
    {:else if connected === false}
      <div class="mx-6 mt-4 rounded-lg border border-danger/40 bg-danger/10 px-4 py-3 text-[13px] text-danger">
        {t("app.unreachableNotice", { url: url || "nats://127.0.0.1:4222" })}
        <code class="font-mono">NATS_URL={url || "nats://127.0.0.1:4222"} ./var/bin/niffler</code>
      </div>
    {/if}
    <Chat bind:sessionId={sessionId} />
  </main>
</div>

<ProviderManager bind:open={managerOpen} {providers} onSaved={() => { loadProviders(); loadEffective(sessionModels[sessionId ?? ""] || undefined); }} />
<ModelPicker bind:open={modelPickerOpen} catalog={headerCatalog} currentModel={headerModel} onSelect={pickModel} />

{#if approvals.length > 0}
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
    <div class="w-[520px] max-w-[92vw] rounded-xl border border-ink-600 bg-ink-900 p-5 shadow-2xl">
      <div class="text-[15px] font-semibold text-ink-200">{t("app.approvalRequired")}</div>
      <div class="mt-1 text-[13px] text-ink-400">
        {t("app.approvalWaiting")}
      </div>
      <div class="mt-3 rounded-lg border border-ink-600 bg-ink-800 p-3">
        <div class="font-mono text-[13px] text-accent">{approvals[0].tool}</div>
        <pre class="mt-2 max-h-52 overflow-y-auto whitespace-pre-wrap font-mono text-[12px] text-ink-300">{prettyArgs(approvals[0].args)}</pre>
      </div>
      {#if approvals.length > 1}
        <div class="mt-2 text-[12px] text-ink-400">{t("app.moreWaiting", { n: String(approvals.length - 1) })}</div>
      {/if}
      {#if (autoApproved[approvals[0].sessionId] ?? []).length > 0}
        <div class="mt-2 text-[12px] text-ink-400">
          {t("app.autoApproving")} <span class="font-mono">{autoApproved[approvals[0].sessionId].join(", ")}</span>
        </div>
      {/if}
      <div class="mt-4 flex items-center justify-between gap-2">
        <span class="text-[11px] text-ink-400">{t("app.enterEsc")}</span>
        <div class="flex gap-2">
          <button
            class="rounded-lg border border-ink-600 px-4 py-1.5 text-[13px] text-ink-300 hover:bg-ink-800"
            onclick={() => answerApproval(false)}
          >
            {t("app.deny")}
          </button>
          {#if approvals[0].sessionId}
            <button
              class="rounded-lg border border-accent-dim/50 px-4 py-1.5 text-[13px] text-accent hover:bg-accent-dim/10"
              title={t("app.autoApproveTitle")}
              onclick={() => answerApproval(true, true)}
            >
              {t("app.autoApprove")}
            </button>
          {/if}
          <button
            class="rounded-lg bg-accent px-4 py-1.5 text-[13px] font-semibold text-ink-950 hover:opacity-90"
            onclick={() => answerApproval(true)}
          >
            {t("app.approve")}
          </button>
        </div>
      </div>
    </div>
  </div>
{/if}
