# Changelog

All notable changes to Niffler are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims for [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **plugins component** — the ecosystem front door as a bus service:
  `plugin_search` (GitHub `topic:niffler-component` discovery, no
  registry), `plugin_install`/`plugin_update`/`plugin_remove`,
  `plugin_installed`. Packages are git repos with a `niffler.json`
  manifest; installs always compile from source via the builder
  (the harness already ships the toolchain), then `core.spawn` each
  component (approval-gated). Install records live in the store
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
  non-LLM component (bash, store, builder, console, plugins, core, cli),
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
