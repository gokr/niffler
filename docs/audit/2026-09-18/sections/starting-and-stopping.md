# Worklist slice: Starting and stopping

From `worklist.tsv` (13 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A189 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2237-2243 "The bridge's first act is the SDK's `ensureHarness`: probe `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222 for a core serving **this root** … spawn `var/bin/niffler` detached with `NIF_AUTOSTART=1`"
- CODE: `ui/bridge.go:70-81` (`sdk.EnsureHarness(harnessRoot())` in `startup`, before the connect loop), `sdk/go/harness.go:121-184`, `sdk/niffler/sdk.nim:608-672`
- FIX: accurate; add the numbers a debugger needs — the attach probe retries for ~10 s at 200 ms, the post-spawn wait is 20 s and fails with "spawned core did not answer within 20s — check <root>" (`harness.go:133-142,163-182`; `sdk.nim:626-634,655-671`), and the Nim SDK first reaps a core it spawned earlier in this session (`sdk.nim:593,621`).

## A190 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2244-2247 "**Interactive plugins** (e.g. `niffler-tui`) — they do **not** call `ensureHarness` and never spawn a harness: they probe for a live bus (`NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222), connect and register `client: true`"
- CODE: `~/git/niffler-tui/tui/main.go:2821-2841` (probe order: `NIF_NATS_URL`, `$NIF_ROOT/var/nats-url`, `./var/nats-url`, well-known URL), `tui/main.go:2956` (`comp.Client = true`)
- FIX: mostly accurate; correct two things — the TUI also probes `$NIF_ROOT`-relative and **cwd**-relative `var/nats-url`, and, unlike `ensureHarness`, it performs **no root check** on the core it attaches to, so a TUI can join a foreign harness's bus while the desktop UI cannot.

## A191 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2251-2259 "Interactive frontends register `"client": true` … An **autostarted** core counts them: when the last one departs it shuts down after `NIF_AUTOSTART_IDLE_S` (default 10s — a restarting UI re-registers inside that window) … if none ever arrives it gives up after `NIF_AUTOSTART_BOOT_S` (default 60s)."
- CODE: `core/catalog.nim:794-798` (`clientCount` counts `reg.publish` entries with `client: true`), `core/niffler.nim:659-691` (`sawClients` latch, `lastClientLeft` debounce, `bootedAt` grace)
- FIX: accurate, but the text conflates two mechanisms — add "(client counting is registration-based: a client that dies without `reg.depart` keeps core alive until the catalog drops it, which is a different clock from the UI registry's 20 s lease, see Clients)".

## A192 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2248-2250 "**Terminal admin shell** — `./var/bin/niffler` directly … A manually started core never self-terminates; stop it with Ctrl-C / SIGTERM."
- CODE: `core/niffler.nim:659` `if isatty(stdin) and not autostart:` → admin shell; `:330-334` SIGTERM/SIGINT handlers installed before the bus spawn
- FIX: accurate; add that `NIF_AUTOSTART=1` forces service mode even on a tty (`niffler.nim:659`), and that the shell keeps pumping `svc.core.call` while it waits at the prompt (`tty.nim:7-9`, `niffler.nim:661-664`).

## A193 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (`NIF_NATS_SPAWN`, and `NIF_NATS_URL`'s short-circuit)
- CODE: `core/niffler.nim:343-351` (`NIF_NATS_SPAWN=1` → isolated core-owned bus on a random port, never 4222), `sdk/go/harness.go:121-123` + `sdk/niffler/sdk.nim:615-617` (an explicit `NIF_NATS_URL` returns early: nothing is probed and nothing is spawned)
- FIX: add to §Starting and stopping: "An explicit `NIF_NATS_URL` short-circuits `ensureHarness` entirely — the client attaches to exactly that bus and never spawns core. `NIF_NATS_SPAWN=1` (dev clones) is the opposite: core always creates its own isolated bus on a random port and never claims 4222." (`grep -n NIF_NATS_SPAWN docs/MANUAL.md` → only line 1947, in the observe section.)

## A194 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (kernel-level child cleanup)
- CODE: `core/supervisor.nim:143-152` (every supervised child is launched as `setpriv --pdeathsig TERM …` so the kernel SIGTERMs it when core dies, even on SIGKILL), `components/nats/main.go:15-18` + `sdk/go/pdeathsig_linux.go:17` + `sdk/niffler/sdk.nim:547` (the bus and SDK-spawned processes self-set `PR_SET_PDEATHSIG`), `sdk/go/harness.go:158` (`Setsid` only — core itself deliberately has no PDEATHSIG, so a UI-detached core can outlive the UI)
- FIX: add a short paragraph: "Core is the only process without a parent-death backstop (it must survive its UI); every child it starts — components, session runners, the bus — is launched with `setpriv --pdeathsig TERM` and the SDKs self-set `PR_SET_PDEATHSIG`, so nothing survives its harness, even on SIGKILL. Off Linux both mechanisms are absent."

## A196 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2322 Troubleshooting "component crashes on boot, restarts in a backoff loop | `core.remove` it …"
- CODE: `core/supervisor.nim:33-49,200-212`
- FIX: scope it: only components whose policy is `on-failure` loop; `never` components (session runners, any manifest entry declaring `restart: never`) stay down after a crash and are reported once.

## A197 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (the `ui` core tool, the registry, its ops)
- CODE: `core/catalog.nim:213-224` (hidden core tool `ui`, ops `register|renew|release|claim|release_session|owner`), `core/uireg.nim:1-124`
- FIX: add "Clients and the UI registry": interactive frontends announce a client-supplied UUID, receive a display number ("Niffler 1", "Niffler 2", …) and a 20 s lease they must renew; `claim` gives one live UI a conversation, `release_session`/`release` give it back, `owner` reports the holder; expired entries are swept lazily on every registry decision, so no timer thread exists (`uireg.nim:52-59,65-77`); numbers are monotonic per harness lifetime and never reused (`uireg.nim:11-12,84-88`); a claim by a non-owner answers `{ok: false, owner, number}` (`uireg.nim:97-102`) and a `renew` for an expired id answers `{ok: false}`, forcing re-register + re-claim (`uireg.nim:89-95`). Say plainly that this is coordination between cooperating UIs, **not** authentication (`uireg.nim:10-13`).

## A198 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (which clients use the registry, and renewal cadence)
- CODE: `~/git/niffler-tui/tui/main.go:629-690,635` (the TUI registers `tui-<hex>`, claims its startup conversation, re-registers/re-claims every `uiLeaseRenewInterval = 5 * time.Second`), `ui/bridge.go:25-26` (the Wails bridge registers as **component `ui`** with `Client = true` and never touches the registry), `grep -rn '"ui"' ui/frontend/src` → no hits; shipped tree: `grep -rn 'Client = true' components/ ui/ core/ sdk/` → only `ui/bridge.go:26`
- FIX: state the asymmetry: "Only the niffler-tui terminal client participates in the registry; the desktop UI registers as component `ui` with `client: true` purely for autostart bookkeeping, so several desktop windows can view one conversation without an ownership notice. Note the name collision: the hidden core **tool** `ui` is the registry; the **component** `ui` is the Wails bridge."

## A199 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (`/restart` identity handoff)
- CODE: `~/git/niffler-tui/tui/handoff.go:1-30,36-111` (a `handoff` record beside the last-session file, `{ui, session, at}`, TTL 120 s, consumed once, both ids sanitized on the way out), `tui/main.go:2896-2910,2940-2956` (successor adopts `handoffUI` for its first register+claim), `tui/main.go:3055-3068` (a restarting client exits with code 85 **without** releasing the lease — a release would make the successor a stranger core refuses), `tui/main.go:58-63` (the install wrapper loops on that code), `tui/uirelease.go:1-63` (every *other* exit releases, 3 attempts / ~2.5 s, then one stderr warning)
- FIX: document under the registry: "`/restart` exits with code 85 for the install wrapper to re-run the binary from disk. The predecessor does **not** release its registry identity; it leaves a `handoff` record (keyed by bus + workspace, TTL 120 s) that the successor consumes for its first register+claim, so the conversation and the 'Niffler N' label survive a restart whose release never landed."

## A200 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (the client roster)
- CODE: `core/tty.nim:19-26,141-177,203-210` (`help\|status\|catalog\|tools\|sessions\|exit`, plus `?` and `quit`; nothing else — an unknown word prints "unknown command"), `ui/bridge.go:15-36` (bridge is a bus citizen; the SPA is the NATS client), `ui/frontend/src/nats.ts:7,17-28` (SPA talks to `window.go.main.Bridge` and raw NATS), `components/cli`, `components/console` (both documented at MANUAL 430-455)
- FIX: add a one-table "Clients" section — binary → role → autostarts a harness? → uses the registry? The three facts a reader cannot get today: the tty is status-only (no chat, no calls), the SPA is a NATS client that Wails merely hosts, and `console`/`cli` are bus tools rather than chat UIs.

## A201 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 139-144 (admin shell) is accurate but buried in §Session runners
- CODE: `core/tty.nim:19-26`
- FIX: keep the sentence and cross-link the new §Clients; the command list is exactly `help|status|catalog|tools|sessions|exit` and both `?` and `quit` are accepted aliases (`tty.nim:203-210`).

## A202 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: absent (what the interactive clients actually call)
- CODE: `ui/frontend/src/views/Chat.svelte:439` (`send("core","session",{sessionId, content, model, profile}, 600000)` — a 10-minute timeout), `ui/frontend/src/App.svelte:206` (`core`/`session` status/controls with a 30 s timeout), `ui/frontend/src/views/Sessions.svelte:27,58` (sidebar reads `store.list` directly)
- FIX: add one sentence to §Clients: "The web UI and the TUI are ordinary bus clients: they call `svc.core.call` with the `session` tool (10-minute timeout for a turn, 30 s for status/control calls) and read the transcript with `store.list` — nothing about a conversation is UI-private."

