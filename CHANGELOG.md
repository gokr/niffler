# Changelog

All notable changes to Niffler are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims for [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **UI-owned harness lifecycle** — `scripts/niffler.sh` (and `make
  up/down/status`) are gone; the binaries own start/stop. Any interactive
  client (the desktop UI, interactive plugins) calls the SDK's
  `ensureHarness`: probe `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222
  for a live core, else spawn `var/bin/niffler` detached with
  `NIF_AUTOSTART=1`. Interactive frontends register `"client": true`; an
  autostarted core exits when the last one departs
  (`NIF_AUTOSTART_IDLE_S`, default 10s) or when none arrives within boot
  grace (`NIF_AUTOSTART_BOOT_S`, default 60s). A manually started
  `./var/bin/niffler` (terminal admin shell) never self-terminates.
  `niffler-ui`'s repo root is baked via ldflags at `make ui` time, so the
  installed desktop icon is the whole system; `make recover` stops any
  running harness inline. Covered by `tests/t_autostart.nim`.
- **models component** — a Go component serving the models.dev provider/
  model catalog over the bus (docs/MODELS.md): embedded offline seed,
  validated atomic cache with last-known-good fallback, strict model
  resolution, searchable capabilities/limits/pricing, and deterministic
  `x-models-source` plugin patches (RFC 7396 JSON Merge Patch) discovered
  automatically from other registered components; refreshes publish
  `ev.models.updated`. `llm` resolves each model's context window through
  the catalog (per-provider override → `NIF_OPENAI_CONTEXT` → catalog →
  built-in fallback), so core's context guard uses real provider metadata.
- **provider component** — a Go component turning the LLM backend
  configuration into store records (kind `provider`, docs/MANUAL.md
  "Provider registry"): `provider_add`/`list`/`switch`/`active`/`remove`/
  `export`/`import`, with the first added provider becoming active, keys
  never leaked by `provider_list`, active-fallback on removal, and
  `ev.provider.switch {nickname, previous, at}` notifications on every
  switch. `llm` now resolves its default backend from the active stored
  provider on each chat call — `provider_switch` live-updates the LLM
  backend with no restart — falling back to `NIF_OPENAI_*` and
  `NIF_LLM_PROVIDERS` when the component is absent or nothing is active.
  Secret-handling tools (`add`/`import`/`export`) are approval-gated.
- **grep + write components** — ripgrep-backed code search (`grep`:
  `path:line:match` results with .gitignore/hidden/binary handling,
  globs, context, case folding, exact truncation markers; `files`: sorted
  repo listing) with the pattern passed as argv, so no shell quoting is
  needed, plus an approval-gated atomic whole-file `write` (temp file +
  rename, permission preservation, symlink-following, parent-dir
  creation, content cap under the NATS payload limit). Both ship as
  autostart components with bus-contract tests.
- **fetch component** — bounded HTTP(S) retrieval over the bus with custom
  methods, headers and request bodies; redirects, timeout and response-size
  limits; and oversized post-processing results spilled under `var/fetch`.
  HTML extraction prefers an installed Trafilatura CLI, passing it the
  already-downloaded response with a 30-second bound, then falls back to a
  pure-Nim `htmlparser` walk when Trafilatura is absent, fails, times out or
  returns no content. `NIF_TRAFILATURA` overrides detection or disables it.
- **isolated concurrent tests** — every bus-contract test owns a
  NATS-assigned loopback port and writable temporary `NIF_ROOT`; core tests
  snapshot only their required binaries, agent-built Nim components use a
  local cache, and a cross-process lock (`scripts/with-build-lock.sh`)
  serializes repository build writers while letting test runs overlap. One
  lock is held around a whole build generation (`make build`), `make clean`
  takes it too, the builder writes binaries via temp+rename, core tracks its
  spawned bus by PID file, and `make test` runs the Go unit tests. Separate
  agents can now run component targets alongside each other and a live harness.
- **Session runners — one conversation = one process** — the system
  harness spawns a `var/bin/session <id>` runner per conversation
  (present in the catalog as `session-<id>`, 0 tools), serving
  `svc.session.<id>.call` and emitting `ev.session.*`; runners resume the
  conversation from the store on first use, so they are ephemeral and
  disposable — killing one loses only that conversation's in-flight turn.
  Core tools (spawn/kill/remove/catalog) go back over the bus to
  `svc.core.call`; a new `catalog {op: snapshot}` lets late joiners seed
  their view (reg.publish is fire-once). The tty is no longer a chat REPL —
  turns never nest.
- **tty: admin shell** — the stdin/stdout REPL is now an admin status
  shell (`core/tty.nim`), not a conversation UI: `help`, `status`,
  `catalog`, `tools`, `sessions`, `exit`, with arrow-key history and tab
  completion. The LLM chat lives in the web UI and the `niffler-tui`
  plugin; scripting goes through the `cli` component.
- **observe component** — bounded live inspection of the raw NATS bus:
  subject discovery, token-correct listen probes, request/reply traces,
  recent structured logs, safe capture exports, and server monitoring.
  Arbitrary event publishing and service requests are approval-gated.
- **logfile component + SDK logging** — all SDKs publish thresholded
  `ev.log.<component>` events; logfile persists them as rotating JSONL with
  bounded newest-first search, lossless whole-bus JSON capture, retention,
  and write-health reporting. Raw SDK taps now dispatch exactly once per
  NATS subscription.
- **UI: components panel** — the sidebar now lists the live bus
  components and their tools (name, version, pid, registration time,
  language/source where known), fed by `ev.catalog.updated`.
- **UI: tool-run view** — `ToolRun.svelte` replaces the tool-call card:
  a dedicated view per tool call with the run's arguments, result and
  error rendering.
- **UI: app theme** — light/dark theming (`theme.ts`): a `dark` class on
  `<html>` with a localStorage override of the OS default, applied inline
  before first paint (no flash of the wrong theme).
- **UI: chrome** — window menu, About dialog showing the build commit
  hash, and a Linux desktop entry with app icons (launcher + icon files).
- **Approval requests carry the session** — `ev.approval.request` payloads
  now include `sessionId` ("" for direct harness calls), enabling
  per-conversation auto-approve decisions in the UI.
- **plugins component** — the ecosystem front door as a bus service:
  `plugin_search` (GitHub `topic:niffler-component` discovery, no
  registry), `plugin_install`/`plugin_update`/`plugin_remove`,
  `plugin_installed`. Packages are git repos with a `niffler.json`
  manifest; installs always compile from source via the builder
  (the harness already ships the toolchain), then `core.spawn` each
  service component (approval-gated). Components marked
  `"interactive": true` are built into `var/bin` but left for the user to
  start in a terminal. Install records live in the store
  (kind `plugin`) and survive restarts. `file://` repo URLs install
  from local git repos — hermetic installs, mirrors.
- **console component** — passive bus viewer: subscribes to everything
  and renders every envelope readably (calls with tool+args, results,
  errors, events, approvals). Run it in a second terminal to follow the
  harness live; better than `nats sub '>'`.
- **cli component** — drive the harness from a terminal or a script:
  `catalog` / `wait <comp>` / `call <tool> '<json>'` / `install <repo>[@<ref>]`,
  each exiting 0 on success. Its catalog seeds from a new core
  `catalog {op: components}` view, so it works against an
  already-running harness. This is the preferred way to CI a plugin
  repo (gokr/niffler-weather's workflow uses it).
- **Streaming LLM adapter** — `components/llm` (Go): OpenAI-compatible
  chat with live token streaming (`ev.llm.token {sessionId, content,
  reasoning}` deltas, incl. deepseek-reasoner's `reasoning_content`),
  streamed tool-call aggregation, per-call cancellation
  (`llm.cancel.<sessionId>`). Core forwards deltas for the active turn
  as `ev.session.token`; the UI appends them to the live assistant
  bubble; the final assistant event always carries complete content
  (heals any last-frame race). `components/llm-openai` stays as the
  minimal non-streaming example adapter (swap via manifest.yaml).
- **hashline-edit component** — hash-anchored file editing (Nim port of
  pi-hashline-edit-pro): `read` / `replace` / `undo_last_replace` on
  stable 3-char line anchors, so edits land on the lines the model
  actually saw; persistent per-file anchor store; stale-range
  protection.
- **Bus-contract test suite** — `tests/helpers.nim` + one `t_*.nim` per
  non-LLM component (bash, store, builder, console, plugins, skills, fetch,
  models, provider, observe, logfile, hashline-edit, grep, write, core, cli,
  autostart),
  each booting the real binaries over its own throwaway NATS and driving
  them with envelopes (the envelope is the artifact — one harness tests
  Nim and Go components alike). `make test` runs the suite;
  `make test-<comp>` runs one. Network opt-ins:
  `NIF_TEST_INSTALL=1` (real install + tool validation),
  `NIF_TEST_NETWORK=1` (plugin_search).
- **TypeScript/Node.js component SDK** — `sdk/ts` (npm package
  `niffler-sdk`), a 1:1 mirror of the Go SDK: same surface
  (`newComponent`/`tool`/`on`/`emit`/`request`/`run`), async handlers
  serialized through a promise chain (the Nim single-thread model).
  The builder compiles `lang: "ts"` components: generated package.json
  (wires the SDK via a `file:` dependency) + tsconfig, `npm install`,
  `tsc`, and a `#!/usr/bin/env node` wrapper binary under `var/bin`.
  Verified live end-to-end: builder → spawn → call from Node.js.
- **HTTPS in all Nim builds** — `-d:ssl` is now set repo-wide
  (`config.nims`), so every component (and builder-built tool) can use
  std/httpclient against https endpoints. Prerequisite: `libssl-dev`
  (Ubuntu), Xcode CLT (macOS) — added to `make setup`.
- **Approval gate** — tools carrying `x-harness.approval: "always"`
  (`bash`, `builder.build`, `core.spawn`/`kill`/`remove`) now require a
  human before executing: a y/N prompt in the terminal harness, a dialog in
  the web UI (`ev.approval.request` / `ev.approval.reply` over the bus).
  Calls with no human reachable are denied, never silently approved;
  unanswered UI requests time out after 5 minutes. `NIF_AUTO_APPROVE=1`
  bypasses the gate for headless automation.
- **Recover mode** — `./var/bin/niffler --recover` (front door:
  `make recover`): rebuilds the shipped binaries from source (`make build`,
  falling back to `nimble all`), wipes the store's component records so
  spawned components are not restored, and boots normally. Conversations
  and messages survive; only the component shape resets.
- **Context-window guard** — core tracks the model-reported
  `usage.prompt_tokens` vs the window size (persisted with assistant
  messages, restored on resume) and acts trivially: warns once at 75%,
  trims whole turns from the front at 90% (system prompt kept, never
  below 2 turns, note inserted). The store keeps the full history;
  trimming is in-memory per session. `ev.session.context` events
  surface it in the UI.
- **Context window is config, not a database** — `llm` reports the
  window with every chat response: `NIF_OPENAI_CONTEXT` env override, a
  tiny built-in table for the default model family (DeepSeek: 1M), else a
  conservative 128K. The only window that matters is the configured
  model's, and it rides in `context` on each chat response.
- **docs/MANUAL.md** — operating manual: layout of a running system, all
  environment variables and `.env` rules, bus subjects, approvals,
  lifecycle, recovery, store, troubleshooting. Linked from README.
- **Self-knowledge in the system prompt** — the agent is now told its home
  directory (the git repo), where components/SDK/docs/manifest live, that
  `var/` is disposable build output, and that `--recover` rebuilds it.

### Changed

- **Bus discovery prefers the canonical port** — when core spawns its own
  `nats-server` it now tries `127.0.0.1:4222` first (the port local clients
  default to) and falls back to a random loopback port only when 4222 is
  taken — a failed bind makes nats-server exit immediately, which retries
  with `-p -1`. `cli`/`console` resolve the bus as `NIF_NATS_URL` →
  `var/nats-url` → 4222, with a clear connect error instead of a silent hang.
- **Session turns run in per-session runner processes** — the session
  service moved out of the system process into `var/bin/session <id>`
  (see Added); the system harness only ensures a runner per conversation
  and forwards `session` tool calls to `svc.session.<id>.call` (clients
  keep calling `svc.core.call`).
- **Core entry point renamed** — `core/core.nim` → `core/niffler.nim`
  (matches the binary name).
- **All environment variables now carry the `NIF_` prefix**:
  `NATS_URL` → `NIF_NATS_URL`, `OPENAI_API_KEY` → `NIF_OPENAI_API_KEY`,
  `OPENAI_BASE_URL` → `NIF_OPENAI_BASE_URL`, `OPENAI_MODEL` →
  `NIF_OPENAI_MODEL`. (`NIF_ROOT` and `NIF_AUTO_APPROVE` already did.)
  Update `.env`, shell env and any scripts accordingly.
- **Restart policy is honored** — `manifest.yaml`'s `restart:` key and the
  store's `policy` field now actually control the supervisor
  (`never` vs `on-failure`); unknown values fall back to `on-failure`.
- **UI shows build commit** — the SPA embeds the git commit hash it was
  built from (`__BUILD_COMMIT__`, injected by `vite.config.js`).
- **UI assistant bubbles** — one live bubble per turn, updated in place
  as assistant events arrive; live token deltas stream into it.

### Fixed

- **Approval prompts go to the driving UI** — when an interactive client
  (web UI) is attached, approval requests route to its dialog even if
  core's own stdin happens to be a tty (core spawned from a terminal while
  the user interacts through the UI). The terminal y/N prompt is used only
  when core is on a terminal AND no UI is attached.
- **Core↔component re-entry deadlock** — a component calling back into
  core during a session turn (`plugin_install` → `core.spawn`) used to
  deadlock: core waited for the install's reply while the install waited
  for core's spawn answer. Dispatch now sends tool calls as poll-loop
  requests on a private inbox and serves `svc.core.call` (and the live
  token stream) in the idle slots; concurrent session requests are
  stashed and drained when the turn ends.
- **Timeout contract (`exit_code: 124`)** — Nim's
  `waitForExit(timeoutMs)` SIGKILLs the child itself on timeout and
  returns 137, never -1, so the bash/builder/plugins timeout branches
  never fired (bash reported 137 with no marker). Components now poll
  `peekExitCode` and own the kill; the documented 124 + `[timed out]`
  marker actually holds.
- **plugins stale-HTTP hang** — a single `HttpClient` reused across
  GitHub API calls could hang forever on a connection the server had
  closed (e.g. after a 404). One fresh client per call.
- **cli missed registrations** — the cli's catalog only saw
  `reg.publish` after connect; it now seeds from core's
  `catalog {op: components}` at startup and re-syncs on every wait miss.
- **UI duplicate reply bubbles** — one assistant event per LLM round
  pushed a new bubble once the pending one was resolved; the turn's
  assistant bubble is now tracked by index and updated in place.
- **Reserved component name `core`** — the catalog now rejects any
  `reg.publish`/`reg.depart` naming `"core"`. Previously a bus citizen
  could spoof core's registration (or delete core's seeded catalog entry
  with a `reg.depart`), hiding or replacing the control plane's tools.

## [0.1.0] — 2026-08-18

First cut of the minimal, self-extending agent harness: core speaks exactly
one protocol (JSON envelopes over NATS); everything else is a separate
process component.

### Added

- **Wire spec** (`docs/WIRE.md`) and envelope codec (`sdk/envelope.nim`,
  pure `std/json`) — versioned, boring, portable.
- **Nim SDK** (`sdk/niffler`) and **Go SDK** (`sdk/go`) — mirror 1:1;
  typed tool definitions with doc-comment schemas (Nim macro), request /
  emit / on, drain-on-signal, no threads (Nim) / mutex-serialized (Go).
- **Core** — bus bootstrap (reuse/spawn nats-server, `var/nats-url`
  discovery), supervisor (spawn, crash detection, backoff restarts, drain
  ordering, SIGTERM→SIGKILL escalation), catalog (registration, global
  tool-name uniqueness, hidden-tool filtering, schema normalization),
  dispatch (per-tool timeouts from `x-harness.timeoutMs`), conversation
  loop with the LLM toolset rebuilt from the live catalog per request.
- **Components** — `bash` (exec), `builder` (compiles agent-written Nim/Go
  sources), `store` (document store over the bus: put/get/list/del,
  rev-based optimistic concurrency, embedded BitBarrel), `llm-openai`
  (OpenAI-compatible chat adapter, `deepseek-chat` by default,
  DeepSeek-friendly flat tool_calls).
- **Self-extension end-to-end** — write → `builder.build` → `core.spawn`
  → tool appears in the LLM's toolset; `core.kill` (temporary) and
  `core.remove` (permanent) lifecycle.
- **Persistence of shape** — spawned components recorded in the store and
  restored on boot; conversations and messages persisted; `store` is
  single-writer on `var/barrel-db`.
- **Session service** — `svc.core.call` `session` turns + `ev.session.*`
  events; service mode (no tty) for UIs.
- **Wails v2 + Svelte 5 desktop UI** — a NATS client, not a Wails client:
  sessions from the store (create/delete/rename/auto-title), live chat
  with tool-call cards and markdown, conversation resume, model / token /
  context metadata, connection banner.
- **Makefile front door** — incremental builds per binary, `up`/`down`/
  `status`/`run`/`test`/`dev`/`clean`, `setup`/`doctor` per platform.
- **Smoke test** (`tests/smoke.nim`) — the one end-to-end test: spawns its
  own bus, exercises bash + store over the wire.
- **Docs** — REBOOT (design rationale), ARCHITECTURE (why core is core),
  WIRE (protocol), AGENTS (working guidelines), README.
