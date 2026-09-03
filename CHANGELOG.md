# Changelog

All notable changes to Niffler are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims for [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **llm: Anthropic cache reads surfaced in the usage breakdown** — the
  Anthropic adapter normalized `cache_read_input_tokens` into
  `prompt_tokens` but never set the OpenAI-style
  `usage.prompt_tokens_details.cached_tokens`, so Claude sessions
  carried no cached-input breakdown downstream (conversation status
  events, expert token accounting, bench, clients). Reads now map to
  `cached_tokens`; cache-creation input is excluded (a write, not a
  hit).

### Added

- **Subagent budgets: per-job token and tool-call caps** —
  `agent_run`/`agent_spawn` accept `maxCalls` (total tool dispatches per
  child turn, 1-500 — every dispatch attempt counts, success or error) and
  `maxTokens` (cumulative provider-reported tokens across the child's LLM
  rounds, checked before each new round). Both freeze into the child
  conversation header like `maxRounds` and end the turn as
  budget-exhausted instead of spending more.

- **Real command cancellation for bash** — a cancelled turn now kills the
  running command's whole process tree: the runner publishes
  `cancel.<component>` when it abandons an in-flight dispatch, and the bash
  component kills the command's process group promptly (exit 130). Commands
  run as the leader of their own process group (fork + setpgid + execvp), so
  the tool's own timeout now reaches descendants too instead of orphaning
  them (`sleep 100 &` no longer survives). Components opt in by subscribing
  their cancel subject and matching the injected session id.

- **SWE-bench Verified pilot run end-to-end** — 10 sympy instances, one-shot,
  official swebench 4.1.0 Docker grading, both bench models × pi/opencode/
  niffler: deepseek 9/9/6, glm 8/7/5 (resolved counts). Niffler resolves
  fewer tasks at 2.3–2.9× less total tokens per task. Protocol changes the
  pilot forced: recipe-style task prompts (flash agents previously burned
  turns on env archaeology and produced empty diffs), transport-level round
  retries (2×, never for auth/balance), process-group SIGKILL + stdio EOF on
  runner timeouts (an orphaned opencode child held the pipe and delayed
  `close` by ~20 h), and hidden gold/test-patch cards moved to
  `~/.cache/niffler-swe/cards`. Curated report:
  `bench/reports/swe-sympy10-pilot-report.md`.

- **fabric reliability pass + typed mode + named library** — the
  programmable-tool substrate hardened end-to-end (Phase 1.5–4):
  persistent bounded frame buffering (coalesced frames no longer
  starve the selector a round-trip late), scoped nested leases (an
  outer program's tool lease survives an inner `agent_run`), private
  session context stripped before targets, approvals and events, one
  monotonic absolute deadline for the whole run (`min(target tool
  timeout, remaining program time)` per nested call), complete bounded
  JSON-schema validation at admission, and hard caps on source,
  `strings` payload, frames, logs, results, artifacts and OS limits.
  `fabric` gained a **typed mode** (`tools: [...]`): the selected tool
  schemas are fingerprinted and pinned for the run (a
  `catalog-changed` error replaces silent drift against a replaced
  component), `fabricmeta` generates input-typed Nim wrappers
  (`tools.grep(...)` with compile-checked arguments), and a tool's
  scalar `outputSchema` types the wrapper's return value. Approvals
  show a manifest — source digest, viewable source
  (`var/approval-sources/<digest>.nim`), selected tools and budgets —
  with digest-keyed auto-approval: the same program runs freely again,
  any different program asks again. Repeatable programs live in a
  **named library** (`fabric {name}`, store kind `fabricprog`).
- **Bounded batch calls + effect declarations** — `batch(...)` runs up
  to 16 independent calls with 4 on the bus at once (host-backed, no
  guest async), returns per-item outcomes in input order under one
  deadline, and a failing item lands in its slot without aborting the
  rest. Tools declare `x-harness.effect` (`"read"` | `"write"`,
  default write): batch reads fill the concurrency cap together while
  writes run exclusively, so concurrent mutations are prevented by
  construction (per-target write overlap remains the deferred delta).
- **Durable background agent jobs** — `agent_spawn` starts a subagent
  and returns `{jobId, sessionId}` immediately; `agent_status` is a
  non-blocking durable lookup, `agent_wait` blocks until a terminal
  state, `agent_steer` injects a message into the live turn, and
  `agent_stop` cancels for real (llm.cancel side-channel plus a
  `__cancel` control message on the steer channel, honored at round
  tops; terminal records read `stopped`). Jobs are store-backed, so
  terminal state survives restarts and a late wait can't miss it,
  announced as `ev.agent.started`/`done`. Stale records reconcile
  lazily against the live catalog and the child transcript (missed
  completions synthesize from the transcript, dead runners record
  `interrupted`); lost stops re-arm once. Spawn accepts a `budgetMs`
  job budget (enforced lazily on observation with agent_stop
  semantics) and passes the subagent's reasoning effort through.
- **Agent lifecycle semantics** — fail-closed lineage (a lineage-store
  failure closes spawning instead of orphaning children), the original
  interactive caller propagates to child approvals, child LLM failures
  report as failures rather than successful text replies, and idle
  child runners retire on their own (`NIF_RUNNER_IDLE_S`).
- **Correlated fabric lifecycle events + UI activity strip** —
  `ev.fabric.started` / `call.started` / `call.done` / `done` on the
  bus, correlated by `runId` with bounded metadata; `started` fires
  only after admission and `done` carries real call counts, budget
  usage and component/result-byte sizes. The console renders the trace
  live, and the desktop UI surfaces fabric runs and background jobs as
  a compact activity strip without leaving the chat. Oversized-result
  artifacts (`var/fabric-artifacts/`) get retention sweeps at boot and
  per run.
- **systemprompt component** — the conversation constitution as a
  replaceable component: session runners ask `svc.systemprompt.call`
  once per conversation for the real system prompt (product prompt +
  the repo's AGENTS.md/CLAUDE.md chain); absent, slow or broken, core
  falls back to its minimal baked-in prompt. Replace the component to
  replace the constitution.
- **Bundled skill scope** — the repo's `skills/` tree ships with
  Niffler as a bundled scope in `skill_list`/`skill_load`, discovered
  even when NIF_ROOT differs from the repo, shadowable by
  project/home scopes and never removable via `skill_remove`.
- **`session_info` tool** — conversation self-introspection for the
  LLM: id, title, model selection, thinking effort, context window and
  token usage, plus message counts by role. Without a sessionId it
  answers about the current conversation (a session runner injects its
  own id); any other conversation id inspects that conversation.
- **`dialog` component — a component in pure bash** — the wire
  contract is the component: `components/dialog/dialog.sh` speaks
  envelopes with only the nats CLI and jq (no SDK, no compile step —
  `make build` copies it to `var/bin/dialog`). `dialog_show` pops an
  info/warning/error dialog on the user's desktop (zenity →
  notify-send → log fallback), `dialog_ask` asks a yes/no question and
  returns the answer (`yes`/`no`/`timeout`). Ships with `make build`
  but is not autostarted — spawn on demand via `core.spawn`
  (approval-gated). Prerequisites added to `make setup`/`make doctor`:
  natscli, jq, zenity.

- **Bench `niffler-expert` variant** — paired measurement of plain Niffler
  vs expert-assisted Niffler: the runner arms `expert_follow` on the exact
  task session before its first turn (setup excluded from time-to-green),
  records judgment/steer/acceptance/stale-drop counters plus judge tokens
  per result, and folds judge usage into the run totals. Judgments run on a
  separate cheap flash provider — `config.json → expertJudge`, default
  Synthetic `syn:small:text` (GLM-4.7-Flash), wired through
  `NIF_LLM_PROVIDERS` so the shared llm component reaches a second provider
  without touching the worker's. Raw run output moved from `bench/results/`
  to `var/bench/results/` (disposable runtime state; `make clean` wipes it,
  the committed record is `bench/reports/`); after `patch.diff` capture the
  runner strips each nested `.git` by default (`--keep-repos` opts back in),
  and workspace scanning ignores `**/var/**`, so completed tasks stay out of
  editor Source Control. `report.mjs` also gained a working `--latest`.

- **Harder benchmark task `t06-stackvm`** — a cross-file Go stack VM and
  assembler with missing opcodes plus seeded operand-order, jump,
  underflow, label-resolution and comment bugs. The base suite fails in
  milliseconds and a separately applied reference solution proves green;
  its end-to-end labeled loop exercises the runner's feedback rounds when
  an agent fixes only part of the contract.

- **Bench harness comparison framework** — `bench/run.mjs` orchestrates
  niffler/pi/opencode × model combos (deepseek-v4-flash, glm-5.3-flash):
  per combo it copies the pristine task repo, loops [agent turn →
  `test.sh` verify → feed failure back] and records time-to-green,
  provider-reported token usage and diff stats, with a protected-file
  guard marking test tampering invalid. The pi adapter isolates
  `PI_CODING_AGENT_DIR` (+ JSON mode, session JSONL usage), opencode runs
  `--format json --pure` (step_finish tokens), niffler gets a private
  NATS + isolated `NIF_ROOT` per model (blocking session calls,
  transcript usage). Five tasks (go/python/nim/node) are red at base and
  verified green with reference impls. SWE-bench Verified importer
  (`bench/swe/import.mjs`) downloads all 500 Verified task cards via the
  HF datasets-server API (no pip/parquet needed), and a task-level
  `verify` script gives the runner hidden-test mode: `test_patch` is
  applied only at verification time, so the agent never sees the tests.
- **SWE-bench Verified pilot** — the official evaluation path is wired
  into the bench runner end-to-end and proved on `sympy__sympy-11618`
  (no-op patch unresolved, dataset gold patch resolved; 3.92 GB official
  image, ~9 min first pull + evaluation, ~25 s cached):
  `bench/swe/setup.sh` bootstraps a Python 3.12 uv venv under
  `var/bench/swe/.venv` with the `swebench` harness pinned to 4.1.0 (the
  classic release with repo/version test specs and prebuilt
  `sweb.eval.*` images; 5.x cannot evaluate Verified's classic rows);
  `import.mjs` pulls task cards from the HF datasets-server API
  (`--repos`/`--limit` for subsets, gold patch + environment metadata
  included but kept outside generated agent repos); `prepare.mjs` turns
  cards into a `run.mjs` task root — per-task checkouts at exactly
  `base_commit` with no future refs (one shared git mirror, hidden
  gold/`test_patch` never exposed), official images pre-pulled;
  `verify.mjs` grades a candidate patch with the official Docker harness,
  applying `test_patch` only inside the disposable evaluator container.
  `run.mjs` gained `--task-root` for generated/custom task roots, a
  hidden-verifier feedback message, and `git add -N` so untracked files
  count in diff stats and the submitted patch. First pilot: 10 SymPy
  cards × niffler/pi/opencode, one-shot submissions (`--rounds 1`).

- **Expert advisory peer (`expert`)** — one expert follows one working
  session: a bounded current-turn observation built from `ev.session.*`
  events, a stateless LLM judgment over a cache-stable knowledge prefix
  (policy + non-hidden catalog hints, versioned), and fail-closed delivery
  through the new turn-bound `svc.session.<id>.advise` request/reply —
  accepted only while that exact turn is live, folded as a marked user
  message and announced on `ev.session.advice`. Core now emits
  `ev.session.turn` and correlates every session event with a `turnId`;
  `ev.session.toolcall` gained `callId`, start/done phases and a stable
  `errorCode`. Silent by default, approval-gated follow, best-effort
  scheduling (the working session never waits); `tests/t_expert.nim`
  proves the loop with a scripted mock llm. Cache economics are
  measurable from day one: the `llm` adapter forwards
  `prompt_tokens_details.cached_tokens`, core passes usage through, and
  `expert_status` accumulates judgment prompt/cached/completion tokens.

- **SDK result-convention helpers** — `okResult(extra)` / `errResult(msg, code, extra)`
  build the canonical `{ok, error}` tool-result shape (mirrored as
  `OK`/`Err`/`ErrCode` in the Go SDK and `okResult`/`errResult` in the TS SDK),
  and `comp.requestOk(...)` turns an `ok:false` reply into an exception so
  callers stop hand-rolling ok-flag chains. Components migrated off the
  hand-rolled `%*{"ok": false, "error": ...}` literals.
- **SDK session-subject + path helpers** — `sanitizeSessionId`,
  `sessionCallSubject`/`sessionSteerSubject`/`sessionToolSubject`,
  `resolveNatsUrl`, `rootDir`/`rootVarDir` (Nim: pure `sdk/subjects.nim`,
  shared by core like the envelope; Go `wire.go`, TS `wire.ts`). The
  sanitize-once rule now has a single implementation per language — previously
  copied in core, agent and fabric.
- **`comp.onDrain(handler)`** (Nim/Go/TS) — register cleanup callbacks for
  `ev.sys.drain` without hand-wiring an event subscription (store closes its
  barrel-db with it).
- **Subscription OAuth logins (ChatGPT Plus/Pro, Claude Pro/Max)** — the
  same PKCE flows Pi and opencode use: `provider_oauth_start` returns the
  authorization URL (browser login via fixed localhost callback ports, or
  OpenAI's device-code flow for headless machines; manual
  code/redirect-URL paste as fallback), `provider_oauth_complete` polls and
  exchanges the code, and the provider component owns refresh — tokens
  rotate transparently on read within 5 minutes of expiry and refresh
  tokens never leave the component. Providers gain `authType`, `protocol`
  and `expiresAt` fields; exports carry live refresh tokens.
- **Wire-protocol routing in `llm`** — providers now declare a `protocol`:
  `openai-chat` (default, unchanged), `openai-codex` (ChatGPT's Codex
  Responses endpoint with OAuth headers, message translation to the
  Responses API, SSE event mapping) or `anthropic` (Messages endpoint with
  Claude Code identity headers and tool_use/tool_result block
  translation). All three share the existing chat result shape, so core
  and UIs are unchanged.
- **Provider Manager OAuth UI** — subscription sign-in buttons (OpenAI
  browser/device, Anthropic browser) with live pending state, device-code
  display, manual-code fallback and OAuth badges on stored providers;
  an API-protocol selector for API-key providers; protocol-aware model
  defaults (`gpt-5.4`, `claude-sonnet-4-6`) and catalog ids.

- **UI: conversation controls at TUI parity** — slash commands (built-ins
  `/provider /model /effort /connect /status /new /session /think /tools
  /locale /help` plus the declarative plugin registry) with tab completion
  and did-you-mean hints, thinking and tool-card display modes
  (ctrl+T / ctrl+E), a colored context gauge (same 75%/90% thresholds as
  core), mid-turn steer, and a two-stage stop (arm, then force-cancel via
  `llm.cancel.<sessionId>`).
- **Per-conversation thinking effort** — `session {thinking}` accepts
  low/medium/high (empty clears, thinking-only calls run no inference),
  persists it in the conversation header and forwards it to the LLM as
  `reasoning_effort` (omitted for providers without support). The TUI
  cycles it with ctrl+g.
- **Session titles** — `session {title}` renames a conversation
  (rune-safe 48-char cap; title-only calls are valid); fresh
  conversations auto-title from the first user message's first line, so
  session lists are descriptive instead of `conv-<epoch>`.
- **Declarative slash-command registry** — components declare a `slash`
  section in reg.publish (`{name, description, tool, params[]}` with
  per-param completion sources); core validates it, exposes it in
  catalog snapshots and checkpoints the merged table to the store
  (kind `slash`) before `ev.catalog.updated`, so UIs read store-first
  and follow live. Both SDKs gain the registration API.
- **fabric component** — programmable tool calling via an embedded Nim
  VM (docs/research/FABRIC.md): the model writes a Nim program, a per-program
  executor (nimeval, RLIMIT-capped, no bus access) runs it, and every
  nested tool call re-enters the session proxy (approval, lease,
  budgets, audit). maxCalls budget, output cap with artifact fallback,
  compile errors surfaced as diagnostics, `ev.fabric.log` activity
  events, and worked examples the LLM reads as its documentation.
- **agent component** — subagent sessions via delegated child runners:
  `agent_run` prepares a child session runner (`session_prepare`),
  drives it mid-turn and returns its reply; a depth guard denies nested
  agents; the child transcript is inspectable via the returned
  sessionId. Hybrid fabric programs can call `agent_run` mid-program.
- **Nested-call proxy + session leases** — `svc.session.<id>.tool` is
  pumped from dispatch's idle slot so nested calls (fabric programs,
  subagents) re-enter the one dispatch gate (approval, required-args
  validation, per-tool timeout); `x-harness.sessionContext` injects
  `{session, lease}` and stale leases or hidden/chat/invoke targets are
  denied fail-closed.
- **edit component** — the file-tools component: `read` (plain, pageable,
  verbatim content for old_string), `write` (atomic whole-file, merged
  from the former write component) and `edit`/`undo_last_edit` with a
  guarded fallback cascade for near-miss old_strings (trailing
  whitespace, indentation drift, unicode punctuation folding, block
  anchors with Levenshtein similarity, double-escaped text),
  `replace_all`, and lenient input shapes — ambiguity always stays a
  hard error, fuzziness only rescues not-found.
- **git component** — read-only repo inspection: `git_status`/
  `git_diff`/`git_log`/`git_show`/`git_blame` over fixed argv (never a
  shell), paths scoped to the harness root, ~40KB caps with narrowing
  hints; mutations stay in bash.
- **UI locales** — typed en/zh/zh-TW catalogs (missing keys fail
  typecheck), auto-detected from `navigator.language` and cycled via a
  header button; bilingual website and zh/zh-TW docs.
- **Network mirror knobs** — `NIF_GIT_MIRROR` rewrites the plugins clone
  host (CNB/Gitee mirrors), `NIF_NPM_REGISTRY` overrides the registry
  for TS-component builds (docs/MANUAL.md).
- **Component manifest defines** — `niffler.json` entries may list
  `defines: ["ssl", ...]`, appended as `-d:NAME` (identifier-whitelisted,
  so defines can never inject flags or shell) by builder and plugins.

- **Minimal boot profile** — `./var/bin/niffler --minimal` starts only the
  `store`, `bash`, and `llm` manifest services, using `NIF_OPENAI_*` directly
  without the `provider` or `models` components. Core/NATS and on-demand
  session runners still operate normally. Persisted agent-added components
  stay stopped without their records being deleted, and a later normal boot
  restores them. `--minimal` composes with `--recover`; covered by the core
  bus-contract test.
- **Progressive tool discovery** (docs/MANUAL.md, "Progressive tool discovery") — the catalog stays
  complete, but each conversation freezes a small immutable *direct*
  toolset into its LLM prompt (13 shipped tools: core `discover`/`invoke`,
  bash, store get/list, grep/files, write, hashline read/replace/
  undo_last_replace, skill_list/skill_load). Everything else is on demand
  (`x-harness.onDemand`) or hidden (`x-harness.hidden`): `discover`
  returns deterministic hints and full schemas as ordinary tool results
  (append-only, so provider prompt caches stay valid), and `invoke` calls
  any live non-hidden tool through the normal approval/timeout path —
  including components registered after the conversation started.
  `catalog {op: list}` and `ev.catalog.updated` are now the direct
  projection; `{op: snapshot}`/`{op: components}` remain complete.
  Exposure state persists per conversation (`<sessionId>:tools` store
  document) and drives the UI Live Components panel (direct/seen/demand/
  internal). Covered by `tests/t_discover.nim`.
- **Directed approval routing** — approval requests now route to the
  component that is driving the turn instead of a global broadcast: call
  envelopes carry a self-declared `caller` (all four SDKs), and when a
  session turn raises an approval the request goes to that component's
  private subject `svc.approval.<caller>.request`. The driver acks it
  (`{id, ack: true}` — a human is being asked) and later answers
  `{id, ok}`; a missing ack within ~1.5s rebroadcasts on
  `ev.approval.request {fallback: true}` to any interactive client, and
  direct (non-session) calls broadcast immediately. Core publishes
  `ev.approval.resolved {id, ok}` when a verdict lands so every client
  dismisses stale modals. The web UI acks + answers on its private
  subject, and `observe`'s known-event list covers the new subjects; a Go
  SDK test pins the envelope `caller` round-trip (legacy caller-less
  envelopes still parse with an empty caller).
- **Developer source-counting helper** — `scripts/cloc-niffler.sh` runs `cloc`
  over the maintained Nim, Go, TypeScript, Svelte, and web sources while
  excluding generated/build/runtime paths.
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
  model catalog over the bus (docs/MANUAL.md, "Model catalog"): embedded offline seed,
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
- **Interactive provider/model/context control** — provider adds now return
  redacted summaries; hidden `provider_status`, `provider_active`,
  `provider_get`, and secret-preserving `provider_update` support safe
  clients, with `ev.provider.changed` invalidations. Hidden `llm_resolve`
  reports the effective provider/model/context and provenance without
  credentials, resolves stored nicknames for explicit provider pinning,
  and chat results identify the provider that answered. Session calls
  accept and persist a conversation model override (including model-only
  configuration calls with no inference), resolve its context before the
  guard, pin both provider and model across tool rounds, and publish
  `ev.session.status`; conversation headers retain provider/model/context
  and total-token occupancy for resumed context meters.
- **Multi-file Go plugins** — component manifest entries can list additional
  same-package `.go` `sources`; plugin installation validates confined,
  non-symlink paths and the builder compiles the files together. This keeps
  substantial interactive components modular without bypassing the normal
  source-build/install path.
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
- **UI: provider/model controls** — the desktop header now shows the
  active provider, conversation model, and live context occupancy. A
  provider switcher popover (stored providers + environment fallback),
  a searchable model picker backed by `models_list`, a provider
  management drawer (add/edit/remove with credential-safe forms), and
  a context meter (`used / window`, color-graded at 75/90%) compose the
  header. State is owned by `App.svelte` and refreshed by
  `ev.provider.changed`, `ev.models.updated`, and `ev.session.status`.
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
  (`bash`, `builder.build`, `core.spawn`/`kill`/`remove`) require a human
  before executing: a y/N prompt in the terminal harness, or a caller-directed
  web UI approval (`svc.approval.<name>.request`, with
  `ev.approval.request` broadcast fallback and `ev.approval.resolved` cleanup).
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

- **`expert` judgment economics tuned from bench evidence** — the initial
  pass raised `EvalCooldownMs` 2000 → 8000 and pinned policy to harness usage,
  but the six-task matrix still spent 32–40 judgments per model lane and
  emitted 14 mostly generic "read/run tests" steers. The scheduler now waits
  for an actual tool-call start (completion enriches the same evidence; this
  preserves time to advise while the tool runs) or ≥80% context pressure,
  caps each turn at two judgments, and stops after accepted advice; validation requires
  a non-empty live `tools` array whose exact names appear in backticks in the
  message. Task-strategy examples are explicitly always-silent.
  `expert_follow` also gained a `provider` override (`NIF_LLM_PROVIDERS`
  nickname or stored provider) so judgments can run on a cheap flash model
  off the worker's bill; `expert_status` reports it. A focused DeepSeek
  confirmation run (report `expert-grounded-bfbb81b`) then verified the
  retune on t01/t04/t06: 3/3 pass in one round with exactly two judgments
  per task and 6/6 silence, zero steers — direct expert usage fell from
  75,081 tokens (17 judgments on the same tasks in the earlier matrix) to
  17,657, a 76.5% reduction, while preserving the correct silence
  behavior.

- **`tool` macro accepts an x-harness argument** — `comp.tool(%*{"approval":
  "always", "timeoutMs": 60000}): proc ...` replaces the ~45
  `comp.tools[^1].schema["x-harness"] = ...` post-registration pokes; the
  low-level `comp.tool(name, schema, handler, xharness)` form gained the same
  optional parameter.
- **`sdk/procutil.nim`** — one implementation of the process-with-timeout
  runner (`runCmd`, `runArgv`) with the temp-file capture that avoids osproc
  pipe deadlocks and the peekExitCode poll-kill (osproc's `waitForExit(timeout)`
  SIGKILLs and returns 137 itself), plus output capping (`capBytes`,
  `capLines`, `tailBytes` with UTF-8 boundary snapping). bash, grep, git,
  builder, plugins and skills now share it; skills' local `tail` copy had
  silently lost the UTF-8 snap.
- **edit absorbs read + write; hashline-edit moved to a plugin** — the
  whole file surface lives in one component; the write component is gone
  (t_edit covers the merged tools) and hashline anchors ship as the
  niffler-hashline plugin (install via plugins; `replace`/
  `undo_last_replace` stay onDemand for large block moves).
- **System prompt leads with the capability ladder** — an explicit
  discover+invoke → plugin install → skills → bash ordering, so models
  stop hand-rolling curl for missing capabilities and reach for the
  ecosystem first.
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

- **Benchmark token accounting and Pi/GLM wiring** — Niffler now reads
  OpenAI-compatible `prompt_tokens_details.cached_tokens` and normalizes
  counters to the same disjoint shape as Pi/OpenCode (`total = uncached input
  + cache read/write + output`) instead of hiding cache hits or double-counting
  them; reports show total tokens explicitly. Pi's GLM-5.3-Flash lane now sets
  `thinking: low` because the gateway rejects Pi's default `off`; the invalid
  six-task lane was rerun and replaced with a documented 6/6 correction.

- **systemprompt: context files deduped by file identity, not path** — a
  symlink farm (the bench harness re-exposes the repo root inside its runtime
  dir) made the same AGENTS.md reachable twice in one ancestor walk, so every
  bench conversation carried its standing instructions twice. Dedup via
  `getFileInfo` id; identical content from different paths now counts once.

- **Codex reasoning summaries no longer run together** — the
  Responses API streams reasoning summaries as one delta per step
  title with no separator, so consecutive headings glued into one
  run-on blob in the transcript; llm tracks the summary index and
  inserts newlines between items (fallback break for backends that
  keep the index constant).

- **Tool-call reasoning survives the round trip** — core persisted the
  provider-neutral `reasoning` field, but the OpenAI wire expects
  `reasoning_content`, so thinking models (deepseek-reasoner) 400'd the
  next request ("The `reasoning_content` in the thinking mode must be
  passed back"). The llm adapter now maps stored `reasoning` back to
  `reasoning_content` on replay, and a tool-calling round is persisted
  as one assistant message (content + reasoning + tool_calls) *before*
  its tool results, instead of a contentless call entry persisted after
  them.
- **Long answers are no longer cut off by the provider's server-side
  cap** — neither adapter set a max-token budget, so the provider's
  default cap (often 4K–16K) stopped long answers mid-stream with
  `finish_reason=length` and the turn ended, making the TUI appear to
  stop until nudged. llm now resolves the model's `limit.output` from
  the models catalog (generous 32K fallback) and sends it as
  `max_completion_tokens` on every call (surfaced via `llm_resolve`);
  llm-openai sends `max_tokens=32768`.
- **Vendor-prefixed model ids no longer break gateways** — gateways
  like devpass route on the canonical id and reject ids like
  `alibaba/glm-5.2`; providers gain a `stripPrefix` option (set in
  `provider_add`/`provider_update`) that sends the bare model id.
- **Truncated tool-call arguments repaired on replay** — a session
  poisoned by a truncated stream 400-bricked every later turn on strict
  backends; core neutralizes garbled assistant tool_calls in the
  persisted history and the llm adapter completes/repairs arguments
  before sending.
- **Console survives bus loss** — `natsSubscription_NextMsg` fails
  instantly once the connection is closed (nats.c abandons its
  reconnect budget after ~2min of unreachable server), and the follow
  loop treated every error as continue — a console left open across a
  harness restart spun at 100% CPU. Idle timeouts are the normal path;
  any other error closes and retries every 2s, re-reading bus discovery
  so the console follows a harness restarting on a new port.
- **Session status keeps its own fields** — `resolveTurnConfig`'s return
  was assigned over the status literal, dropping sessionId,
  thinkingEffort and the token counters from the reply and
  `ev.session.status` (the ctrl+g effort selector never saw its
  selection echoed); invoke's unknown/hidden error message stays
  identical and name-free (existence-oracle leak).
- **Client flag survives catalog reseeding** — a fresh core's snapshot
  reseed lost `reg.client`, so child session runners computed zero
  interactive clients and their fallback approval routing denied every
  request; the snapshot op carries `reg.client` through.
- **Clashing tool registrations refused entirely** — a reg.publish whose
  tools collide with another component's used to have the colliding tool
  silently dropped, leaving a component that shows installed but does
  nothing; the whole registration is now refused. `invoke` also accepts
  `component.tool` spellings (the namespace stays flat).
- **zai/glm 'reasoning' stream field captured** — go-openai only parses
  `reasoning_content`, so every thinking delta from glm-family gateways
  streaming `reasoning` was silently dropped: no reasoning reached
  `ev.session.token` and ctrl+t had nothing to toggle. The stream loop
  reads both field names (regression-tested via a fake SSE server).
- **UTF-8-safe truncation + rune-aware tty backspace** — byte-window
  truncation now snaps to UTF-8 boundaries so CJK runes are never split
  into invalid UTF-8 (which would poison JSON envelopes downstream), and
  the tty admin shell's backspace deletes a whole character.
- **Supervisor surfaces child death cause; no silent backoff drop** —
  child stdout/stderr go to `var/logs/<name>.log` (an unread pipe
  swallowed crash messages) and pump() reports exit code + log tail when
  a child dies; a child dying twice in a row was nil'ed during its
  backoff window and never restarted again. `make down` stops stray
  harnesses, components and nats-server.
- **nimble task parser fixes** — backticks/hyphens in task names and
  descriptions broke `nimble install -d` for every plugin CI that
  bootstraps Niffler's dependencies (natswrapper/bitbarrel were never
  installed).
- **plugin_search relaxes zero-hit queries** — GitHub repo search ANDs
  space-separated words, so natural-language queries returned zero hits
  even when a matching package existed; the search now retries by
  dropping the last word, then sweeps single words, reporting every
  attempt and the winning query.
- **Complete Makefile component build** — `make build` now includes the shipped
  `skills` and `fetch` binaries, matching `niffler.nimble`, the manifest, and
  their bus-contract test targets.
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
- **Docs** — MANUAL (operating guide), ARCHITECTURE (why core is core),
  WIRE (protocol), AGENTS (working guidelines), README.
