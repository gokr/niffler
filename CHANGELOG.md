# Changelog

All notable changes to Niffler are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims for [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A conversation's runner answers while it waits for a human approval.**
  `askHuman`'s wait loop used to pump nothing: a session call that arrived
  while a turn sat at an approval prompt went unanswered — not even the
  instant "busy" refusal a tool dispatch gives — until the approval timed
  out (300s default), which read as a hang and left the caller's deadline to
  expire. The approval wait now pumps the same idle surfaces a dispatch wait
  does (core's `svc.core.call`, a runner's busy/cancel/steer/advice/nested
  surfaces), a `__cancel` control aborts the wait as a denial so a stop lands
  promptly, and nested approval questions (reachable through those pumps) are
  denied immediately instead of opening a second blocking wait inside the
  first — the human can answer one modal at a time.
- **Turn cancellation also aborts a concurrent tool-call wave.** The
  single-call dispatch had the cancel-abort path (publish `cancel.<component>`,
  short grace for a partial reply, `TurnCancelled`); a wave of parallel tool
  calls ran out its timeouts instead. The wave loop now marks the remaining
  calls cancelled and returns, so the round boundary ends the turn as
  cancelled instead of waiting on dead work.
- **Stale interactive clients are swept from the catalog.** External clients
  (TUIs) have no supervisor to match their pid, so a hard-exited TUI — a
  `/restart` successor, a killed terminal — left its `tui-<hex>` entry
  registered forever. The system catalog now checks client pids for liveness
  every 30s and drops the dead ones, which also keeps `clientCount` (and the
  autostarted core's shutdown) honest.

- **TS components resolve their dependencies from their own imports — no
  build parameter, and TS plugin packages became installable.** The builder
  generated a fixed `package.json` (`nats` + `niffler-sdk`), so a TypeScript
  component that needed a third-party parser had nothing to resolve against —
  `import { Project } from "ts-morph"` could never build. Go never had that problem
  (`go mod tidy` reads the imports out of the source), so the fix follows the
  same shape instead of asking the caller for a dependency list: after the base
  npm install the builder scans the entrypoint with TypeScript's own
  `preProcessFile` (comments and strings cannot fool it), npm-installs the
  external packages it finds (relative paths and `node:` builtins skipped,
  ≤32, names whitelisted before they reach an argv), and the resolved ranges
  land in the generated `package.json` — so the component's imports are the
  whole declaration, and it is visible in the same approval payload as the
  source. The reply lists what was installed under `deps`. The plugins
  manifest reader also accepts `"lang": "ts"` now, which previously made TS
  packages uninstallable: `plugin_install` builds the entry through the
  builder and spawns it like any other component.

### Fixed

- **manual `/compact`: the context gauge reflects the compaction immediately.**
  A commit zeroes the measured prompt size on purpose — the new projection has
  not been through a provider yet — and the gauge reads `usedTokens` from a
  status frame, so after `/compact` it kept showing the pre-compaction number
  until some later turn happened to measure the smaller prompt. (The automatic
  path never showed this: the compaction happens inside a turn, and the very
  next request re-measures.) The manual path now publishes a status frame with
  the local estimate — `usedTokens`, the window, `reason: "reset:compact"`,
  `generation`, and `estimated: true` so nothing pretends it was measured — and
  the next request's measured usage replaces it. A *declined* compaction
  publishes nothing, so the gauge can never show a size for a compaction that
  did not happen. The UI notes it (`context compacted — the size shown is an
  estimate until the next request re-measures it`), localized in all three
  languages. `t_compaction` asserts the frame, its fields, and the decline's
  silence; the MANUAL documents the frame under `/compact` (EN + both zh).

- **A stop during LLM retry backoff waited out the whole delay.** The
  transient-failure backoff was a plain `sleep`, so a `__cancel` queued
  unread for up to the maximum backoff. The wait is now sliced and pumped, so
  the cancel flag is raised within a quarter second and the retried dispatch
  aborts itself.

- **lsp: scope is a bound, not an equality — work outside the workspace is no
  longer refused.** `hLsp` refused any path outside the conversation workspace
  (`E_LSP_SCOPE`), which an agent hits constantly: sibling checkouts, git
  worktrees, a second repo. Worse, the edit tool's diagnostics push swallowed
  that refusal as "no server configured for this extension" — a whole session of
  edits in a sibling clone (`~/git/niffler` from a conversation whose workspace
  is `~/git/nifflerprod`) produced zero diagnostics and zero signal. A file
  inside the workspace keeps the workspace root (warm servers reused); a file
  outside it is indexed under its own marker-derived root
  (`deriveRootUnbounded` — a worktree roots at its own top, where `.git` is a
  *file*), and the reply names it in `workspaceRoot`. `E_LSP_SCOPE` survives for
  the two cases that matter: a `..` component, and a marker walk that reaches
  `/` or `$HOME`. The edit tool now also reports the out-of-scope refusal when
  it does happen, instead of going silent.
- **config.nims declares the local SDK path.** The Makefile and nimble tasks
  pass `--path:sdk`, but `config.nims` is what everything *else* reads — a bare
  `nim check components/x/main.nim` and every language server driving
  nimsuggest. Without it `import niffler/sdk` failed and the fallout was ~100
  phantom "undeclared identifier" errors: querying
  `components/recall/main.nim` in-workspace returned 110 diagnostics / 103
  errors, all cascading from `cannot open file: niffler/sdk`. Attached to an
  edit, that is worse than no diagnostics — the model would chase errors that
  do not exist. `nim check` with no flags is now clean.
- **core: an empty provider reply no longer ends a turn as if it were an
  answer.** A round that returns HTTP 200 with no content *and* no tool calls
  was accepted as the final reply, so the turn ended with `""` and the caller
  saw a silent no-op — in the Multilingual-10 bench one cell (vuejs/core-11739)
  burned 29 minutes that way and surfaced only as `candidate patch is empty`,
  indistinguishable from a bad patch. Two shapes now diverge by
  `finish_reason`: `length` (the provider cut the reply at the output cap
  before any content — a thinking model can spend the whole budget on
  reasoning) ends the turn with an explicit error; anything else is re-asked up
  to `NIF_EMPTY_REPLY_RETRIES` (default 2) times *invisibly* — nothing is
  appended, so the frozen prefix and its cache are untouched, and the model is
  never told (a provider hiccup is not its mistake). Exhausting the retries
  ends the turn as `turnError` and persists a `role: error` record with
  `error: "empty-reply"`, so drivers and the bench see an infrastructure
  outcome instead of a capability failure.
- **bash: the 60s ceiling is gone.** The tool's schema pinned
  `x-harness.timeoutMs` to 60_000 while every other tool gets the harness's
  120_000 — so a slow build was killed by *core* (which discards the output
  captured so far) and no `timeoutMs` above 60s could take effect. The call
  wait is now 600_000, the command budget defaults to 120_000 and is capped at
  570_000, i.e. the component's own timer always fires first and reports
  `exit 124` *with the output so far*; both messages name the two real options
  (`timeoutMs`, `run_in_background`). The description also stops implying that
  `cd`-ing to the workspace is the way to work there: the shell already starts
  in it.
- **recall: `context_recall` is on-demand, not hidden.** It was registered
  with `x-harness.hidden: true` while every prune/trim notice tells the model
  to call it with the ref verbatim — and a hidden tool is invisible to exactly
  that caller (`discover` never lists it, `invoke` refuses it: "tool is not
  available through invoke"). Dropped history was reachable only by reading
  the store directly. It is now `onDemand` + `sessionId` (the runner injects
  the conversation), which keeps the two properties that matter — out of the
  frozen direct set, behind an explicit discover+invoke — and makes the
  notices' advice actionable. Covered by a new `tests/t_recall.nim`, which
  asserts the registered flags (this shipped broken because the component had
  no test at all).
- **bench: a cell can no longer fetch the upstream fix unnoticed.** The first
  rerun on the new stack had carbon-3005 (PHP) flip fail→pass by fetching
  `https://github.com/briannesbitt/Carbon/pull/3005.diff` — a SWE-bench
  instance is derived from a merged upstream PR, so its gold patch is public
  (it also crawled the maintainer's issue pages). The prompt's
  knowledge-isolation rule was collateral damage of the previous change: the
  old "do not fetch anything from the network" covered it, and its replacement
  only forbade hunting for the hidden tests. The task prompt now says it
  directly — the issue text is the only specification; do not look up the
  upstream project, its issues, pull requests or patches — while keeping the
  compile/existing-tests permission the earlier edit was actually after (and
  dropping the now-duplicated wording from step 3). Prompt rules are not
  enforcement, so the pipeline records it too: `transcriptShape` collects every
  external URL a cell reaches (fetch invokes, and `curl`/`wget`/`git clone`
  bash commands; loopback ignored) as `leaked`/`leakUrls` in `result.json`,
  `run.mjs` warns per cell, and `report.md` marks the row `⚠LEAK` with a
  per-combo count and a CSV column. Limit, stated so nobody over-trusts it: it
  sees tool-level web access, not a compiler downloading modules.
- **ctx: the admission reserve is the model's declared output cap, and the
  llm adapter clamps the completion at dispatch — the provider-side overflow
  both layers had to agree on.** Providers count the requested `max_tokens`
  against the window at admission, but core held back a fixed 16K while the
  catalog declared DeepSeek's output as 384K: a 736,803-token prompt plus
  the 384,000-token completion overflowed the provider's 1,048,576 limit
  while the prompt alone fit the harness's 1M window — and overflow recovery
  re-admitted the candidate against the same wrong target, so the retry was
  byte-identical and refused again. Core now carries the resolved
  `limit.output` (`llm_resolve` already returned it): `outputReserve(p)`
  uses it, the admission target becomes `window − declared output` (floored
  at half the window), and the 75% warning tracks that effective line;
  `NIF_CTX_RESERVE` still overrides and 16K remains the unknown-model
  default. `llm`'s `fitOutput` independently clamps the requested output to
  the headroom the serialized prompt leaves (messages plus frozen tool
  schemas), so neither layer's estimate can push a fitting prompt over the
  provider limit (`448a6e9`; `t_ctx_accounting`, `components/llm/main_test.go`).
- **retry: failure budgets are split by kind, and a timed-out tool keeps its
  partial output.** A hinted 429 is safe to wait out indefinitely, but a
  stream timeout may already have billed output and a refused local connect
  is cheap: `RetryPolicy` gains `maxStreamRetries`/`maxConnectRetries`/
  `retryAfterCapMs` (defaults 2/2/1h, tunable per budget with
  `NIF_LLM_MAX_STREAM_RETRIES`, `NIF_LLM_MAX_CONNECT_RETRIES`,
  `NIF_LLM_RETRY_AFTER_CAP_MS`) and `RetryKind` classifies each failure. The
  partial tool output a timeout produced is preserved in the error record
  instead of discarded (`060b5d1`, `9bbe3e8`; `t_retry_unit`).
- **core: session calls are forwarded asynchronously, so one slow turn no
  longer blocks another conversation's call.** A session call used to block
  core's `svc.core.call` pump for the whole turn; concurrent requests (a
  second UI saving its model) were stashed in `ct.pending` until the first
  turn ended and timed out behind it. Each call now routes on a private
  inbox and completes from the pump's idle slot — different runners make
  progress concurrently while a runner still serializes its own
  conversation (`17ed5b3`; regression in `t_core`).
- **agent: queued turn events are applied before the busy cache is read.**
  The SDK drains the call binding before the `ev.session.turn` tap, so a
  tool call arriving just as a child turn finished could read the child as
  still busy — `agent_ask` queued an answer that was already available, and
  a steer could be published into a subscription that no longer existed and
  silently lost. The taps are now pumped (bounded) before `liveTurns` is
  read, the pattern `requestChildTurn` already used (`5f40e71`).
- **web UI: a conversation's model pin is dropped when the provider moves.**
  The pin was chosen under one provider, so a switch that moves the backend
  clears it and the newly active provider's default applies — the pinned id
  may not exist there. Re-selecting the already active provider keeps the
  pin. Mirrors the TUI behavior (`0f98251`).
- **plugins: refless installs update from their clone's branch, and a
  branch-pinned install is never repointed at a release tag.**
  `plugin_update` refused with "no tracked branch ref to pull" for
  `file://` installs made without an explicit ref; it now reads the
  checked-out branch from the clone and records it. Separately, a package
  installed at a branch (the user asked to track main) was removed and
  reinstalled at the newest tag on first update whenever main was ahead —
  a silent downgrade; the tag move now requires the recorded ref to
  actually name a tag (`2488938`, `28fcb07`).
- **install-lsp: the summary counts only servers this run actually
  installed.** `ok()` bumped the "newly installed" counter on the
  already-present branches too, so a fully provisioned host re-reported
  "11 newly installed" while having installed nothing. `ok` now means
  verified and `new` means installed now, and the line also reports the
  available count the listing finds (`727212c`).

- **lsp: a configured-but-unrunnable server both reported "ok" and wasted a
  warm slot.** `install-lsp.sh` only checked for a JRE on the branch where
  `jdtls` was *missing*, so a present jdtls wrapper with no `java` on `PATH`
  installed cleanly and then died on every query (`FileNotFoundError:
  'java'`) — and because warmup pre-starts a workspace's most prevalent
  languages, the dead server also held one of the two warm slots for the whole
  conversation. Java now gets a runtime: `install-lsp.sh` verifies JDK 17+
  whenever jdtls is used and installs a user-local JDK 21 under
  `~/.local/share/niffler-lsp/jdk` (sudo-free, like the server downloads).
  The version probe was itself part of the bug: grepping the first number out
  of `java -version` reads the *shell's* error line ("line 206: java: command
  not found" → 206 ≥ 17), so a missing runtime parsed as a modern JRE; it now
  matches a real `version "NN"` field.
- **lsp: servers can declare the runtime they need (`requires`), so a missing
  one is reported instead of spawned.** jdtls declares `java`, csharp-ls
  declares `dotnet`. `warmup` lists them in `skipped` ("jdtls (needs
  'java')") and a query fails fast with `E_LSP_UNAVAILABLE` — no process is
  started that can only die, and no warm slot is spent on it.
- **edit/git: the read tools declare the effect they have, so fabric stops
  serializing read-only batches.** `read` and `git_status`/`git_diff`/
  `git_log`/`git_show`/`git_blame` were registered `parallel: true` with no
  `x-harness.effect`, and the default is `write` — the batch host ran them one
  at a time, leaving the concurrency cap idle for the whole tool. The only
  write `read` can make is a correction to the per-file seen-state it owns
  (losing one is a hint loss, never a correctness loss); `review_receipt`,
  which stores receipts, deliberately stays a write.
- **edit: the `write` description builds its cap from the knob that controls
  it.** It hardcoded "Cap 900KB" while `NIF_WRITE_MAX_BYTES` overrides the real
  limit, so a lowered cap produced a tool whose own description lied.
- **lsp: `NIF_LSP_BIN_DIRS` entries are tilde-expanded.** The list was split
  on `PathSep` and used verbatim, so the `~/...` form the MANUAL documents
  never matched a server. A leading `~` now means the user's home.
- **lsp: `..` is refused in the argument as given.** `resolvePath` joins with
  `/` and Nim *normalizes*, so `../hidden.nx` reached the scope check already
  rewritten to `<root>/hidden.nx` and the call answered `E_NOT_FOUND` — a path
  the caller was never allowed to name reported as absent. The refusal now
  runs on the raw argument first; absolute paths outside the workspace stay
  allowed (scope is a bound, not an equality).
- **web UI: deleting a conversation goes through core's
  `conversation_delete`.** The SPA trimmed raw `store` records by hand: it
  could not stop a live runner (which resurrects what it writes) and left the
  `sessionmeta` lineage and durable `agentjob` rows behind. One approval-gated
  core call does what core's own control does.
- **Makefile: a multi-file component rebuilds when its sibling sources
  change.** `var/bin/lsp` listed only `components/lsp/main.nim`, so editing
  `roots.nim` rebuilt nothing and `make test-lsp` silently ran the previous
  binary (found while gating the tilde fix). `NIM_SRCS`/`GO_SRCS` are
  wildcards — a hand-written list rots the same way — `_test.*` is filtered out
  (only the test target compiles it), and `var/bin/test_t_lsp` depends on the
  component sources it imports.
- **tests: `t_recall` now reads `reg.publish` for what it is, and passes.**
  The announcement carries the registration object itself, not an envelope, so
  the test's `payload`-based drain captured nothing and the three assertions it
  exists for — `context_recall` is registered, `onDemand`, and `sessionId`, the
  ones that keep the trim/prune notices' advice actionable — never ran. It also
  waited on a subscription opened *after* the spawns (announcements are
  fire-and-forget: recall announces while store is still opening its database),
  and the resulting nil reached a `check` detail, where `$` on a nil JsonNode
  dereferences — so the run ended in SIGSEGV rather than a report. Both
  announcements are read off the pre-spawn subscription now, parsed as JSON,
  with guarded details. (`t_recall` never passed; `make test-recall` is green.)

### Added

- **Workspace set: a conversation knows the trees that belong to its project.**
  `core/workspace.nim` answers the question every path-scoping component was
  answering on its own: primary workspace, plus its linked git worktrees
  (`git worktree list --porcelain`) and sibling checkouts of the same
  `remote.origin.url` — including a sibling cloned from a local path, whose
  origin *is* that path. Mostly best-effort: no repo, no git, a weird remote →
  just the primary. Injected for tools that declare the workspace policy as
  core-owned private context `__workspace = {root, roots}`, cached on the
  nested state (a ref, so it survives `CoreTools`' by-value copies) and
  **never** rendered into the frozen prompt or a tool schema — worktree
  awareness is data for dispatch and components, so a worktree appearing
  mid-conversation widens what components accept without invalidating a
  conversation's cache. First consumer: `lsp`, which indexes a file inside a
  declared root as that tree (its own server instance) instead of deriving a
  root or refusing. Tested hermetically against real repositories
  (`tests/t_workspaces.nim`).

- **edit→lsp diagnostics are asynchronous (`svc.session.<id>.diag`).** An edit
  no longer waits for a language server: it asks the `lsp` component with
  `{async: true, session, first, last}` (fire-and-forget, acknowledged
  `pending`) and the check runs in the component's idle seam — a cold
  rust-analyzer/jdtls legitimately needs minutes. The rendered result is
  published on the conversation's `.diag` subject when the server answers (or a
  one-line note when it cannot), and the runner drains it (`pumpDiag`) and
  appends it as append-only history, exactly like the repo-map `.map` lane:
  never the frozen prefix, newest text per path wins so five edits to one file
  cost one message. The Multilingual-10 run paid **39 blocking 25s waits (~16
  minutes) that all answered "server busy or still indexing"** — repeated cost
  for no information, because "ready" meant the process had started, not that
  it had indexed. Range scoping moved into the lsp component with it
  (structured, off the parsed diagnostics instead of re-parsed text), and
  `components/edit/diagformat.nim` plus its unit test are gone with the inline
  renderer.
- **`context_recall {mode: "search"}` — grep the conversation's whole history.**
  A ref answers "give me *that* document"; nothing answered "which messages
  mentioned X?" once a trim had dropped them from the projection (a trim names
  only an id range). The new mode scans the canonical `message` documents,
  including trimmed/compacted-away ones, and returns bounded one-line hits
  (`{id, role, seq, snippet}`, default 20, `role` filter, case-insensitive and
  matching the whole record so a hit inside tool-call arguments is found) whose
  `id` is then a valid `canonical` ref for `mode: "full"` — hit list first,
  bodies only for what matters, since pulling a dropped span back wholesale
  would re-inflate the window that was just trimmed.

- **The manual in Chinese.** `docs/MANUAL.zh.md` and `docs/MANUAL.zh-TW.md`
  are complete translations of `docs/MANUAL.md` (identical section headings,
  links and table shape; the translation banner says AI-autotranslated). The
  READMEs link them, and they link back to English/Simplified/Traditional, so
  the whole manual is now reachable in all three languages.
- **Manual `/compact` reports the real refusal and keeps its model identity.**
  A live 67%-full conversation had hundreds of legal cuts, but the auxiliary
  summary hit the old 2048-token output cap (`finish_reason: length`). Core
  collapsed that invalid/truncated candidate into “compactor declined or no
  permitted cut,” falsely blaming cut eligibility. The shipped compactor now
  recognizes length truncation as the stable `summary-output-truncated`
  decline, manual controls return structured failure detail, and the default
  summary cap is 4096. Auxiliary summaries also inherit the parent
  conversation's resolved provider/model instead of following a mutable global
  provider switch.
- **Manual compaction: `/compact`.** Runs the conversation's replaceable
  compactor on demand — a verified checkpoint replaces older history, with
  no LLM turn and no user message — instead of waiting for the automatic
  pressure ladder. The core control is a content-less session call
  (`{sessionId, compact: true}`, trigger `"manual"`) answering
  `{compacted, beforeTokens, afterTokens, generation}` or an explicit
  decline (no compactor configured / compactor declined / no permitted
  cut); a decline never silently falls back to lossy trim. The web UI
  exposes it as a builtin slash command; the TUI ships its own `/compact`
  in niffler-tui (`448a6e9`; `t_compaction`, `t_controls`).
- **agent: subagents v2 continues — the autonomous wake, delegation depth,
  keyed leases, durable mail and `agent_ask`.** Follow-ups to the
  settlement-notice entry above:
  - **Autonomous wake (`fc770e3`)** — a background child settling while its
    parent was idle left an `agentnotice` nobody read until the human
    spoke again. The agent component now publishes a fire-and-forget
    `session {wake: true}`; `ensureRunner` spawns the parent's runner on
    demand and the runner admits the wake only when `NIF_AGENT_WAKES`
    (default 3) consecutive wakes are unspent, pending notices exist, and
    wakes are enabled. The budget is derived from the stored wake-marked
    messages, so it survives runner restarts; the human's next message
    resets it. An admitted wake appends a notice-marked user message,
    drains the notices and runs one normal turn — the parent conversation
    moves on its own and the request prefix stays append-only. A declined
    wake persists nothing and the notice stays pending for the pull lane.
    A notice that lands during a live turn holds that turn open one more
    step so it cannot close over a child that just finished (a burst folds
    in one drain; `NIF_AGENT_NOTICE_HOLD=0` restores the previous timing),
    and niffler-tui renders folded notices and wake prompts as dim
    machinery rows instead of dropping the event.
  - **Delegation depth cap + keyed nested leases (`f1ef4c2`)** — recursion
    is bounded by a depth cap, and the nested-call proxy's leases are keyed
    so an outer program's tool lease survives an inner `agent_run`.
  - **`agent_ask` and durable parent mail (`34e8433`)** — `agent_ask
    {session, question}` returns a continuation's answer (idle child:
    directly, activation ledgered; mid-turn: queued as durable mail and
    delivered at the child's next turn top). `agent_steer` to an
    idle/retired child used to vanish into a subscription nobody drained;
    between turns it now queues on the same mail lane. Mode-sensitive task
    wording (fresh/fork/continuation) and the delegation-scope statement
    (approvals belong to the parent's human, budgets are fixed at start, a
    denial is a reported limitation, never retried) land in both tools'
    schemas, first turn only.
- **web UI: the SPA joins the UI lease registry.** The browser UI now
  registers with core's UI registry alongside the TUIs (one identity per
  tab, minted by the bridge and kept in `sessionStorage`), so mixed TUI/web
  setups coordinate instead of silently sharing a conversation. The header
  shows the registry's display number; opening a held conversation reports
  the holder by number and offers a fresh conversation instead; the ~20s
  lease renews every 5s, a claim lost while frozen moves the tab to a new
  conversation, `beforeunload` releases best-effort, and registry outages
  degrade to the legacy broadcast approval path (`794f062`;
  `uiRegistry.test.mjs`).
- **core: `/export`** — `session {sessionId, export: true}` returns the
  exact provider request the next turn would send (messages, tool schemas,
  model, provider, `reasoning_effort`) with no user message, LLM call or
  store write; built in lockstep with the `llmArgs` construction so the
  dump is faithful for reproducing a request (`87b14bf`).
- **read: a whole read of a large file returns the lsp outline.** A whole
  read (no explicit `offset`/`limit`) of a file above
  `NIF_READ_OUTLINE_LINES` (default 1000, 0 disables) asks the lsp
  component for `documentSymbol` and returns the outline — every symbol
  with kind, name and one-based position — plus window pointers (12 ranges
  per call) and the `offset=1` dump-anyway escape hatch. Language-agnostic
  (the registry is data; every failure falls back byte-identically to the
  normal content read), the outline delivers no bytes so the conversation's
  seen-state is preserved, and a per-call budget of 2 outlines bounds
  batch latency. Live: a 1277-line file costs 4.1KB instead of ~45KB of
  content (`0e3e070`).
- **plugins: the component registers a slash surface.** `/plugins`,
  `/plugins-search`, `/plugins-install`, `/plugins-update` and
  `/plugins-remove` are registered (namespaced by component name, bound to
  their tools), so UIs can list and manage packages through the normal
  approval path instead of hand-calling the tools (`111b971`).
- **systemprompt: deterministic prompt slots (`prompt_hint`).** Components
  and plugins can register prompt fragments into named slots
  (`efficient_tools`, `after_instructions`, …) through a hidden
  `prompt_hint` tool; contributions sort by source/key and a repeated
  key replaces its own contribution, so the same registrations always
  compose the same prompt. Registration affects only prompts composed
  afterwards — frozen conversations are never rewritten (`a506618`;
  `t_systemprompt`).

- **lsp: Ruby and PHP language servers** — `solargraph` (`.rb`, `.rake`,
  `.ru`, `.gemspec`) and `intelephense` (`.php`, `.phtml`) are now built-in
  registry entries, and `install-lsp.sh` installs them (intelephense via npm,
  which needs no PHP runtime on the host; solargraph via a user-local gem, and
  when Ruby itself is absent the failure names the install, like the .NET
  path).
- **lsp: warmup picks by cost class instead of raw extension count.** A
  workspace's languages are censused as before, but *cheap* servers (those
  that index nothing — bash-language-server) no longer compete with the
  language the task is written in for the heavy-server budget: heavy picks are
  capped by `NIF_LSP_WARM_MAX` (2), cheap ones by `NIF_LSP_WARM_CHEAP` (1,
  and only from 2+ matching files), and `NIF_LSP_WARM_TOTAL` (4) ceilings
  pre-started processes per workspace. Before this, a repo full of `.sh` files
  routinely spent one of the two slots on bash-language-server.
- **bench: cell checkouts no longer rewrite the task repos' symlinks.**
  `prepareRepo` used Node's `cpSync(..., {recursive: true})`, whose default
  resolves symlink *targets*: terraform's ten relative links (testdata
  roundtrip states, the plugin-protocol `.proto` files) landed in the cell as
  absolute paths, and since the cell's `base` commit holds the originals,
  `git diff base` recorded every one of them as a change the agent never made.
  That is patch noise at best and a spurious `invalid` verdict (tests passed,
  protected files touched) whenever such a link sits under a test path; it hit
  8 cells across the Multilingual runs (terraform 10 hunks, jekyll 8, plus
  axum/php-cs-fixer/jq). `verbatimSymlinks: true` keeps the original links.
- **bench: three tooling bugs that each silently invalidated or killed a run.**
  The SWE-bench importer wrote a hardcoded column list, dropping
  `eval_script`/`eval_type`/`image`/`log_parser` — and `verify.mjs` routes on
  `eval_script` to pick the 5.x harness venv, so imported SWE-bench Multilingual
  cards graded under the classic 4.x path instead. `--pull-images` invoked
  swebench's `prepare_images`, a *builder*: pointed at Multilingual rows it
  built base/env images from Dockerfiles (base images are not published) and
  died on a dead `mvnd` download for the Java rows. It now pulls the card's
  `image` ref — exactly what `run_evaluation` does at grading time — and falls
  back to the builder only for cards without one (SWE-bench Verified). The
  niffler adapter also inherited `NIF_AUTOSTART=1` from the caller, so driving
  the bench from inside a Niffler session made the private harness treat itself
  as UI-autostarted and exit after the 60s boot grace, stranding the run's
  `cli call session` children on a dead bus; the adapter now pins it off.
- **bench: the private bus was capped at the NATS default 1 MiB payload.**
  Core warns about this at boot and it bites exactly where it hurts — a long
  SWE transcript whose tool output exceeds 1 MiB cannot be published and the
  turn dies. The adapter now spawns its `nats-server` with
  `--max_payload 8388608`, matching what core spawns for its own bus.
- **DeepSeek turns can no longer be silently length-capped or silently
  interrupted.** DeepSeek's Chat Completions reference documents only
  `max_tokens`; the llm adapter sent `max_completion_tokens`, which is ignored
  there, so the server default applied — 8K non-thinking, 64K thinking, 128K at
  effort `max` — and a long agent turn ended truncated at
  `finish_reason: "length"`. The adapter now picks the field the provider
  honors (`lengthCap`), turns an interrupted generation (`aborted`,
  `insufficient_system_resource` — delivered as HTTP 200, so they used to read
  as successful turns) into a transient `stream error` the retry policy acts on,
  logs truncation, and carries `finish_reason` on the result; the Anthropic
  (`max_tokens`) and Codex (`response.incomplete`) lanes normalize into the same
  vocabulary. `core/retry.nim` no longer classifies every "insufficient" as
  billing: a *resource* interruption is retryable, while "insufficient
  balance/funds/credit/quota" stays permanent. Survey, verified facts and the
  remaining backlog live in `docs/research/DEEPSEEK.md`.
- **web UI: persisted error and system records no longer render as user
  speech.** `Chat.svelte`'s history loader mapped every role that is not
  `tool` or `assistant` to `user`, so a turn failure stored as role `error`
  (round/token budget, limit, abort) reappeared as a user bubble on reload,
  and runner notices (a trim without summary) looked like something the human
  typed. Error records use the transcript's error block; system/meta records
  use the meta block.

### Changed

- **edit: the read batching nudge is gone.** The hint taught the
  windows-era shape; under the canonical reads shape the full30 run showed
  0/17 post-nudge conversions while every batch was spontaneous pre-nudge,
  and the tool description already teaches batching. The bench's
  transcript-shape metrics now count canonical read arrays with more than
  one item (the run's batches had been invisible: recorded 0, re-scored
  readSingle=74 / readBatch=4) (`2e2d3dc`).

- **Prompts: change-scope discipline, and the SWE task prompt no longer
  forbids running tests.** Three graded cells (terraform-35543 twice, fmt-1683)
  lost on the same thing: a fix for the issue at hand that altered behavior on
  a neighbouring path, or that left one of the paths producing that behavior
  untouched. Two places now say so. The base prompt gains one clause — "Keep
  changes scoped: leave behavior you were not asked to change exactly as it
  was, and cover every path that produces the behavior you do change —
  regressions hide on shared code paths" (+187 bytes, ~47 tokens; pinned by
  `tests/t_systemprompt.nim`) — and the generated SWE task prompt states the
  same rule as step 2 instead of asking for "the minimal correct fix", which
  was the wrong lever: terraform's failing patch was a third the size of the
  gold one (+108/−11 across 4 files vs 377 lines across 8).
  The task prompt also stops forbidding test runs, because that rule was
  unenforceable prose — the agent's own `go build` fetched Terraform's
  dependencies mid-turn (module zips stamped inside the cell's window) — and
  the graded tests are hidden regardless. It now says why they are hidden (do
  not try to find, recreate or guess them; never modify tests), permits
  compiling or exercising a small repro, and keeps the rule that is actually
  checkable: no added or vendored dependencies. Self-testing stays
  machine-dependent until deps are provisioned per task; the task prompt's
  instruction block grows 701 → 1005 chars (~76 tokens).
- **Session round guard default raised from 50 to 1000.** The hard
  `NIF_MAX_TURN_ROUNDS` runaway guard remains configurable and separate from
  the soft `/limit` controls.
- **Docs lead with the terminal client, and the Makefile grows `install-ui` /
  `install-tui`.** The README quick start now builds components only and
  installs the `niffler-tui` plugin (`make install-tui` = `make install
  WITH_TUI=1`); the desktop UI is documented as optional (`make install-ui`,
  alias of the existing `ui-install`, builds the Wails UI and adds the
  launcher entry + icon).

### Added

- **bench: pricing for the direct DeepSeek endpoint** (`deepseek-v4-flash` →
  `api.deepseek.com/v1`), where provider rates are the first-party list rates,
  so reports carry cost columns instead of blanks.
- **bench: repomap append-gate evidence — the Multi10 low A/B rerun and the
  full30 gate verification.** The first low A/B was invalid twice over (lane B
  DNS-dead, lanes on different trees); rerun on a matched tree with
  `NIF_REPOMAP_AUTOAPPEND` as the only knob (publish counts verified ON 10 /
  OFF 0): **ON 10/10 vs OFF 9/10 at 0.46× the tokens per cell** (166k vs
  362k) — the high-thinking probe's sign inverted. The swing again lives in
  jq and redis; the other eight cells are near-flat in both regimes. The
  full30 gate verification then ran all 30 tasks with append forced on and
  gates live: **30/30 workspaces withheld** ("workspace below census floor"),
  0 published — the ungated-ON lane's +41% prompt tax (34.5k vs 24.1k tokens)
  is gone by construction. Default stays opt-in. Reports:
  `bench/reports/repomap-ab-multi10-low.md`,
  `bench/reports/repomap-gates-full30.md` (`3f9f3e1`, `6bd1247`).

- **repomap append admission gates.** The workspace-open auto-append (still
  opt-in via `NIF_REPOMAP_AUTOAPPEND=1`) now admits a map only when it is
  worth injecting (docs/research/REPOMAP-GATES.md): a **size floor** —
  workspaces under `NIF_REPOMAP_MIN_CENSUS` (default 50) covered source
  files are never mapped, decided from the census before any tag parsing —
  and a **content gate** — a rendered map below `NIF_REPOMAP_MIN_BYTES`
  (800), `NIF_REPOMAP_MIN_SYMBOLS` (25) or `NIF_REPOMAP_MIN_FILES` (5) is a
  stub and is withheld. Withheld maps log `repo map withheld ... (reason)`,
  so bench artifacts show which gate fired. The `repo_map` tool path is
  never gated: a small map is a fine answer to an explicit question, just
  not worth injecting unasked. Thresholds are calibrated from the bench
  stores' published maps (stub class 4-9 symbols / 1-4 files / <3.1KB;
  healthy 59-119 symbols / 19-48 files / 3.5-4.6KB) and all four are
  env-overridable.

- **docs/research: FAST-APPLY survey.** `docs/research/FAST-APPLY.md` surveys
  the "fast apply" edit families across the harness shelf — whole-result
  generation, deterministic cascades, merge providers, repair tiers — with
  per-harness positions cited from their checkouts (Claude Code cited from its
  compiled binary; no source exists). It ends where Niffler's edit 0.3.0 sits
  and names the three supported steals: candidate-line ambiguity errors, a
  repair tier behind the existing hook seam, and an opt-in fastapply plugin
  component for merge providers — never core. Also records that cited code
  lives in the sibling clone shelf `~/git/harnesses/` with its own
  pinned-commit index (`6832e76`, `0e094ee`).

- **repomap: c/cpp/rust/ruby tiers — complete language coverage.** The
  Multi10 A/B exposed the gap: jq/redis/tokio/rubocop all fell outside the
  .nim/.go/.py/.ts/.js tiers and got tiny or empty maps. Vendored
  tree-sitter-c v0.23.4, -cpp v0.23.4, -rust v0.23.2 and -ruby v0.23.1 (MIT;
  NOTICE.md updated); census, grammar map, query map, dispatch and the
  Makefile rebuild list grew `.c/.h` → c, `.cpp/.hpp/.cc/.hh/.cxx/.hxx` →
  cpp, `.rs`, `.rb`. Aider's c/cpp queries are definitions-only (aider
  backfills refs with pygments at runtime) and the graph needs refs, so
  call-expression ref patterns were appended (rust/ruby already carried
  refs). Verified on the real Multi10 repos — rubocop 1149 tok, redis 911
  (real C now), jq 1070, fmt 1036, tokio 920, all full-strength; fixture
  coverage for the four tiers (54 checks green, was 45) (`aba88b8`).

- **Background processes report their exit to the conversation that owns them,
  and the SDK grows the seam that makes it possible.** A `run_in_background`
  child (or a direct `process_start`) that finishes now publishes an exit
  notice — `kind: "process-exited"` on the same `svc.session.<id>.steer` lane
  subagent settlement notices use — which the runner folds in as append-only
  history (`[background process p3 (dev-server) exited(code 0)] ran 412s,
  8123 bytes of output — read it with process_poll …`). It is a pointer: the
  output stays in the spool, the command text never travels.

  Why it was needed: nothing reaped a child except a tool call, so an exit was
  invisible until someone happened to poll — a build or watcher that finished
  while the model was busy went unnoticed. The reap is now periodic, via a new
  SDK seam `onIdle(intervalMs, handler)` invoked from the pump loop between
  passes (main thread, serialized, one handler per component); `processes` uses
  it, which also stops `process_list` from reporting a finished child as
  `running` until asked. `process_list` entries carry `started_at` for
  client-side age displays. Design + the pointer discipline: docs/WIRE.md
  "Settlement notices", docs/MANUAL.md "Background processes".


- **Conversation controls: `/approvals`, `/limit` and the keep-going question.**
  Two controls now belong to the human, per conversation, set through the
  `session` call (the SPA exposes them as slash commands; any bus client can
  call `session` directly) and persisted in the conversation header so a
  resumed runner re-applies them:
  - **`approvals`** (`""`/`"ask"`/`"auto"`) — this conversation's gate mode.
    `auto` grants every `x-harness.approval` tool without asking any client,
    loudly (`core: approval auto-granted for <tool>`); the default gates as
    before. Chosen by the human, never by the model.
  - **`limits`** (`rounds`/`tokens`/`seconds`) — SOFT turn budgets. Reaching
    one no longer ends the turn: core asks "keep going?" over the existing
    approval transport (`tool: "turn-limit"`, `purpose: "continue"`,
    `args: {dimension, detail}`), and a yes extends that limit by one step.
    A no, no answer or no reachable human ends the turn with a distinct
    `limit-<dimension>` error record naming the limit and the command that
    raises it. The seconds limit is checked before every tool dispatch, not
    just at round boundaries. Job-scoped budgets (`maxRounds`/`maxCalls`/
    `maxTokens`, what `agent` freezes into a subagent) and
    `NIF_MAX_TURN_ROUNDS` stay HARD and never ask — a subagent cannot
    negotiate its own budget. `NIF_AUTO_CONTINUE=1` answers yes with no human.
  A session call with only a `sessionId` is the read-only status readback
  (it echoes `approvals` and `limits`). Contract, routing and the fail-closed
  rules: docs/WIRE.md "Conversation controls"; user-facing chapter:
  docs/MANUAL.md.
- **A mid-turn session call is refused with `busy`, not left hanging.** The
  session runner is single-threaded and a turn never nests, so a session call
  arriving mid-turn was simply unanswered until the turn ended — any client
  with a deadline gave up first and reported a generic "context deadline
  exceeded" (this is why `/export` looked broken during a long turn: it waits
  10s). The runner's own call subject is now pumped from dispatch's idle slots
  and answered at once with `{code: "busy"}` and "the conversation is
  mid-turn — retry when the turn finishes", the same contract `agent_run`
  uses for a mid-turn child (tests/t_controls.nim).

- **prompt+skills: Niffler can explain itself (`c262a87`).** Asking about
  Niffler — features, operating, configuring, extending, debugging — now
  routes through the bundled skills instead of guesswork: `baseprompt`
  gains a trigger to `skill_list` (query `"niffler"`) + `skill_load` the
  matching `niffler-*` skill before answering, and `niffler-harness` gains
  a docs map (`docs/MANUAL.md`, `docs/WIRE.md`, `docs/ARCHITECTURE.md`,
  `docs/research/`, repo-root `AGENTS.md`/`CHANGELOG.md`) so one skill
  owns the doc routing. Out-of-root workspaces learn the harness root via
  the per-conversation `<workspace>` tail — the frozen head stays
  path-free, and two conversations on one machine share the same root, so
  provider prompt-cache prefixes still line up — so reading
  `<root>/docs/MANUAL.md` needs no discovery round-trip. The skills
  component bakes the bundled SKILL.md files into the binary as a
  last-resort discovery source when no bundled tree is reachable (disk
  always wins by name; baked entries report source `bundled`, dir
  `(baked)` and no resources), so binary-only sandboxes keep the
  self-knowledge set; `NIF_SKILLS_BUNDLED_DIR` relocates the bundled tree,
  and pointing it at a path that does not exist is the explicit way to
  force the fallback. `skill_list`'s docstring now names the
  bundled/baked sources and the Niffler routing, and `docs/MANUAL.md`
  gained the baked row, the env var and the `<workspace>` tail. Tests:
  `t_skills` (bundled skills discoverable/loadable with a disk tree *and*
  from the compiled-in copies alone — bundled dir unreachable — incl.
  `skill_audit`'s baked-only rows and unaffected project/home/config
  discovery), `t_systemprompt` (workspace tail carries the root; in-root
  prompt stays path-free).
- **agent: subagents-v2 — settlement notices, the child roster,
  continuation and fork.** Four steps landed from the
  `docs/research/SUBAGENTS-PLAN.md` runbook, closing the gaps the DSH
  comparison named:
  - **Settlement notices (P0.1, `2911074`)** — a finished background child
    now reaches the parent conversation without polling. The agent
    component records a durable `agentnotice` record first
    (`{parent, jobId, child, status, summary?, replyBytes, fullReplyIn}`,
    id `<parent>:<zero-padded seq>`) and delivers it second; the notice is
    a POINTER to the reply the agentjob record already holds, never the
    reply, so a model told "your subagent finished" also learns that
    `agent_status` returns the byte-identical full text (`fullReplyIn`).
    Delivery is two-lane by parent state: mid-turn it rides
    `svc.session.<parent>.steer` as a structurally marked user message
    (never a bare "Steer: "); otherwise it pends and the parent's next
    turn drains it at the top alongside steer and advisories — the model
    never has to poll. `agent_notices {session?, peek?}` is the manual
    drain. Best-effort throughout: an unreachable store costs a notice,
    never a turn.
  - **`agent_list` (P0.2, `fbea052`)** — the derived child roster:
    `agent_list {scope?: "children"|"descendants"}` joins
    `sessionmeta.parent` with agentjob records and one catalog read for
    residency; nothing new is persisted. `status` (running | idle |
    ready — storage only, never terminal) and `lastStatus` (how the last
    activation ended) are deliberately separate questions.
  - **Continuation (P1.3, `a54129d`)** — `agent_run`/`agent_spawn` accept
    `session` to give an existing child another turn instead of minting a
    fresh one per delegation. Authorization is the durable lineage
    relation (`sessionmeta.parent == caller`) and every failure refuses
    explicitly, fail-closed; a mid-turn child REFUSES `agent_run`
    (`code: "busy"`) but queues under `agent_spawn`. Frozen controls
    belong to the child — a continuation sends content only, so the
    cached prefix survives — and `close: true` retires the child after
    its turn.
  - **Fork (P1.4, `f3338f5`)** — `fork: true | {"lastK": n} |
    {"maxChars": n}` seeds a fresh child with the CALLER's completed
    turns, so the model has read the discussion instead of being told
    about it. The copy is a contiguous-from-0 replay-valid prefix
    (two-pass cut: provider-validity walk, then turn blocks) — never a
    dangling `tool_call_id` — and a selection that drops everything fails
    closed. Fork + `session` is refused: a fork is a birth, not a
    continuation.
  - Children also inherit the parent's effective model unless an explicit
    `model` override is given, instead of silently falling back to the
    provider default (`ac14d02`). Tests: `tests/t_agentnotice.nim`,
    `t_agentcont.nim`, `t_agentfork.nim`; WIRE.md gains the notice
    record, continuation and fork contracts; MANUAL.md documents the new
    tools.

- **lsp: `documentSymbol` and `workspaceSymbol` — the file outline and
  repo-wide symbol search as the sixth and seventh operations.**
  `documentSymbol` (`62e5374`) returns every symbol in a file with kind,
  name and one-based position (anchored at the name token), depth-indented
  for nesting; hierarchical `DocumentSymbol[]` is primary, the deprecated
  flat `SymbolInformation[]` form is handled too. `workspaceSymbol`
  (`a5a2dca`) sends a fuzzy `query` to the server's own in-RAM workspace
  index and renders the flat result cross-file, one-based,
  workspace-relative — no indexing code of ours; the first call after
  warmup may need a retry while the index builds. Both are
  capability-gated like every other op, capped at `MAX_LOCATIONS` with a
  pointer for the tail, and still one tool: new enum values, never new
  registrations. Live-verified on nimtortoise and pyright;
  `tests/fixtures/lsp_server.py` and `t_lsp` cover both forms.

- **lsp: nimtortoise is the Nim default; jdtls and csharp-ls join the
  defaults; `make install-lsp` is per-language.** The default registry now
  maps .nim/.nims to nimtortoise (nimlangserver additionally never
  publishes diagnostics for loose files; nimtortoise answered
  clean/hover/broken in the live sweep and nimlangserver stays selectable
  by name), adds jdtls (.java) and csharp-ls (.cs) — an absent binary
  stays a clear `E_LSP_UNAVAILABLE` (`3ad367c`). `scripts/install-lsp.sh`
  is reworked: Go, Nim and TS are mandatory (Niffler is built from those),
  every other language is a y/n prompt with default yes, `--all` (`make
  install-lsp ALL=1`) installs unattended for CI, and runtimes a server
  needs (JDK 17+, .NET SDK 8+, cargo) are named in the failure message,
  never auto-installed. jdtls resolves the newest build via
  snapshots/latest.txt and tsserver.path is pinned to the classic TS5
  install (`e285a05`); csharp-ls is pinned per .NET SDK major and dotnet
  errors are surfaced instead of swallowed (`7f8c28d`).

- **core: `/doctor` self-test fan-out — components check themselves, the
  report renders as Markdown and can be interpreted.** The doctor was a
  read-only core-side probe; now every component that registers the
  standard hidden `selftest` tool is asked to check itself and its
  per-check results land in the report (`8ab8c78`). Input
  `{deep, default false}` — quick stays cheap (no spawns, < ~10s), deep
  runs live end-to-end probes and may take minutes; a timeout is a failed
  check, not a crash; components without a selftest are reported as not
  implementing it, never as broken. The standard selftest name is exempt
  from the global tool-uniqueness refusal (it exists on every implementing
  component by design and is addressed per subject). The lsp selftest is
  the flagship: quick = registry loads + every configured server's binary
  resolves; deep = boots each server against throwaway fixtures. The
  report also carries a rendered Markdown table in `text` (what `/doctor`
  displays), and `ask: true` adds a `userMessage` per the WIRE.md
  convention so the client submits an interpretation request as a user
  turn — core stays a read-only health provider (`109a544`).

- **compaction: contract-v1 conformance runner (`make test-conformance`).**
  `tests/t_compaction_conformance.nim` runs any implementation against the
  compaction contract — `--bin:`/`--tool:` point it at a third-party
  component, the suite default proves the shipped one (`f5bd958`). The
  runner now rejects candidates claiming more auxiliary LLM calls than
  `maxLlmCalls` grants (provenance is the enforceable boundary; the
  fixture gains `NIF_FIXTURE_LLM_CALLS` to simulate an over-budget
  component), and negative cases are closed in `t_compaction`: a
  concurrent projection writer wins the optimistic commit (foreign record
  untouched, trim rung still completes the turn), and a real steer
  published during compaction folds after settlement, stays outside the
  cut, and reaches the post-compaction provider request.

- **docs/research: subagent and harness studies.** `SUBAGENTS.md` — the
  `agent` component vs DSH's subagent subsystem, tool by tool;
  `SUBAGENTS-PLAN.md` — the phased P0–P4 runbook the subagents-v2 work
  above follows; `OPENHANDS.md` — the Agent Canvas steal list;
  `MAKI-STEAL.md` — the Maki investigation (`7b9202b`, `69b87c0`,
  `30b1699`).

- **make down-here** — the scoped variant of `make down`: stops only this
  checkout's harness, components and spawned bus, pinning every kill by
  process tree + NIF_ROOT env + executable path (`scripts/down-here.sh`,
  with `--dry-run`). The global `down` stays for the stray-everything case;
  `down-here` leaves bench worktrees, other clones and their private buses
  alone.

- **background processes (`processes` component + bash `run_in_background`).**
  bash is synchronous by design; servers, watchers and test loops need a
  different contract: start once, poll incremental output, kill explicitly.
  `process_start` spawns the command detached (own process group, stdin from
  /dev/null, stdout/stderr appended to spool files under `var/processes/`)
  and returns an id immediately; `process_poll` drains output appended since
  the last poll (never re-injects old bytes; `waitMs` blocks for new output
  or exit, `filter` regex over the new lines, `tail` re-reads the raw
  ~64 KB tail); `process_kill` stops the whole group; `process_list` shows
  the registry. Spool files are the drain buffer — the child writes
  append-mode, the component reads from per-stream cursors, so the OS
  absorbs bursts (`NIF_PROCESSES_SPOOL_CAP` truncates an oversized spool to
  its tail, `NIF_PROCESSES_POLL_CHUNK` splits bursts). Crash-safe: children
  are process-group leaders, so a SIGKILLed component leaves them running —
  `registry.json` (pid + /proc starttime, defeating pid reuse) drives a boot
  sweep that kills orphans from a previous life before serving. Caps: 32
  concurrent processes, 50 finished entries kept. All four tools are
  onDemand; `process_start`/`process_kill` approval-gated, polls read-effect.
  bash's `run_in_background` flag is a thin producer: it forwards to
  `process_start` and returns the id (no timeout applies); without the
  component it answers `[E_BACKGROUND]` and suggests the synchronous path
  (`tests/t_processes.nim`).

- **store: SQLite becomes the default engine — boot guard,
  `niffler-store-migrate`, list cursor, full-kind paging.** The default of
  `NIF_STORE_BACKEND` flips from `barrel` to `sqlite` (atomic doc+rev write,
  range-readable list). Switching does not move data: core now refuses to
  boot over an un-migrated `var/barrel-db` with conversation history and
  prints the migration instructions instead of opening an empty
  `var/store.db` and looking like every conversation vanished.
  `niffler-store-migrate` (`var/bin`) moves a root between engines offline —
  it starts its own private NATS + store processes, reads every document
  over the bus contract (any engine pair works, including TiDB), replays
  into the fresh target and verifies per-kind counts; `--scan`/`--all`
  cover sibling clones and bench trees, `--dry-run` works with `--all`.
  Verified on a real 43 MB barrel (4309 documents). `list` gained an
  `after`/`hasMore`/`nextAfter` cursor contract across all three engines,
  and core's full-kind reads page through it (`storeListAll`) because a
  single capped list silently truncated long transcripts on resume.

- **context compaction — long turns survive their own context
  (`compaction` component, `context_recall`, durable projections).** Every
  provider request is now admitted against the model window first; when
  pressure hits, a deterministic ladder runs instead of failing: lossless
  prune of oversized tool results (originals stay recallable), then a
  summarization compaction attempt, then whole-turn trim, and only then an
  explicit `context-recovery-required` error — never a silent over-window
  request. Provider `context-overflow` errors are classified by code
  (`context-overflow: …; window <N> tokens`) and get exactly one
  receipt-backed recovery attempt. Compaction is replaceable: the runner
  owns budgets, cut boundaries, strict candidate validation, checkpoint
  rendering (`checkpoint-v1`) and the optimistic `context_projection`
  commit/reload, while a contract-v1 component (default:
  `compaction_propose`, override `NIF_COMPACTION_TOOL`) only chooses cuts
  and drafts the checkpoint via bounded auxiliary `llm.chat` calls
  (`cancelId`/`emitTokens`/`purpose` keep them out of the live turn's
  token stream and cancel path). Canonical messages stay immutable and
  append-only — prunes become executable refs, oversized bash captures are
  promoted to durable spill documents, and the hidden `context_recall`
  tool resolves canonical, spill and checkpoint refs. A restart reloads
  the committed checkpoint plus the retained tail or fails loudly;
  `tests/compaction_contract/fixture.nim` proves a second compactor
  implementation meets the same contract. Knobs:
  `NIF_COMPACTION_TOOL` (empty disables summarization but keeps the
  deterministic guard), `NIF_COMPACTION_TIMEOUT_MS`,
  `NIF_COMPACTION_MAX_LLM_CALLS`, `NIF_COMPACTION_MAX_SUMMARY_TOKENS`
  (docs/research/COMPACTION.md; `tests/t_compaction.nim`,
  `tests/t_ctxcompact.nim`).

- **make install-lsp + lsp warmup.** `make install-lsp` (`scripts/install-lsp.sh`)
  idempotently installs the language servers behind the lsp component's
  built-in defaults (gopls, pyright, typescript-language-server + tsserver,
  rust-analyzer, clangd, nimlangserver, bash-language-server); failures are
  non-fatal per language (the lsp tool skips it with `E_LSP_UNAVAILABLE`).
  The lsp component gained a `warmup` operation: a bounded extension census
  of a workspace (stops at 5000 files or 2 s) that pre-starts servers for
  its most prevalent languages — core fires it automatically on
  `ev.workspace.opened` so the first real query does not pay server startup.
  `readFrame` now honors the caller's full operation deadline instead of
  giving up after the first silent 250 ms pump slice (servers that run a
  lint subprocess or index a big module legitimately stay silent longer), and
  `E_LSP_TIMEOUT`/protocol errors append the server's last stderr line so
  the message names the actual failure. bash-language-server joins the
  built-in defaults.

- **nats bus safety.** A PATH `nats-server` fallback (hand-compiled dev
  runs) now gets the same 8 MiB payload cap as the bundled build via a
  generated config file — the official binary rejects `--max_payload` as a
  flag but honors it from `-c`; without it a stock 1 MiB bus makes oversized
  publishes time out instead of failing loudly, indistinguishable from a
  component hang. Core also reads `natsConnection_GetMaxPayload` at boot and
  warns when an attached foreign bus caps below the harness's 8 MiB, and
  `reclaimOwnNats` verifies `/proc/<pid>/comm` is nats-server before
  signalling a recorded pid (a recycled pid after a crash is no longer
  signalled; un-verifiable falls back to the safe yield-and-isolate path).

- **bench: SWE-bench Multilingual pilot (10 tasks, 7 languages) — Go
  (caddy, gin), Rust (tokio, nushell), C (redis, jq), C++ (fmt), JS
  (axios), TS (docusaurus), Ruby (rubocop); real OSS repos, real
  issue→PR diffs.** The dataset embeds eval specs (`eval_script`/`image`/
  `log_parser`), which the pinned swebench 4.1.0 cannot evaluate — setup.sh
  now builds a second venv (`.venv-multi`, swebench 5.0.2) and verify.mjs
  routes datasets carrying embedded specs there automatically (dropping the
  5.x-removed `--cache_level`/`--clean` flags), while classic Verified rows
  stay on 4.1.0. Both paths validated: SymPy cell re-graded resolved under
  4.1.0; Multilingual gold-patch run (jq-2235) resolved under 5.0.2.
  import.mjs gained `--dataset`; tasks live in `var/bench/swe/tasks-multi/`
  via `prepare.mjs --input var/bench/swe/tasks-multi.jsonl`. First run —
  `swe-multi10-dsv41-high` (DSV4.1 Flash, `--thinking high`, niffler/pi/
  claudecode lanes, official 5.x grading): **6/10 / 6/10 / 6/10 official**
  (pi 5/10 self-reported; its gin patch resolved despite the agent's own
  fail verdict). Perfect cross-lane agreement on 9 tasks; caddy-6115,
  fmt-1683, jq-2235, tokio-4384 unsolved by every lane. pi burned the
  60-min turn budget on tokio (empty patch, 268k output tokens) — the
  high-thinking profile is costly through pi's OpenAI dialect.

- **bench: full30 re-run on the optimized stack (niffler-only, GLM low,
  baseline protocol) — 30/30, avg 48s / 20.5k prompt tokens / 5.3 turns
  vs baseline 63s / 38.9k / 7.3 turns: prompt volume −47%, time −24%,
  turns −27% at an unchanged pass rate; run cost $0.046 at GLM catalog
  pricing. The gain is the accumulated tool work — change preview (zero
  post-edit re-reads), grep slash-glob fix, result caps — plus the review
  rubric, now all on one commit. Report:
  `bench/reports/full30-synlarge-low-niffler-report.md`.

- **lsp: language-server seam — one tool, registry is data.** A `lsp` tool
  (diagnostics without a test run, goToDefinition, findReferences,
  goToImplementation, hover) over any configured stdio language server, per
  the dsh/Octo analysis in `docs/OCTOFRIEND-STEAL.md`: transient
  didOpen→request→didClose per query, one instance per (server, workspace)
  with poisoned-state teardown, one-based-model → zero-based-UTF-16-wire at
  the boundary, findReferences always includes the declaration, capability
  checks, result caps, structured `[E_LSP_*]` errors, workspace confinement.
  The registry is data (`$XDG_CONFIG_HOME/niffler-lsp/servers.json`, defaults
  for gopls/nimlangserver/tsserver/pyright/rust-analyzer/clangd/bash-LSP):
  adding a language is a config entry or an approval-gated `lsp_registry add`
  the agent makes itself — never code (AGENTS.md invariant:
  language-agnostic core). Tools are onDemand (discover/invoke); the
  baseprompt names lsp among the discoverable capabilities. Read-only
  `lsp_servers` lists the merged registry with provenance for pickers.
  Fixture-tested (24 checks: position conversion, includeDeclaration,
  capability refusal, diagnostics settle, instance reuse, live
  registry add→query→remove; `48b31a4`, `c6d3c93`, `3a4f933`). niffler-tui
  gains `/lsp` — server browser, add/edit form (built-ins open as overrides),
  two-stage delete — approval-gated saves, full i18n (`44a5a82`, `747c848`).
  Manual chapter: docs/MANUAL.md "Language servers (`lsp`)" (`85a9836`).

- **bench: DeepSeek V4.1 Flash on Synthetic (`syn-deepseek-v41`).** Synthetic
  serves `hf:deepseek-ai/DeepSeek-V4.1-Flash` on both the OpenAI-compatible
  and Anthropic-compatible endpoints (the latter returns real thinking
  blocks); `reasoning_effort` accepted. Niffler/pi/claudecode lanes wired to
  SYNTHETIC_API_KEY. Cost uses Synthetic's published model catalog (0.8/1.2/
  0.16 per M, writes at the prompt rate — see the pricing correction below;
  the earlier 0.15/0.6/0.003 figures were borrowed LLM-Gateway rates, i.e.
  DeepSeek's off-peak list, and undercounted ~5-50x depending on cache mix).
  First run — Sym10, one-shot, `--thinking high`, official Docker grading:
  **niffler 10/10** (first perfect
  pilot score; 13091 solved, previously unsolved by every GLM lane; 13031 in
  392s vs 851-1122s) vs **claudecode 8/10** (11618, 13091). Catalog-priced:
  niffler $0.81 run, claudecode $1.37. Report:
  `bench/reports/swe-sympy10-dsv41-high-report.md` (regenerated with dual
  cost bases).

- **bench: cost tables corrected to Synthetic's published catalog; pi
  fallback-pricing bug fixed.** Synthetic publishes per-model pricing on its
  own `/openai/v1/models` endpoint (prompt/completion/input_cache_reads/
  input_cache_writes). The `hf:deepseek-ai/DeepSeek-V4.1-Flash` entries in
  the niffler and claudecode adapters used borrowed LLM-Gateway rates
  (0.15/0.6/0.003) instead of the catalog's 0.8/1.2/0.16/0 (cache writes are
  $0 — so the claudecode lane's write treatment is correct as-is). pi was
  worse: the generated models.json lacked the hf: entry entirely, so pi
  discovered the model and priced it with fallback rates (observed
  0.15/0.50/0.04, reasoning unbilled) — setupPiConfig now injects the entry
  with catalog cost. Corrected totals at catalog rates: Multi10
  (niffler/claudecode/pi) $0.74/$0.41/$1.57 per run (was $0.10/$0.04/$0.49);
  Sym10 dsv41 niffler $0.81, claudecode $1.15 (was $0.10/$0.08). The GLM
  `syn:large:text` entry already matched the catalog (0.15/0.5/0.04/0).

- **systemprompt: review rubric + skill-loading nudge — +3 lines net.** The
  verify paragraph now requires tracing the failing input through the changed
  code, checking the diff for removed setup and for overrides/callers a
  changed convention affects, and reporting what was run vs. only expected
  (a compiling edit or blocked check is not evidence). Skill guidance points
  at the real flow (discover → skill_list → skill_load) for complex/unfamiliar
  tasks. First measurement — Sym10 rerun (`swe-sympy10-niffler-v2`, niffler
  syn-large one-shot, official Docker grading, same protocol as the cc-vs-
  niffler baseline): **8/10 resolved vs 6/10 baseline** — the three diagnosed
  failure modes (11618 wrong-fix, 12419 representation, 12481 deleted setup)
  all resolved; 12489 flipped the other way (sampling noise candidate), 13091
  still unresolved by either harness. Report:
  `bench/reports/swe-sympy10-niffler-v2-report.md`.

- **edit: successful edits now return a compact change preview** with removed
  and added lines, surrounding context, and explicit truncation for large
  changes. This is tool-result history only; frozen prompts and schemas are
  unchanged. Regression coverage checks replacement, deletion, multiple edits,
  and line-bounded output.

- **grep: slash-globs now resolve against ``path``, not the process cwd.**
  rg matches a glob like `dir/file.py` against the walked path relative to
  rg's own cwd, so passing a search root made slash-globs silently miss
  (seen in Sym10: a correct call returned `[no matches]` and the model
  burned a turn falling back to bash). `runCmd`/`runArgv` gained an
  optional `workingDir` (chdir in the forked child); grep/files chdir into
  the search root and pass it absolutely, so globs are root-relative while
  result paths stay absolute. Regression tests cover grep and files.

- **bench: Claude Code harness (`claudecode`) — the framework now compares
  Niffler against Anthropic's CLI agent too.** `bench/adapters/claudecode.mjs`
  drives `claude -p` headless (stream-json, `--dangerously-skip-permissions`,
  pinned `--session-id` on round 1 / `--resume` on feedback rounds, isolated
  `CLAUDE_CONFIG_DIR` per combo so the developer's `~/.claude` is never
  touched). On Synthetic the harness goes through the Anthropic-compatible
  `api.synthetic.new/anthropic` endpoint with `syn:large:text` (GLM-5.3-Flash
  fp8) — the OpenAI-compatible base niffler/pi use does not serve
  `/v1/messages`. Usage is normalized from the result event (verified against
  a controlled two-call run: `input = Σ(prompt − cached_read)`, cache
  read/write summed; per-call stream events zero the cache fields on this
  gateway), cost priced from the same table as the niffler adapter, thinking
  profile mapped to `MAX_THINKING_TOKENS` budgets, and shape (turns + tool
  mix) parsed from the assistant stream events. Wired into `bench/config.json`
  (`syn-large.claudecode` + thinking profiles), `bench/run.mjs` (registry,
  dispatch, preflight, config guard) and documented in `bench/README.md`,
  including the cache-visibility asymmetry vs the OpenAI lanes. First run —
  `full30`, syn-large (GLM-5.3-Flash), default low thinking, both lanes
  fresh on the same commit: **claudecode 30/30 vs niffler 30/30**, avg 61 s
  / 42.9k tokens vs 63 s / 38.9k tokens (niffler leaner per turn at 7.3 vs
  9.7 avg turns; Claude Code steadier on the loop-heavy cells — t06 62k vs
  340k, t20 53k vs 234k tokens). Report committed as
  `bench/reports/full30-claudecode-vs-niffler-report.md`. Same pairing on the
  **Sym10 SWE-bench Verified pilot** (10 SymPy instances, one-shot, official
  4.1 Docker grading, fresh setup.sh/import/prepare): **claudecode 8/10 vs
  niffler 6/10** — they split the misses (11618/12419/12481 only claudecode,
  12489 only niffler; 13091 unresolved by both). Both resolved 13031, the
  run's long-horizon outlier (niffler 5.9M tok / 74 turns, claudecode 1.6M /
  129). Report: `bench/reports/swe-sympy10-cc-vs-niffler-report.md`.

- **store: sqlite is the default engine, list is a page, and migration is a
  tool.** Three linked changes required by `docs/research/COMPACTION.md`
  (§2/§6.4). First the list cursor contract (`after`/`hasMore`/`nextAfter`)
  across all three engines, with `nextAfter` taken from the last returned
  *key* so a page whose documents are all tombstoned still advances
  (`7047947`, `tests/t_store_paging.nim`). Then every full-kind read goes
  through `storeListAll`, which pages to exhaustion — before it, the capped
  1000-item list silently truncated long-conversation resumes (and the
  truncated `lastSeqNo` made the next persist overwrite later history), left
  every later message behind on delete, undercounted `session_info`, and let
  job settlement read a mid-conversation message as the last one (`39b63a0`,
  `tests/t_resume_long.nim`). With those in place, sqlite becomes the
  default engine: compaction's context projection needs an atomic doc+rev
  write (barrel's put is a two-key sequence) and a range-readable list.
  Unset `NIF_STORE_BACKEND` is a default, not a demand — when store-sqlite
  is absent core warns loudly and uses the manifest's engine; an explicit
  request never degrades silently. Switching the default does not move data,
  so two safety nets ship with it (`c5bac07`): a boot guard that refuses to
  start sqlite over an existing `var/barrel-db` (exit 1, printing the exact
  migration command, the `--scan` hint, and the `NIF_STORE_BACKEND=barrel`
  escape hatch), and `niffler-store-migrate` (new binary), which migrates by
  plain bus replay — its own private NATS server and store processes, a
  kind-agnostic copy, per-kind count verification, `--root`/`--scan`/`--all`/
  `--dry-run`. Verified end to end against a copy of the live 42MB
  production barrel (4309 documents; the harness booted on the migrated
  store and restored its spawned components from the migrated records).
  Docs updated: `docs/MANUAL.md` (engine table, migration + troubleshooting),
  `docs/WIRE.md` ("Store contract"), `AGENTS.md`, `docs/research/STORE_V2.md`
  (`26fe134`).

- **processes: long-running commands with an owner** — servers, watchers and
  test loops no longer have to fit bash's synchronous contract. The new
  processes component spawns commands detached (own process group, stdin
  from /dev/null, stdout/stderr appended to spool files under
  `var/processes/`) and owns the child for its whole life:
  `process_start {command, label?}` returns an id immediately
  (approval-gated, like the bash call that produces it); `process_poll`
  drains only what was appended since the last poll (`waitMs` to block for
  new output or exit, `filter` to project matching lines with the cursor
  advancing past all of it, `tail` to re-read the bounded ~64KB raw tail
  without moving the cursor); `process_kill` terminates the whole group
  (SIGTERM → SIGKILL); `process_list` shows state. Spool files are the drain
  buffer — the child never blocks on a full pipe, there is no reader thread,
  and a spool over the 32MB cap (`NIF_PROCESSES_SPOOL_CAP`) truncates to its
  tail on the next poll with the cursor adjusted. Children survive a
  SIGKilled component by design, so a registry (pid + /proc starttime to
  defeat pid reuse) drives a boot sweep that kills orphans from a previous
  life before serving. bash grows `run_in_background` as a thin producer
  (forwards to `process_start`, returns the id with poll/kill guidance);
  baseprompt gains the processes clause. `tests/t_processes.nim`, 35 checks
  (`e347037`).

- **lsp: workspace warmup + `make install-lsp`.** Core now publishes
  `ev.workspace.opened` at conversation bootstrap (any directory, fires on
  resume too when instances are cold again); lsp responds with a bounded
  extension census (hidden/junk dirs skipped, 5k files / 2s budget), matches
  the top-2 languages against the registry and pre-starts their servers so
  the first real query does not pay cold-start mid-turn, announcing
  `ev.lsp.warm {workspace, warmed, skipped}` and exposing the same path as
  lsp op `warmup` (`644d91f`). `make install-lsp` (`scripts/install-lsp.sh`)
  idempotently installs the registry defaults — gopls, pyright,
  typescript-language-server plus the TS5 tsserver bridge (TS7 dropped
  tsserver; installed out of the way in `~/.local/ts5`), rust-analyzer,
  clangd, nimlangserver and bash-language-server — arch-aware standalone
  downloads, fallback-bin-dir aware, per-language failures non-fatal, with a
  summary at the end (`0302317`, `4917b0f`, `697d4df`).

- **edit: language-server diagnostics ride the change preview.** After a
  successful edit, edit requests diagnostics from the lsp component over the
  bus and appends errors/warnings scoped to the changed range (±3 lines,
  capped at 8, else a one-line pointer that names the lsp tool for
  "elsewhere in this file" cases) to the preview. The push happens where the
  signal already flows, because named-but-onDemand lsp tools never activated
  on their own (zero discover calls across 58 Multi10 cells). Every lsp
  failure mode is silent or a one-line note — a missing, slow or crashed
  language server never fails or stalls an edit that already succeeded.
  Formatting is pure and unit-tested (`tests/t_edit_diag.nim`) (`d64f437`,
  `5f22fb2`).

- **bench: Multi10 v2 official re-run + autopsy** — niffler 4/8 attempted,
  claudecode 7/10, pi 3/8 (four no-start cells were Synthetic 429s). jq and
  tokio were eval-environment bugs (a dirty-tree artifact breaks the
  container build; the getrandom manifest parse fails), not harness
  failures; caddy was a convergent wrong fix (all lanes set `Secure:true`,
  the hidden test pins `Secure:false` for non-secure requests); fmt is a
  minimalism lesson (all lanes fixed the new test while the upstream-style
  fill/numeric handling regressed `PrintfTest.ZeroFlag`). Full
  token/cache/time/tools tables; first graded run with the lsp tool
  invoked. Report: `bench/reports/swe-multi10-v2-autopsy.md` (`1f228a4`).

- **docs/research: harness survey sweep.** New under `docs/research/`:
  `COMPACTION.md` — replaceable-compaction proposal (a peer component
  proposes, the runner validates, applies and persists), with
  sqlite-as-default as its stated prerequisite (`8e2248a`); `AIDER.md` —
  ranked steals from Aider, grounded in source paths (the tree-sitter repo
  map with personalized PageRank as an onDemand, cache-safe tool result; the
  typed edit-parse/lint/test reflection loop budgeted by maxRounds/maxCalls;
  the weak/editor model split) (`22c285e`); `PI-VS-NIFFLER.md` +
  `PI-NEXT.md` — an honest map of what pi has that Niffler does not (session
  tree, compaction, hooks with teeth, image reads) with evidence tables, and
  the follow-up ranking: overflow classification + recover-and-retry and
  image payloads are the real gaps, with the cache section later expanded to
  the write path after correcting the dsh cache-retention claim
  (`0cd100c`, `1329b7e`, `e86176c`, `b3e7dd0`); `REMOTE.md` — prior art for
  running full harnesses on remote VMs (OpenHands Agent Server is the only
  real runtime+fleet precedent) and the two-path conclusion — first-class
  Chetter support vs a custom fleet — moved from `docs/REMOTE-NIFFLER.md`
  (`bcad0ee`, `65eedab`); `CONTEXT-REVIEW.md` — prompt-context audit
  (`b71540b`). The processes design settled in `docs/OCTOFRIEND-STEAL.md`
  before the component shipped (`adff562`, `f673b7e`), and the DSH steals
  implementation plan merged docs-only (`412347c`).

### Changed

- **docs: guides reconciled with shipped features.** README (en/zh/zh-TW)
  trimmed by roughly 1,500 lines to describe what actually ships, and
  `docs/PLAN.md`, `docs/SETTINGS.md`, `docs/MANUAL.md`, the bench container
  docs and most `docs/research/` notes updated to match (`77fbb94`).

- **repomap: scoring hot-spot fix.** The rank-distribution loop was
  O(nodes × edges) — 71s of pure iteration on rubocop (1551 files / ~200k
  edges), which made a warm rebuild look like a broken cache (extraction was
  cached all along). One pass over the edges with precomputed out-totals:
  71s → 6.3s, end-to-end warm rebuild 64s → 10s, output byte-identical
  (`aba88b8`).

- **SDK: bounded initial-connect retry.** Nim SDK components now retry an
  initial NATS connection for up to 60 seconds while the bus binds, honoring
  shutdown, then fail into the supervisor's normal backoff. This removes
  expected boot/restart races from component crash logs without changing the
  successful first-connect path (`e761055`).

- **context: provider-scale accounting and bounded overflow recovery.** Context
  admission now measures in the provider's token scale, durable trim records
  its watermark for restart-safe replay, and normalized provider overflow
  errors receive one receipt-backed recovery attempt before becoming terminal
  (`228251e`).

- **settings groundwork.** `.env.example` now points at the complete settings
  inventory and `docs/SETTINGS.md` records the proposed store-backed settings
  surface. The general `/settings` command remains unimplemented; the separate
  `/approvals` and `/limit` conversation controls are shipped (`7a988ba`).

- **toolchain: Nim 2.2.10 → 2.2.12.** The repo now develops against the
  current stable channel; the floor moves with it (`niffler.nimble`,
  `scripts/check-nim-toolchain.sh`) and every pin follows — CI install
  + cache key, `make install-nim`, README (Linux/macOS prerequisites),
  the bench container's `NIM_VERSION`, and the website's fabric blurb.
  Validated with a clean full rebuild (`var/bin` + nimcache cleared):
  all 26 Nim binaries and 9 Go builds land, no new warnings.

- **plugins: `plugin_installed` derives the checkout commit at read time.**
  Store records carry no commit field, so the listing now runs
  `git rev-parse HEAD` in each checkout and injects the result — truthful
  provenance for `/status` and other clients with no store migration or
  reinstall; `t_plugins` asserts the reported SHA matches the fixture
  repo's HEAD (`08e8f93`).

- **baseprompt: placement triggers and scoping.** One sentence ties
  `lsp goToDefinition` to the failure moment — an edit to a symbol belongs
  at its definition, and when grep only shows uses, the tool confirms the
  home (tokio-4384: the edit landed in the wrong file after 23 bash
  calls) (`0e3b3dd`). The processes entry is compressed to its siblings'
  density, fabric and the skill sentence tightened, and the harness-root
  home line is scoped to building Niffler itself — bench agents working in
  foreign repos were reading harness-development guidance as their own
  (`84888e9`).

- **edit: per-line read cap 200KB → 2KB** (Claude Code parity) — one
  minified-line read could previously flood the history with ~50k tokens
  (`d64f437`).

### Fixed

- **agent: live turn state is refreshed before it is read** (`9d1b584`).
  `busyChild`, the steer lane and the roster's status column read
  `liveTurns`, which is fed by the `ev.session.turn` tap — and a tap is only
  drained while a handler waits, so a handler entered right after a child's
  turn returned still saw that child as mid-turn: `agent_ask` on a
  just-finished child queued the question as mail instead of asking it (the
  reply came back with the child's NEXT turn, or never), and a steer to a
  child that had just gone idle was silently dropped (the runner's steer
  subscription goes away with the turn). One non-blocking tap poll now
  precedes each live-state read, processed once for the whole roster listing.

- **edit: both lsp timeout forms now yield the retry pointer** (`aba88b8`).
  The post-edit diagnostics pull classified only the component's own
  `E_LSP_TIMEOUT` envelope as "server busy"; the SDK transport timeout on a
  slow diagnostics settle (gopls on a big Go repo) fell into the silent "no
  server" branch — which is why gin/caddy (gopls ready and healthy) showed no
  diagnostics while fast settlers (clangd/tsserver) did. Gopls install and
  config were never the problem.

- **core: settlement notices join compaction's context ledger.** Merging
  the compaction work brought the context identity ledger rule — every
  context append goes through `ctxAppend`, or the ledger and the
  projection drift apart. `drainNotices` predated that rule and bypassed
  it: notice messages were persisted and projected but invisible to the
  ledger. Notices are now ledger nodes like steer and advisories, and
  compaction may compact them away like any appended history (`4f70949`).

- **lsp: answer server-initiated requests, declare real client
  capabilities, save-echo after didOpen.** Servers gate features on what
  the client declares: an empty capability blob made
  typescript-language-server skip its entire diagnostic push, and it
  publishes no diagnostics until its `workspace/configuration` request is
  answered — the client now declares only what the component honors
  (didSave, publishDiagnostics, hover/definition/implementation/
  references, workspace configuration/folders) and replies to
  server→client requests (configuration gets per-item empty settings
  objects, everything else the legal null "not supported") so
  gate-keeping servers are never left waiting. didOpen is also followed
  by a save echo, because the nimsuggest-family servers push diagnostics
  on save only (`5bae58b`).

- **core: four review-found defects, each with a regression test**
  (`0e4f5fd`): supervisor restart backoff never engaged (startChild reset
  the counter on every launch, so a fast-crashing child relaunched every
  ~500ms forever instead of backing off to 8s); the parallel wave path
  (`x-harness.parallel`) never applied the frozen session tool allowlist, so
  an allowlisted subagent could run unlisted parallel-marked tools; the
  per-turn maxCalls cutoff ran while building the call batch, leaving
  unpaired tool_calls in the transcript that strict providers reject on
  resume (the cutoff now runs during execution and pairs every unexecuted
  call with an error result); and core's idle pump, mid-turn pump and the
  session runner silently dropped non-call envelopes despite docs/WIRE.md
  promising a bad-envelope reply (all three now answer, preserving the
  decodable id). Hardened along the way: catalog registration refuses a
  non-array "tools" and duplicate tool names before mutating state, and runs
  onChange before publishing `ev.catalog.updated` as documented;
  schema_validation accepts a JSON null for plain "required" (required means
  present, not non-null), enforces maxItems/maxProperties/maxLength of 0,
  and counts string bounds in Unicode characters rather than bytes.

- **components: seven review fixes** (`8f86434`): processes never enforced
  the per-poll chunk cap (rfind searched to end-of-string, so one poll could
  return an entire multi-hundred-KB burst); agent background jobs never
  terminalized on a runner-level error envelope, leaving
  agent_status/agent_wait blocked forever on a job stuck "running"; bash ran
  a compound command's later `;`/`||` clauses from the harness root when
  `cd <cwd>` failed — the wrong directory with no visible error; builder
  generated an unquoted `replace niffler.dev/sdk => ...` in go.mod (breaking
  every Go build in a harness root containing a space) and advertised a Go
  example that did not compile; fetch spill files could collide within the
  same second and overwrite a path already handed to the model (now
  createTempFile); console registered with a doubly-wrapped envelope, so
  core never saw its name/pid/tools and it never entered the catalog; and
  grep's `files` returned rg's unsorted walk order despite the documented
  "sorted, one path per line" contract.

- **bus: three safety fixes, all verified against a live nats-server**
  (`c2ef6ee`): the PATH-fallback spawn now raises max_payload to 8MiB via
  config file (the official nats-server rejects `--max_payload` as a flag —
  without this a hand-compiled dev run silently got a 1MiB bus and every
  oversized reply timed out, indistinguishable from a component hang), with
  a one-time core warning; core reads `natsConnection_GetMaxPayload` at boot
  and warns loudly when an attached foreign bus (NIF_NATS_URL) caps below
  what the harness needs instead of failing mid-conversation; and
  `reclaimOwnNats` verifies `/proc/<pid>/comm` is nats-server before
  signalling the pid from `var/nats-pid` — after a crash the kernel may
  recycle that pid onto an unrelated process, and this was the one place the
  harness signalled something it did not spawn this run.

- **lsp: readFrame honors the operation budget, not the first 250ms pump
  slice** — both the quiet and non-quiet paths gave up after a single empty
  pump slice, so a reported "60000ms" budget actually waited ~250ms and
  every bash-language-server query (shellcheck pushes diagnostics 300–500ms+
  after didOpen) failed with a fake timeout; both paths now keep pumping
  (stderr still drains every slice) until the caller's real deadline, and a
  dead server is still caught instantly (`d3562cc`). The readFrame and
  diagnostics timeout messages also append the server's last stderr line, so
  a "still indexing" complaint carries evidence (`1dbd4f2`).

- **store-migrate: `--dry-run --all` really migrated** — the `--all` loop
  hardcoded dryRun=false (all seven niffler bench roots got written that
  way); the flag now passes through and per-root verdicts read PLAN on a dry
  run. Also fixes an inverted source-engine guard: a root holding both
  stores died with the "no store data" message while the truly-empty case
  slipped through to a confusing engineFor failure (`4faec8a`).

## [0.2.0] — 2026-09-11

### Added

- **bus: natsnim is the default NATS client — `natswrapper` and `libnats`
  are gone** — the bus now runs on
  [gokr/natsnim](https://github.com/gokr/natsnim), a pure-Nim translation of
  `nats-io/nats.go`: the built binaries link libc alone, and `libnats-dev`,
  `cnats`, futhark and `opir` have left the prerequisites entirely
  (`make doctor` no longer checks them; `make install-native-deps` no longer
  installs them). The migration ran behind a `-d:nifflerNimNats` flag with
  the shim aliasing the new module to the old name — call sites
  byte-identical, both clients testable from the same source — and the full
  server suite passed with **each** client on the same commit before the
  guards collapsed to `import natsnim`. Wiring it into a real harness caught
  two client bugs the unit suites had missed (a 1 ms `NextMsg` that never
  read the socket; missing no-responders, so probing an absent component
  burned its whole timeout), and a subsequent review pass hardened the
  transport: absolute deadlines on every operation (a stalled peer can no
  longer hold a 20 ms request for 5 s), explicit handle ownership (destroyed
  messages no longer leak ~1.1 KiB each), bounded parser and queue memory,
  publish write-through with an opt-in batch API (`deferFlush`/`flushOutbound`
  /the `batch` template), and `TCP_NODELAY` (a 20-request loopback probe
  went from 829 ms to 3.5 ms). Head-to-head against `nats.go`
  (`natsnim/bench/compare`): connect and small request/reply at parity or
  faster; fan-out at publisher parity with the batch API (~1.5–1.7M msgs/s
  into a Go subscriber vs ~1.6M for Go itself) and ~1.3–1.5× behind through
  the pure-Nim subscriber (owned payload copies — a safety choice).
  `niffler.nimble` requires the client by URL; `config.nims` resolves it
  from the pkgs2 scan and honors `NATSNIM_SRC` for a local checkout while
  iterating on the client. The full story lives in
  `docs/research/NATSNIM.md`.

- **fabric: compiled-Nim executor (native guests), content-addressed cache,
  structured guest SDK** — the embedded Nim VM (nimeval) is gone:
  `fabric-exec` now writes the guest and compiles it with `nim c` into a
  private process (private HOME/TMPDIR, fresh nimcache), maps `guest.nim`
  line numbers back onto the author's lines in compile diagnostics, then
  execs in place. Approval still precedes compilation, and the trust class
  is now stated explicitly: approved native code may import any std module
  (bash-class trust, not a sandbox), so the banned-token/import lint is
  removed. The executor setsid()s and kills the whole process group
  (compiler, linker, guest, descendants) on timeout/cancel; RLIMIT_CPU/
  FSIZE/AS/NOFILE bound runaway; fd 3 is the protocol pipe and guest stdout
  is redirected to stderr so ordinary echo cannot inject frames. Guests get
  a structured SDK (`import fabricguest`): `call(tool, JsonNode) →
  JsonNode`, `toolCall`/`batch(openArray[FabricCall]) → seq[FabricOutcome]`
  (auto-chunked, ordered, per-item errors preserved, inputs validated
  before any mutation), `finish(JsonNode)` terminal with exactly-once
  semantics, `inputs()`/`stringArg`, `logg`/`log`; the legacy
  `callTool`/`batch(string)`/`finish(string)` forms remain as the compatible
  path. Identical programs reuse a cached binary keyed by the compiled unit
  (guest source with prelude + generated driver + guest SDK sources +
  compiler identity + build flags) under `var/fabric-cache`, LRU-evicted at
  boot and per run — a warm replay reports `compileMs: 0` and
  `cacheHit: true` on the new `ev.fabric.phase` event (results also carry
  `compileMs`, additively). A new on-demand `fabric_help` tool serves the
  bundled `REFERENCE.md` and the worked-example index from component-local
  assets, so models stop hunting the harness root for them (t30-high burned
  ~7 calls locating the files); the `fabric` description points at it.
  Optional `strings`/`tools` arguments accept an explicit JSON null as
  absent (a wrong type still fails, naming the kind it saw).
  `REFERENCE.md` is rewritten for the compiled structured style — skeleton
  with the full import preamble, `call()`/`finish(%*{...})` as the
  preferred API, tool-result envelopes, the corrected trust class, and an
  error table anchored to real native diagnostics — and the five examples
  are migrated to it (retry-loop probes `exit_code` instead of substring-
  matching serialized text). Setup is lighter: the compiler sources
  (nimeval/vm/dist-checksums) are no longer needed, so any Nim ≥ 2.2.10
  distribution works (`scripts/check-nim-toolchain.sh` updated;
  `fabricguest.nimble`, VM-only, dropped). Coverage: `tests/t_fabric_native.py`
  (compilation, structured JSON round-trips, a 33-call auto-chunked batch,
  cache hit and distinct-key behavior, legacy API, compile failure before
  any tool dispatch, missing-finish) plus process-group reaping and
  non-terminating-program stages, both wired into `make test-fabric`; the
  migration plan and phase status live in
  `components/fabric/docs/COMPILED_PLAN.md`.

- **fabric: mid-run cancellation** — stopping the session turn that launched
  a fabric program (or `agent_stop` on the job whose child runs it) now ends
  the guest within seconds instead of letting fabric-exec run out its whole
  deadline. Fabric subscribes `cancel.>` and polls it while the guest runs —
  the wildcard matters, because a stop landing while a nested bridge call is
  in flight is published on that call's component subject
  (`cancel.bash`/...), and the guest must still end. On cancel the executor
  is terminated, in-flight bridge calls are abandoned (inbox subscriptions
  destroyed, queued calls never dispatched), and the run reports
  `status: "cancelled"` (`ev.fabric.done`, tool result carries
  `cancelled: true`) — distinct from success and from failure/timeout.
  Cancels for other sessions are stashed so a queued run is skipped, not
  started, and a queued run is untouched by another run's cancellation.
  `agent_run` polls `cancel.agent` while it waits for its child, so a
  stopped parent turn cancels the child turn (publishCancel) instead of
  letting it burn its budget for a caller that is gone — this is what tears
  down nested `agent_run` children of a cancelled fabric program.
  `tests/t_fabric_cancel.nim` covers the busy-loop stop (cancelled outcome,
  no orphaned fabric-exec), a queued second run completing unaffected, and a
  guest blocked inside a nested bash call whose process tree is killed.

- **docs/research: DeepSeek Harness (dsh) study + the DSH steal proposal** —
  `docs/research/DEEPSEEK-HARNESS.md` surveys DeepSeek's open-source agent
  harness (~170k LOC TypeScript, everything-is-a-plugin on the Cordis DI
  framework, profiles/bundles/patch files, Landlock sandbox launcher) with
  file:line citations — the event-sourced conversation surface with
  provable deletions, the guarded tool pipeline, subagents. Companion
  `docs/research/DSH-STEAL.md` distills four candidate steals made
  Niffler-native (continuable subagents via activation epochs, forked
  children seeded from the parent's history, typed tool declarations
  delivered on demand as a tool result rather than prompt weight, and a
  `team` component with named teammates and a durable mailbox), each checked
  against the existing wire/topology/prompt-cache invariants. Explicitly a
  proposal; nothing here is implemented.

- **Bench: `deepseek-v4.1-flash` model + full30 reports** — the model is
  wired through DevPass / LLM Gateway on both lanes (niffler: baseUrl +
  model + `LLMGATEWAY_API_KEY`; pi: an llmgateway provider with
  `reasoning: true` and a `thinkingLevelMap` so `--thinking` reaches a real
  `reasoning_effort`; catalog ctx 1,050,000 / max out 393,216, runs pass
  `NIF_OPENAI_CONTEXT=1050000` since no catalog entry exists for the id).
  Reports: syn-large low — niffler 30/30 (56s, 26.8k tok avg) and pi 3/3 on
  the t28–t30 fan-out tier, all 1-round
  (`full30-syn-large-low-report.md`); deepseek-v4.1-flash low — both lanes
  30/30 (niffler 24s vs pi 16s avg) and high — both lanes 30/30, where
  niffler pays 3.4× pi's tokens and 2.8× the wall clock
  (`full30-deepseek-v4.1-flash-{low,high}-report.md`); and a niffler-only
  high rerun on the compiled-fabric build, 30/30 under the hardened t30
  verifier, with an explicit variance caveat — single-run deltas against the
  pre-fabric run are not attributable to the fabric change (cells with no
  fabric in their path moved as much as fabric cells in both directions)
  (`full30-deepseek-v4.1-flash-high-postfabric-report.md`).

- **Merged `read` + `read_many`; `grep` is now direct** — one `read` tool
  takes the canonical `reads` array (1..12 files/ranges in one call, each
  item `{path, offset?, limit?}`, per-item errors, identical items deduped,
  512KB aggregate cap) with the single-file `path` sugar; the separate
  `read_many` tool is gone, so the direct toolset loses a schema and the
  batch shape is visible at read time. The
  grep component's `grep` tool is promoted from on-demand to the default
  direct set (ripgrep search without a discover+invoke round trip); `files`
  stays on-demand. `grep`'s output byte cap drops 100KB → 32KB: broad
  patterns were doubling conversation context (an A/B cell fell 6.10M →
  4.74M tokens, peak context 158k → 135k). Baseprompt guidance now says
  "batch known-relevant reads (grep hits, imports)" instead of conditioning
  batching on the task naming files.

- **Web UI `/info` and `session_info` completion tokens** — core's
  `session_info` now reports `completionTokens` (the sum of
  `completion_tokens` over assistant messages with usage) alongside the
  message role counts, and the desktop UI gains an `/info [id]` slash
  command rendering that state (conversation id, title, model/provider,
  thinking effort, created time, workspace, message counts by role,
  context used/limit, input split cached/uncached, output). Builtin
  slash commands that duplicate richer UI flows are marked as aliases
  and hidden from `/help`, command descriptions move into locale
  strings (`slash.*` keys, en/zh/zh-TW), and `/info` rendering has its
  own localized strings.

- **Bench: fan-out tier t28–t30, suite renamed full30** — three tasks
  built so the mechanical work genuinely varies per item or the
  intermediates are oversized — the two shapes where a single `sed`
  fails and model-driven per-file edits burn a turn per file:
  t28-docbackfill (Go: 27 files across 3 packages each need their exact
  package doc comment inserted, replaced (drifted variants) or left
  untouched — three states per file, pinned by a behavior test),
  t29-logrollup (Python: 36 log files (~450KB) roll up into a
  byte-exact `summary.json` with canonical key order), and t30-ifacedrift
  (Node: 24 modules migrate to a new library API where each module's
  own `// profile:`/`// width:` header directives determine the correct
  arguments; the verifier carries an independent reference
  implementation). All red at base, verified green with a reference
  solution; task fixtures are deterministic and committed (t29's input
  logs included) so fresh checkouts run them. Bench-validated with
  syn-large: low tier solves all three with scripted bash (22–71s,
  3–7.5k tokens); high tier passes all three and reaches for fabric on
  t28 (recovering from three precise guest compile errors via
  `firstError` diagnostics) and t30 (one program driving all 24 edits
  plus verification in a single call, after reading
  `components/fabric/docs/REFERENCE.md`). The launcher and READMEs
  track the full27 → full30 rename; `REFERENCE.md` also gains a
  tool-result-envelopes section (the exact bash/edit/grep/read JSON
  shapes guests probe) and corrects the raising rule — a bash nonzero
  exit is a normal result (check `exit_code`), only tool-level failures
  raise.

- **Bench: trimmed-prefix reports (low + high)** — post-diet full27
  numbers on syn-large, niffler-only, against the pre-diet runs and pi
  on the identical protocol. Low: 27/27 round-1 (pi 27/27 with one
  2-round cell), avg 56s vs pi 74.5s, uncached input 3.1k vs pi 3.2k,
  cost parity ($0.0016 vs $0.0015/cell), first prompt 1690 vs 2482
  (`bench/reports/full27-syn-large-low-trimmed-report.md`). High:
  27/27 round-1, avg 264s vs 281s pre-diet — wall time is model
  reasoning, not footprint — uncached input −40% (10.5k → 6.4k), cost
  −5% (`bench/reports/full27-syn-large-high-trimmed-report.md`).

- **`make ram`: per-stack memory report (`scripts/niffler-ram.sh`)** — sums
  RSS/PSS over every process whose executable lives in a checkout's
  `var/bin` (harness, nats-server, all components, session runners,
  tui/cli/console) plus the desktop UI, grouped per stack: dev clone,
  nifflerprod, and each bench private harness (cwd under
  `var/bench/results/<run>/`) separately. Membership is by executable
  path, not a PPID walk (the tui parents an autostarted harness and a
  bench run's private bus belongs to the bench driver), and PSS is
  preferred over RSS so stacks sharing one `var/bin` don't double-count
  file-backed pages. Wired as `make ram`; `docs/MANUAL.md` "Common tasks"
  documents usage and the PSS-vs-RSS reading.

- **Bench: Synthetic `syn:large:text` model, suite renamed full27** —
  `config.json` gains a `syn-large` model (Synthetic's GLM-5.3-Flash:
  512k context, 64k output, efforts low/high/max, $0.15/M in / $0.50/M
  out / $0.04/M cache-read) wired for the niffler and pi lanes. The pi
  adapter gets a `synthetic` provider in its isolated models.json with
  `reasoning: true` + `thinkingLevelMap` — required so `--thinking
  low|high` reaches the API as a real `reasoning_effort` (the
  interactive `~/.pi` extension ships `reasoning: false`, which flattens
  both to the default); the niffler adapter carries `syn:large:text`
  transcript pricing, and the missing-key check is now generic (derived
  from config `apiKeyEnvs`, with a `.env` fallback so `SYNTHETIC_API_KEY`
  resolves). The high-effort timeout lesson scales `high` (x2, `max`
  x3) in both `run.mjs` and `launch.mjs`, and the custom suite is
  renamed full27 (t01–t27). First full27 run on it:
  `bench/reports/full27-syn-large-low-report.md` (thinking=low, both
  lanes 27/27, cache behavior clean on both).

- **Named tool profiles and sticky `invoke`** — a new on-demand core tool
  `profile` (ops `list`/`get`/`save`/`delete`, store kind `profile`) manages
  persistent selector lists applied on top of the fundamental direct set:
  `component` (every non-hidden tool of that component), `component.tool`
  (one exact tool) and `-name` (exclude, may trim the base or an earlier
  add). `session.profile` selects a profile when a conversation is first
  created; selectors resolve against the live catalog exactly once and the
  resolved set is persisted with the conversation's frozen snapshot — the
  profile is never consulted again, so resume stays byte-stable.
  Unresolvable selectors are skipped and reported as `missing` (unknown and
  hidden indistinguishable, same name-free rule as `invoke`, so a profile
  cannot probe for hidden tools), output is name-sorted, and `list`/`get`
  report `toolCount`/`estTokens` for pickers and budget checks. The
  complementary path for existing conversations is `invoke {sticky: true}`:
  after a successful call the target's normalized schema is appended to the
  persisted direct set — hidden tools never promote, a session tool
  allowlist defers it, and `NIF_MAX_DIRECT_TOKENS` (default 4000) caps the
  whole direct set — emitting a `reset:tools` status event when the direct
  set actually grows. Explicit discovery stays append-only in history with
  no automatic promotion. The web client gains `/components
  [all|direct|discovered|undiscovered]` filters (also in the Components
  panel, with text search), an explicit `/discover COMPONENT` /
  `/discover tool=NAME` command, and `/profile NAME` (or `/profile default`
  to clear) to set the client default used by `/new`.

- **External MCP servers as bus components (`mcp`, `mcp-bridge`)** — the
  `mcp` manager owns a store-backed server registry (kind `mcp`) with
  approval-gated CRUD (`mcp_add`/`mcp_edit`/`mcp_remove`), every add/edit
  validated through one real connect via `mcp-bridge --probe`, and spawns
  one supervised mcp-bridge process per server. Bridges (official Go SDK;
  stdio / streamable HTTP / SSE) announce the server's tools as ordinary
  catalog tools (`mcp_<server>_<tool>`, on-demand by default) reachable
  through `discover` + `invoke`. MCP sessions are lazy (connect on first
  call, idle timeout) and server-pushed tool-contract drift persists the
  fresh listing and restarts the bridge so discovery stays truthful.
  `${ENV}` references in headers, env, args and url are resolved at spawn
  time, so tokens stay out of the store. Prompts and resources: each
  server prompt registers a hidden `mcp_<server>_prompt` tool plus an
  `mcp-<server>-<prompt>` slash command (prompt submits render as user
  messages), and `mcp_<server>_resources` lists/reads resources (64KB
  text cap, base64 blobs); prompt cache changes ride the same drift
  flow. `mcp_search` queries the official MCP Registry
  (`NIF_MCP_REGISTRY_URL` override) and suggests an `mcp_add` config for
  npm/PyPI-packaged entries. Hardening: strict config parsing
  (`DisallowUnknownFields`, validated URL/env/header/timeout bounds),
  name + namespace collision checks, env allowlist for stdio servers,
  same-origin-only header injection with cross-origin redirect refusal,
  serialized call gate with mid-flight cancellation (`cancel.<server>`
  aborts in-flight MCP calls), >64KiB results spilled to
  `var/mcp-results`, capped probe buffers with secret redaction, and a
  stdio guard subprocess (lifeline pipe, process-group
  SIGTERM/SIGKILL, `PDEATHSIG`) so MCP servers never outlive the
  harness. Supporting changes: `core.spawn` accepts persisted args
  (restored on boot, preserved across supervisor restarts); the Go SDK
  gains `DeferAnnounce`/`Announce`, extracted `Wait`, exported
  `DieWithParent`, and a contract frozen after `Announce` (late
  registration panics; post-ready calls fail not-ready). `tests/t_mcp.nim`
  drives a dependency-free fixture server (prompts, resources,
  cancellation, killed-guard orphan regressions) plus a mock registry,
  and `make gotest` runs the mcp modules under `-race`. `docs/MANUAL.md`
  has a full "External MCP servers" section.

- **Web UI: MCP server manager panel** — `McpManager.svelte` (slide-over
  mirroring ProviderManager): self-loading server list with
  live/disabled badges, per-secret-key counts, two-click remove and
  refresh, plus an add/edit form covering transport (stdio/http/sse),
  args/env/headers (line format) and exposure/effect/approval/
  concurrency/timeout. Talks straight to the mcp component's tools
  (120s saves — validation runs one real connect); header MCP button and
  en/zh/zh-TW strings; shared `mcpForm` model, warnings/lastError/idle
  display, and 4 UI tests.

- **Bench mid-tier tasks t18–t27** — t01–t17 saturated (frontier models
  clear them in ~20s/cell) while SWE-bench cells burn hours, so ten new
  tasks target 2–10 min/cell with difficulty from spec fidelity and edge
  cases instead of volume: LRU+TTL with injected clock (go), token
  bucket refill math (py), LCS-aligned JSON patch (node), varint/zigzag
  wire codec (go), vixie cron next-run (py), interval merge + min-rooms
  (go), deterministic Levenshtein edit script (node), race-tested FNV
  shard map (go), mini log-query language (py), ustar reader (nim). Each
  ships tests + `test.sh` in the base commit, red at base, verified
  green with a reference solution. Supporting bench fixes: the launcher
  accepts task names (`t22-cronnext` style) alongside indexes;
  `run.mjs` chmods the prepared `test.sh` to 0755 (the plain copy lost
  the exec bit, costing every cell a wasted exit-126 round) and the
  committed task sources now carry the bit too; `run.mjs` aborts when a
  task has no runnable verifier. First mid-tier calibration in
  `bench/midtier-analysis.md` (niffler vs pi, glm-5.3-flash low: 20/20
  pass, niffler avg 164s vs pi 103s, 84 LLM calls of which 61 are
  <60-token tool-selection turns) with the README table updated.

- **Prior-art analysis of Reasonix** (`docs/research/REASONIX.md`) —
  research note on the DeepSeek-Reasonix codebase (Go, single binary):
  transport-agnostic controller, MCP client, plugin/sidecar extension,
  permission postures, and a ranked list of the ten highest-leverage
  candidates for Niffler. Explicitly not a plan.

- **Store engines: SQLite and TiDB behind `NIF_STORE_BACKEND`** — the store
  bus contract is now an interchangeable engine choice with one component
  identity: every engine registers as `store` v0.1.0 with identical
  put/get/list/del tools and result shapes, and core resolves the manifest
  entry's binary from `NIF_STORE_BACKEND` (`barrel` default, `sqlite`,
  `tidb`; unknown values refuse boot). `components/store-sqlite` is pure-Go
  modernc.org/sqlite (goose embedded migrations, WAL, flock single-writer,
  one-statement upsert/CAS) and `components/store-tidb` speaks the MySQL
  protocol (DSN from `NIF_STORE_TIDB_DSN`, pessimistic upsert transactions,
  `utf8mb4_bin` for byte-exact ids). `tests/t_store.nim` takes a
  `NIF_STORE_BIN` override so one bus-contract suite runs against any
  engine (`make test-store` / `test-store-sqlite` / `test-store-tidb`), and
  `tools/bench_stores.nim` benchmarks engines at the bus level.

- **`make install` / `make uninstall`** — installs `niffler`-prefixed
  symlinks to the built binaries plus a `niffler-tui` wrapper (which
  performs the opt-in plugin dance before launching the TUI) and generates
  a starter `.env` (`scripts/install.sh`); README quickstart now points at
  it, with clone-equals-instance isolation noted.

- **Bundled skill `niffler-harness`** — operational guide to the running
  harness itself: lifecycle (`make run` / `--minimal` / `--recover` /
  `make down`, autostart rules), session runners, the store (engines,
  reading a conversation out via `cli`), self-extension end-to-end with the
  `x-harness.*` schema extensions, bus debugging (`console`, `cli`,
  `observe`, `logfile`, prompt-cache discipline), plugins/skills discovery,
  config and a recovery cheatsheet. Complements `niffler-tools` (which
  tool) and `niffler-fabric` (program construction). `niffler-tools` gains
  an execution-contexts section (main session vs `agent_run` vs fabric
  guest), a per-conversation toolset reminder, and the model-catalog-
  as-authority pointer. The expert advisory peer embeds it in the judge
  prefix — `SkillAllowlist` now carries all three bundled skills
  (`niffler-tools`, `niffler-fabric`, `niffler-harness`) and `t_expert`
  asserts the full set loads.

- **NATS server as a first-class Go component** — `components/nats`
  rebuilds the official nats-server (v2.14.6, in-process server library,
  CLI-compatible) into `var/bin/nats-server`; core prefers that binary over
  a PATH install, so `make build` alone satisfies the bus dependency and
  pure-desktop use needs no `go install` of nats-server. `make setup` drops
  `install-nats`; tests and the bench prefer the built component too.

- **Bench: full17 task set, thinking profiles, CodeWhale lane** — the
  comparison bench grows to 17 tasks tagged by kind (general / fabric /
  expert / selfextend; six seeded-bug repairs, a racy worker pool under
  `-race`, INI/async/log-summary CLI tasks, batch rename, TODO sweep,
  JSON API fetch, build-a-checker self-extension). A 4th adapter drives
  CodeWhale headless (`exec --auto`, per-run CODEWHALE_HOME with a
  provider table rewritten per combo — union, not first-boot freeze);
  SWE-bench Verified runs as its own subset. A `thinking` config section
  maps one CLI flag across harnesses — niffler forwards
  `reasoning_effort`, pi needs `thinkingLevelMap` to send a real "max",
  opencode uses `--variant`, codewhale writes its config — so `--thinking
  low|max` multiplies the matrix cleanly.

- **Expert: tool-selection mission, judgment audit** — the expert's job
  is now keeping the working session on the correct Niffler tool. Its
  prefix snapshots the observed session's frozen direct exposure and
  allowlist via `core.prompt_preview` (an allowlisted session is never
  told about tools it cannot call), is backed by two bundled skills
  (`niffler-tools`, `niffler-fabric`) loaded from the skills component
  behind a reviewed allowlist, and demands steers that name component +
  exact tool + argument shape (or a fabric sketch). Every parsed judgment
  lands in `ev.log.expert` (silence reasons included), in-flight tool
  calls read as "RUNNING", and session runners now serve `prompt_preview`
  / `doctor` (they share `svc.core.call`, so the expert's probes used to
  land on a runner and fail 5/17 follows).

- **fabric: curated program writes + bench self-review** — the store's
  `put` is reachable from sessions (onDemand, sessionId-injected,
  kind-scoped: sessions may write only `fabricprog`; harness-managed
  kinds are rejected), so the documented curation flow works from a
  conversation. `bench-selfreview` v2 distills a whole run (136 cells)
  with an embedded python walker into ~11 calls and reports per-kind
  aggregates, invalid/missing cells and bash file-inspection/prompt-mass
  drift flags.

- **`make release`** — `make build` stays debug (fast, runtime checks
  on); `make release` rebuilds `var/bin` with `-d:release` for benching
  and production. The mode is stamped in `var/bin/.mode` and a flip
  wipes the binaries, so nothing stale survives the switch.

- **CI: PR gate** — `pull_request` to main runs the full bus-contract
  suite on GitHub Actions (hermetic: private NATS + temp NIF_ROOT per
  test, stub LLM, no API keys), 45-minute job timeout, doc-only PRs
  skip via paths-ignore.

- **LLM per-request timing telemetry** — one INFO stderr line per chat
  request: time to first token, total duration, prompt/completion
  tokens, effective tok/s, reasoning effort and reasoning length,
  aborted status on stream errors. The supervisor captures it into
  `var/logs/llm.log` so bench runs can separate provider routing from
  request shape.

- **UI: human-first slash results, thinking effort "max"** — slash
  command results render the payload itself (crafted `summary` verbatim,
  now `text` first after the tool-result change, pretty JSON as
  fallback), and the per-conversation effort selector cycles
  auto/low/medium/high/max end to end (session tool → llm
  `reasoning_effort`).

- **SDK: `jsonx` nil-safe JsonNode helpers** — `jkind`/`isStr`/`isObj`/
  `isArr`/`listOf`/`jdump` cover the nil-unsafe half of std/json (pure
  std/json, unit-tested in `t_jsonx`); born from a SIGSEGV on a missing
  text field.

- **CodeWhale borrows — quick-win batch** (docs/research/CODEWHALE.md):
  techniques adopted from the CodeWhale coding agent (Rust, gemini-cli
  fork). New `hooks` component: operator shell commands on selected bus
  events (`ev.session.turn`, `ev.log.>`), payload as JSON on stdin,
  observe-only (no approval steering — that stays core's gate),
  env-configured, off by default, worked examples in
  `components/hooks/README.md` (`tests/t_hooks.nim`). New core tools:
  `prompt_preview` (composed-request provenance: prompt source/bytes,
  project context files, frozen direct vs discovered tools — read-only,
  never sends) and `doctor` (one-shot machine-readable health report:
  store/llm/provider/systemprompt/catalog, read-only probes). `git` gains
  `review_receipt` — local diff-fingerprint write/check pair under
  `var/review-receipts/` for pre-push review handoff, never calls a model.
  `skills` gains `skill_audit` — unmerged on-disk inventory making skill
  shadowing visible. Cache economics surfaced: `ev.session.status` carries
  `cacheHitTokens`/`cacheHitRatio` (frozen-prefix hit rate),
  `ev.session.context` names its reason (`reset:trim`, `warn:threshold`),
  the web UI shows `⚡ NN% cached` per message and a trim-resets-cache note;
  the niffler-tui plugin shows a `⚡ NN% cached` status-line chip
  (niffler-tui `feat/cache-stats`). `sdk/dotenv` hardened: 1 MiB cap,
  symlinks/hardlinks refused, no variable expansion. AGENTS.md documents
  the prompt-cache contributor rule (frozen prefix vs append-only history).

- **bash: oversized output spills to a temp file, paged with `read`** — the
  transcript keeps a 12KB cap: when a command's output exceeds it, the full
  capture (bounded at 2MB) is written to `var/toolout/<session>/<id>.out`
  and the transcript keeps head + tail with a marker carrying
  `result.spill {path, bytes, lines}`. The model pages the rest with the
  existing `read` tool (offset/limit), so no new tool and no prompt weight;
  spill files are swept after an hour, and paged slices arrive as ordinary
  new tool results, so the frozen prompt prefix stays cache-valid.

- **LLM auto-retry (B3)** — the session runner classifies chat failures and
  retries transient ones (429/5xx/overloaded/timeout/connection drop) with
  exponential backoff + jitter, `NIF_LLM_MAX_RETRIES` (default 2, 0 disables);
  auth/quota/bad-request fail fast. Every retry announces
  `ev.session.retry {attempt, maxRetries, delayMs, error}`. Policy lives in
  `core/retry.nim`; unit-tested, plus an end-to-end scenario (two mocked 503s
  then success) in the parallel test suite.

- **Usage-accurate context accounting (A2) + cache reporting (A3)** — the
  context guard trims at min(90% of window, window − 16K output reserve;
  `NIF_CTX_RESERVE`) instead of a bare ratio, and the pre-usage chars/4
  estimate now counts reasoning, tool-call arguments and per-message
  overhead. Per-conversation prompt-cache counters (from the provider's
  `cached_tokens`) surface as `cache {prompt, read, hitRate}` on session
  status events, in the conversation header and in `session_info` —
  making cache hostility measurable before compaction lands.

- **Parallel tool waves and process replicas** — session runners fan out
  explicitly `x-harness.parallel` calls over distinct NATS reply inboxes and
  commit results in model order. Stateless logical components can now set
  `replicas: N` (1–16) in `manifest.yaml` or `core.spawn`; the supervisor,
  catalog, persisted shape, status, and group lifecycle are replica-aware.
  Four `grep` replicas ship by default, and the timing contract proves two
  one-second same-component calls finish in about one second without adding
  threads or `{.gcsafe.}` handlers to the default Nim SDK pump. The Go SDK
  gained bounded `ToolConcurrent` goroutine dispatch with serialized-handler
  barriers and graceful waiting; the audited `llm.chat`, `llm_resolve`, and
  `llm-openai.chat` handlers now overlap across independent sessions.

- **Live model ids from the provider's own /models endpoint** — two
  complementary surfaces over models.dev (metadata authority: limits,
  pricing) with the provider itself as id authority:
  - `provider` component: new `provider_models` tool probes
    `{base}/models` — by stored `nickname`, or explicit `baseUrl`+`apiKey`
    for the connect form before the credential is saved. Disk-cached
    5 min per endpoint under `var/models-served/`; a failing probe serves
    the last-known-good cache; OAuth credentials are honored.
  - `llm` component: registers an `x-models-source` plugin (priority 150)
    whose JSON Merge Patch adds the ids each provider was observed serving.
    Probes run in the background after chats (10-minute TTL, never blocking
    or failing a chat); the models component merges the patch on its normal
    refresh cycle so every bus client sees served ids.

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
- **Configurable chat completion timeout** — `NIF_LLM_TIMEOUT_MS` raises
  `llm`'s chat ceiling (default 5 min) for slow reasoning models; a single
  GLM thinking=max completion can legitimately exceed it. Bench harnesses
  inherit it to the private bus.
- **DeepSWE benchmark port, niffler-bench container, interactive launcher
  (bench/)** — `bench/deepswe/` ports Datacurve's deep-swe: 113 original
  long-horizon tasks across TS/Python/Go/Rust/JS, imported with
  `import.mjs`, prepared into task-root layout with `prepare.mjs`, and
  graded by Datacurve's own verifier inside Docker (`verify.mjs`);
  verified end-to-end on `etree-xml-diff-patch` (trivial patch unresolved,
  gold patch resolved). `bench/container/` builds the niffler-bench job
  image + compose (builds Niffler at `NIFFLER_REF` per run) so lanes run
  on a remote host. `bench/launch.mjs` is a guided front-end for `run.mjs`
  (target/harness/model/thinking/benchmark prompts, flag-equivalent,
  `--dry-run`). `bench/README.md` documents all three.

### Changed

- **edit: canonical reads shape** — reads adopt union semantics with no
  exclusivity errors: overlap between explicit windows, line ranges and the
  seen-state is a feature rather than a conflict, the speculative
  read-batching nudge is dropped, and the bench counts canonical-reads
  batches (`088826f`, `2e2d3dc`).

- **read: window batches; frozen-prefix trim** — `read`'s batch mode is now
  `windows` (items `{path, offset?, limit?}`, 1..12), replacing the
  string-only `paths` form (shipped unreleased, no users): per-item ranges
  let the grep-hit → read-each-window loop batch in one call instead of one
  read per turn, and `x-harness.workspace` gained
  `pathObjectArrayFields` so relative paths inside array objects resolve
  against the conversation workspace. The frozen prefix is trimmed before it
  reaches the model (`08bb603`).

- **`make test` split into `test-server` and `test-ui`** — `make test` is the
  full gate and runs both, frontend first so a TypeScript break fails fast;
  `test-server` is the bus-contract suite alone and `test-ui` the frontend
  alone. Server-side work no longer needs the node toolchain, and frontend
  work no longer needs a bus: the frontend lib tests import the TypeScript
  sources directly (node type stripping, no dependencies, no NATS), while
  the typecheck needs `ui/frontend/node_modules` and fails with a hint to
  run `make ui` when it is missing (node 20+ checked the same way
  install-node does). AGENTS.md and docs/MANUAL.md document both targets.

- **Web UI: one registry for slash-command dispatch, help and completion** —
  `slash.ts` declares what exists (names, params, built-in synonyms as
  `aliasOf`, subcommands); `slashDispatch.ts` declares what happens, keyed
  by those names; and `tests/slash.test.mjs` fails when the two sets diverge
  in either direction — the drift that hid `/provider strip` behind a string
  comparison and left the dispatch switch with no test coverage at all.
  `/provider`'s environment/env/strip subcommands are declared, so `/help`
  renders them from the registry and Tab completes them next to
  `provider_list`'s nicknames; `/discover` declares its
  `<component>|tool=NAME` argument shape; `commandUsage()` renders `/help`
  usage lines from the declarations (moved out of Chat.svelte so it is
  testable). The registry no longer imports the transport (`SendFn` is
  injected), so it loads on plain node, and Chat.svelte keeps only an
  adapter from component state to SlashContext.

- **fabric: banned-import lint catches bracket imports, actionable
  compile failures, run-tested examples, LLM reference doc** — the
  token lint missed `import std/[os, strutils, sequtils]` (bench t13:
  the VM compile then failed on stdlib internals, the agent saw
  "closed its output before a complete response" and retried the
  identical guest twice before falling back to bash). Lint now scans
  `import`/`from` lines and matches each module against a banned-module
  set (os, osproc, net, asyncnet, asyncdispatch, nativesockets,
  selectors, posix, httpclient, asyncfile) — bracket lists, aliases and
  from-imports included — skipping lines inside triple-quoted strings
  (bench-selfreview's embedded Python walker tripped the line scan);
  the rejection names the module and the sanctioned pattern
  (`callTool("bash", ...)`). Guest compile failures surface `firstError`
  (the actionable compiler line) plus an explicit hint when std/os is
  the culprit — this enforces the documented contract that guests must
  not touch the filesystem, processes or network directly, instead of
  leaning on a stdlib accident (direct FS access in a guest would
  bypass the per-call approval gate). The five examples
  (fanout, pipeline, retry-loop, hybrid, bench-selfreview) — which had
  never been executed by the test suite — are fixed (missing `std/json`
  imports rendered as misleading type-mismatch errors) and now run in
  `t_fabric` as scripted stub turns with real fixtures asserting their
  finish values. New `components/fabric/docs/REFERENCE.md`: a dense LLM
  reference (verified import preamble, tool args, guest API, result
  flow with artifacts, common-errors table, patterns index); component
  headers and the tool description point at it instead of the human
  research doc. The baseprompt gloss and fabric's description also
  raise the bar for reaching fabric at all — "mechanical fan-out beyond
  one command": a single shell one-liner (bulk rename, a sed across
  files) stays in bash (bench t13 burned ~30k tokens on a fabric
  detour for one `sed` line; with the fixes the rerun solved in 16s
  via direct bash).

- **Session: per-turn round budget default 20 → 50** — `NIF_MAX_TURN_ROUNDS`
  and the subagent `maxRounds` range (`agent_run`/`agent_spawn`) both
  move to 50: the old default clipped long agentic turns (bench lanes
  already ran at 100 for exactly that reason), and the cap exists to
  bound runaway cost, not to shape normal work. `docs/MANUAL.md`
  documents both.

- **edit/read: unchanged full re-reads return a marker, edits guard
  against stale context** — reads and writes track a per-(session, file)
  digest of raw bytes, so an unchanged FULL re-read returns a compact
  `[unchanged] path: N bytes, digest` confirmation instead of re-dumping
  content the conversation already holds. `force=true` (or an
  offset/limit window) opts back out, and sub-512-byte files always
  re-dump (the marker would cost nearly as much as the bytes). `edit`
  now refuses with `E_STALE` when a file's bytes changed since the
  conversation last saw them — `old_string` could otherwise match text
  the model has never seen. Digests are keyed by session, so parallel
  conversations never share state, and cli/scripted calls without a
  session behave exactly as before. File-tool descriptions were slimmed
  to point-of-use semantics (batching and authoring-routing rules live
  in the baseprompt once). Covered end-to-end in `tests/t_edit.nim`.

- **Frozen prompt prefix diet: 2479 → ~1540 tokens (-38%)** —
  `formatToolsForLlm` promotes the tool description to
  `function.description` and strips it from `parameters` (it previously
  serialized twice — 25% of the frozen toolset's wire size), drops the
  per-tool batching suffix (the baseprompt owns that rule), and moves
  `files` out of the frozen set to on-demand like `grep` (the baseprompt
  names survey surfaces by component, so tool names are learned at
  discover-time). Component descriptions for bash/edit/read/read_many
  are deduplicated against the constitution, and the baseprompt is
  tighter throughout (one merged call-discipline sentence, a
  discovery-forward ladder naming components, a compact workspace block
  carrying the reach-outside rule). Measured on a live harness: frozen
  prefix 9424 → 5854 chars. As with earlier prompt passes, changes
  affect only new conversations' frozen prefixes.

- **Prompt economy pass, driven by the bench prefix comparison** —
  measured against pi's mid-tier prefix, niffler spent ~900 extra tokens
  per request on tool schemas, so the system prompt dropped from 464 to
  304 words (same rules, tightened wording; the systemprompt-provenance
  note moved to a component doc comment and the contradicting `Run pwd`
  line was dropped), the `discover` description from 309 to 208 chars,
  and the `bash` description from 343 to 62 chars — the exit-124/130/126
  explanations now live in the result text where they fire (including
  the 126 interpreter hint) and spill paging is self-describing at
  spill time. Baseprompt guidance now prefers one full write when
  authoring, one `read_many` when the files are known, and one suite
  run per change set, explains fresh-shell cwd semantics and ranged
  reads, allows practical dependency installation, and asks for
  completion checks over requested behaviors, boundaries, failure paths
  and compatibility with verification gaps disclosed. Changes affect
  new conversations' frozen prefixes only.

- **The expert follows several sessions concurrently** — component state
  moved from one global observation frame to a per-session table keyed by
  session id (frame, knowledge prefix, judgment budget, model/provider
  overrides, per-follow metrics), so two followed sessions no longer
  overwrite each other's target and `expert_status` answers per-session.
  `expert_follow {session_id, model?, provider?}` adds a follow,
  `expert_unfollow`/`expert_status` take an optional `session_id`
  (aggregate without), and `expert_reload` rebuilds every followed
  session's prefix. The judge lane stays global by design: one judgment in
  flight, shared cooldown, per-session latest-state coalescing; stale
  outcomes are dropped, never delivered.

- **Bus max payload raised to 8MiB** — `llm` `chat` requests carry the whole
  conversation, and the official 1MiB NATS `max_payload` capped usable
  context at ~250k tokens (surfacing as `Maximum Payload Exceeded` around
  206k visible tokens). The bundled `components/nats` build gains a
  `--max_payload` flag (a Niffler extension — upstream accepts it only via
  config file) and core spawns it with 8MiB (test buses likewise); a PATH
  `nats-server` keeps the 1MiB default. A publish over the cap now reports
  the size against the bus's `max_payload`.

- **`cli catalog` prints the serving harness** — a `# harness: <root> @
  <gitHash>` line above the component list. The cli has no attach-time
  identity check (it trusts the discovery file by design), so the catalog's
  root + gitHash makes a wrong-bus mixup visible instead of silent; older
  cores answer without the fields and the line is simply omitted.

- **The git clone is the instance identity — bus attach rules follow it**
  (`NIF_NATS_URL` in the process env stays attach-only for tests/bench; a
  URL from the clone's `.env` — or the well-known 4222 default — is the
  clone's home bus: claimed when free, attached to only when the answering
  core serves this root, and yielded loudly (isolated random bus) to a
  foreign core or a bare nats-server; a recorded leftover (`var/nats-pid`)
  is reclaimed). `NIF_NATS_SPAWN=1` now means "never 4222": always an
  isolated core-owned random-port bus. The catalog (list/components/
  snapshot) carries root + gitHash, core prints both at startup,
  `ensureHarness` (Nim and Go) only attaches to a core serving its own
  root, and clients resolve `var/nats-url` from their binary's clone rather
  than the cwd. Nothing survives its harness either way: PR_SET_PDEATHSIG
  in both SDKs and the nats-server component, and the supervisor wraps
  every child with `setpriv --pdeathsig TERM`. The 4222 yield warning now
  names an unidentified (older?) harness when no owner record is present.

- **Core routes calls only to accepted service instances** — components no
  longer share a public NATS queue group per tool: core keeps an
  accepted-PID → private call subject route table and round-robins
  replicas over it (the `replicas` manifest option now spawns service
  replicas behind that router, not queue-group members), so a rejected or
  departed process can never receive a call. While a session waits on a
  service reply, core forwards other service requests on a 1 ms poll
  instead of 100 ms, so dependent calls from the awaited session stay
  responsive.

- **`make setup` dependency installation rebuilt** — new
  `install-native-deps` (build tools, clang/libclang, NATS C + LZ4, PCRE;
  Homebrew vs apt per platform) and `install-nim-deps` (`nimble install
  --depsOnly`) targets, with setup running the install targets serially so
  package-manager writes and Nimble builds never race under `make -j`.
  Nim installs via choosenim pinned to 2.2.10, Node must be 20+ for the
  UI toolchain (snap channel 22 on Linux, explicit error otherwise), and
  macOS uses Xcode's own libclang instead of installing a redundant LLVM.
  `make doctor` checks clang, `opir`, NATS C/LZ4/PCRE and the Nimble
  packages it can now actually verify.

- **Bash discipline in the constitution** — two explicit rules after the
  SWE-bench tool-use audit (~15% of bash calls were redundant navigation:
  `cd` into the repo the tool already runs in, `pwd` re-verification,
  phantom `cd /workspace`) and heavy `cat`/`sed -n` viewing: the bash
  tool's cwd IS the current workspace (no cd/pwd), and file
  viewing/searching goes through read/read_many/files/grep, never bash.

- **First-request prefix diet** — the first assistant prompt drops to a
  path-free baseprompt and an 8-tool direct set (read-only tools stay
  discoverable); bench-validated on both lanes with zero task losses.

- **Two-part tool results** — text for the LLM, structure for the bus.
  Text-oriented tools (bash, git_*, grep, files, edit, write,
  undo_last_edit, read_many) return a JSON object whose string `text`
  field is the LLM-facing rendering — session runners put `text`
  verbatim into the tool message, so transcripts stay lean (`(exit N)`
  status line + output; `### path` blocks for read_many) — while every
  other field (`exit_code`, `cancelled`, `spill`, `edits_applied`,
  `items`, ...) stays machine-readable for fabric programs, tests, UIs
  and plugins; string-parse coupling to prose is gone. Convention
  documented in docs/WIRE.md ("Tool results"); UI slash rendering shows
  `text` first. Bench full17-flat2: −10% tokens deepseek, −34% glm vs
  5aa8c97.

- **Prompt diet** — lean baseprompt + tool descriptions, pure JSON Schema
  to the LLM: the baseprompt shrinks 1320 → ~460 tokens (the
  component-authoring tutorial moves to `builder.info`'s result, where a
  self-extension task discovers it; the ladder/ecosystem guidance
  compresses to one-liners), descriptions are trimmed across the 13
  direct tools (bash 206→90, edit 199→75, write 159→70, ...), and
  `formatToolsForLlm` strips `x-harness.*` from the parameters object —
  the LLM gets a pure JSON Schema; the catalog keeps the full schema for
  gates and validation. Bench-verified: firstPrompt 5154→3543 tokens,
  cache reads −35% (GLM 6/6 pass).

- **Batched tool calls invited** — the baseprompt tells models to batch
  independent calls (read-only calls always batch safely), `llm` sends
  `parallel_tool_calls: true` explicitly on both streaming and one-shot
  paths so gateway defaults don't vary, and read-effect tool descriptions
  get a batch hint. Measured on both bench lanes the invitation is
  harmless (calls per round stayed ~1); it stays as the prompt-side
  counterpart of the host-backed `batch` tool.

- **Typed store client in the SDK** — `sdk/niffler` gains a typed store
  client and config helpers (mirrored in the Go SDK); agent, fabric,
  plugins, logfile and observe drop their local store/config boilerplate
  and every core call site moves onto typed get/putRev/list/del with
  preserved conflict/not-found semantics. Two deliberate behavior fixes
  rode along: session resume lists with the store's full 1000-record cap
  (was silently truncating at 100) and `dispatchSubjectCall` raises on
  timeout. Plus the store v2 (rev 2) plan as a forward-looking doc.

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

- **core: `__session` is injected on the parallel wave path** — parallel-safe
  tools (`read` is `parallel: true`) go through `dispatchToolCalls`, which
  resolved the workspace but never injected the live session id the way
  `dispatchToolCall` does for `x-harness.sessionId` tools. Read's seen-state
  was therefore inert in real turns: no `[unchanged]` stubs, no `E_STALE`
  correction, no batching hint (the direct SWE run showed 0 stubs and 0
  hints across 96 reads). The wave path now injects it exactly like the
  serial one (`1e86d9c`).

- **edit: a read that observes different bytes persists the digest
  correction** — re-reads previously updated only in-memory seen-state, so
  a stale persisted digest survived restarts and other processes and
  refused edits that re-reads could not clear (4 `E_STALE` errors on one
  bench cell, 0 after the fix). The bench niffler adapter also boots a
  private `XDG_CONFIG_HOME` under the harness root (`var/edit-config`,
  wiped per boot) so undo/seen state never leaks across runs that reuse
  session ids against re-prepared repos — the root cause of that wedge.
  Regression checks in `tests/t_edit.nim`.

- **plugins: untracked `go.work` so a manual `make` in a clone builds** —
  Go plugin clones carry the sibling-checkout SDK replace
  (`niffler.dev/sdk => ../niffler/sdk/go`), so a bare `make` in
  `var/plugins/<pkg>@<ref>/` failed. Install/update now write an untracked
  `go.work` redirecting the replace to this harness's `sdk/go` — `go.mod`
  stays pristine so the next `git pull --ff-only` in `plugin_update` still
  works; repos with their own committed `go.work` are left alone, and only
  the modules the manifest actually builds enter the use list.
  `plugin_update` also skips the GitHub release lookup for `file://` repos
  (offline-safe, no 30s API hang). `t_plugins` covers the no-releases branch
  path end to end: install at main, push a commit, update pulls in place and
  rebuilds, a second update is a no-op, and a manual `make` in the clone
  builds.

- **Bench: t30 verifier pinned to the base module set; private nats stderr
  logged** — the t30 verifier discovered modules from the mutable directory
  and read each module's profile/width from its own (editable) header, so
  deleting a module, adding one, or rewriting a header could shrink the
  checked surface — or let an empty directory pass vacuously. All 24
  filenames and their base profile/width values are now pinned; headers must
  still declare those values, so the directive is part of the contract
  rather than the agent's input (deleting a module and flipping a header
  both fail; pristine fails, the reference solution passes). And when a
  per-combo nats-server dies mid-run everything cascades
  (connection-closed publishes, PDEATHSIG teardown) with the cause pure
  guesswork — its stderr is now persisted to `<runRoot>/nats.log` with an
  exit line carrying code/signal.

- **discover: word-AND matching, compact empty-query directory** — query
  matching required the whole query as a verbatim substring, so a
  keyword phrase like "mechanical fan-out" (bench t13) matched nothing,
  and the fallback `discover {query: ""}` serialized the entire bus
  directory with 200-char teasers — 19KB into the conversation, twice.
  Matching now splits on whitespace and requires every word to appear
  in the component name or tool name/description (single-word behavior
  unchanged), and an empty query returns tool names only (19KB → 3.4KB
  measured); `component` and `tools` calls still return full
  hints/schemas. discover's description states the semantics, and the
  baseprompt Files paragraph restores the compact survey hint (bash
  cat/ls usage had risen 31% → 44% after it was dropped).

- **plugins: `plugin_update` pulls branch-tracked packages in place** —
  a package with no GitHub releases (tracking a branch like main)
  errored on `plugin_update`, forcing a manual `plugin_remove` +
  `plugin_install` round-trip to pick up new commits. `plugin_update`
  now falls back to an in-place `git pull --ff-only` of the existing
  clone, rebuilding components only when the pull actually moved HEAD
  (a no-op pull is reported without touching any component); tag-pinned
  packages keep the existing remove/reinstall behavior.

- **macOS builds: Linux-only Pdeathsig identifiers behind build tags** —
  `unix.Prctl`/`unix.PR_SET_PDEATHSIG` (sdk/go, components/nats) and
  `syscall.SysProcAttr.Pdeathsig` (mcp-bridge) were guarded only by a
  runtime GOOS check, which cannot stop Go from compiling those
  Linux-only identifiers for other targets — breaking every darwin
  build (make failed on the first Go component, since every Go
  component imports the SDK). Each is split into a `//go:build linux`
  file with the real implementation and a `//go:build !linux`
  no-op/degraded counterpart, mirroring the Nim SDK's existing
  `when defined(linux)` guard; Linux behavior is unchanged. The
  nats-server Makefile rule wildcards its `.go` files so the new
  build-tagged files are tracked as build inputs.

- **llm: syn-large context window; bench LLM timeout above the thinking
  ceiling** — `syn:large:text` resolved to the 128k conservative
  fallback (the models.dev catalog has no Synthetic entry, so the
  lookup falls through) while the model serves 524288 — the
  full27-syn-large runs executed with context 128000; `knownContext`
  now carries `syn:large:text` and `zai-org/glm-5.3-flash` at 524288.
  The niffler bench adapter now sets `NIF_LLM_TIMEOUT_MS` from the turn
  budget + 120s margin: at the 300s default a 19m41s high-effort
  thinking call died at the timeout and the bench retry re-did the
  entire turn (274s of redone work, +900s wall).

- **mcp-bridge boot crash-loop and eternal contract drift** — two field
  failures fed each other. The manifest listed `mcp-bridge` with an
  invented `autostart: false` key core silently ignores: core spawns
  every listed entry at boot, and a bare bridge (no `--server`) fails
  `validateName` and crash-loops under `restart: on-failure` (4344
  exit-2 deaths in ~70 minutes on one harness); the entry is gone — the
  Makefile builds the binary and the manager spawns bridges per server.
  Meanwhile `acceptContract` compared the stored contract against a
  fresh listing byte-for-byte: stored records omit empty tool/prompt
  lists (`omitempty` → nil) while `listContract` returns non-nil empty
  slices, so every server without prompts "drifted" on every boot,
  fail-closing the bridge into retiring forever. Both sides are now
  normalized; real drift still persists and restarts exactly as before.

- **Resume could clobber a transcript** — a failed store `list` during
  session resume was swallowed and read as an EMPTY conversation, so the
  next persist restarted ids at `000001` and overwrote the transcript
  (observed once as a whole conversation destroyed after a store reply
  outgrew the bus max payload and the list reply never arrived). The
  failure now propagates, and `seqNo` continues after the highest stored
  id (error-role records own ids the loaded list excludes).

- **Silent `(exit 2)` on heredoc commands** — the bash tool's subshell wrap
  `( cmd ) > capture 2>&1` glued the redirection onto a command-final
  heredoc delimiter when the command lacked a trailing newline: the heredoc
  swallowed the redirection, bash exited 2 before any output could be
  captured, and the model saw a bare exit code with zero explanation (then
  retried the identical broken command — observed five times in bench
  transcripts). The wrapper now puts the closing paren on its own line for
  heredoc commands, and a missing capture file yields an explicit
  "failed to parse or start" note instead of silence.
- **`discover` with `tools` but no `component` now searches every
  component** instead of erroring — callers know the tool name, not its
  owner; results carry the owning `component` per entry plus a `notFound`
  list. The fabric errors now teach the expected shape ("needs
  arguments.code or arguments.name") and "closed its output" points at
  guest crash/compile failures and the diagnostics field. `read_many`
  raised to 12 files with the actual count in the rejection.
- **Bench metadata: expert cells recorded `thinking: null`** —
  `thinkingFor("niffler-expert")` had no profile key (the sessions ran at
  the correct profile via the niffler adapter; only the recorded metadata
  was null). Profile lookup now falls back to the base harness, and the
  bench adapter retries the cli spawn once on transient ENOENT (a
  concurrent rebuild unlinks binaries mid-run).

- **Bench orchestration: scoped key checks, round-budget guard, run.json
  lane merge** — `resolveKeys` demanded `LLMGATEWAY_API_KEY` even for
  deepseek-only runs (now optional unless a selected model needs it, and
  the check is scoped to the run's models); the round loop could burn the
  whole task budget on adapter-internal retries and still re-enter the
  provider (a task-budget-reached round is surfaced budget-only, diff
  still verified); and relaunching a lane into an existing run id
  overwrote `run.json` metadata (now merged: combo union, earliest
  `startedAt`). `bench/config.json` gains medium/high thinking profiles.

- **Registration success is reported only from core's accepted catalog** —
  `cli`'s `wait` and `install` (and `plugin_install`'s post-spawn checks)
  used to treat raw `reg.*` announcements as proof that a component came
  up, so a rejected announcement or an existing same-name component could
  report success. Verification now polls the authoritative
  `catalog {op: components}` snapshot, a failed read clears both indexes
  instead of leaving stale entries available as proof, and confirmation is
  limited to the authoritative name lookup. `console`'s hand-rolled
  registration also published an invalid envelope shape and now speaks the
  real one.

- **cli no longer leaks an orphan catalog request** — when NATS's
  `NextMsg` timeout fired a hair early, `waitForRegistration` could run
  one more loop iteration with a ~1 ms bound and publish a second catalog
  request it never waited for; the next caller's request/reply pairing
  latched onto the fossil and timed out. Each request is now bounded by
  the remaining wait (t_cli_catalog went from 5/6 parallel failures to
  10/10 passes).

- **Per-entrypoint nim caches** — Nim's default cache collided on every
  `main.nim`, and scoping one cache per checkout still broke `make -j`,
  which compiles several entrypoints concurrently ("hidden symbol ...
  isn't defined"). The cache is now keyed by the project path relative to
  `config.nims` under `var/nimcache/`, so parallel builds cannot overwrite
  each other's objects while repeat builds stay incremental.

- **The runtime builder finds the SDK toolchain on macOS** — the builder
  invokes Nim outside the Makefile environment, so Futhark's libclang had
  no SDK headers; `config.nims` now supplies `SDKROOT` (and the Homebrew
  include/lib paths) for direct Nim builds, including agent-built
  components. PCRE is linked via the dev package when present instead of
  dlopen by bare filename, so machines with only `libpcre.so.3` build
  again.

- **Test helpers: `startComponent(logFile=...)` passes args through** —
  the logFile branch exec'd only the binary, dropping arguments (the cli
  printed usage and quit 2); args are now appended to the exec'd command.

- **Round-budget exhaustion ends the turn loudly** — a turn hitting
  `NIF_MAX_TURN_ROUNDS` used to fall off the round loop with no done
  event, no persisted message and an empty reply: from the outside
  indistinguishable from a hang (the "runner wedges" during the fabric
  authoring session). It now mirrors the token/call budget endings:
  turnError set, error item persisted (the model sees the cutoff on
  resume), done event emitted.

- **CLOEXEC sweep before every spawn** — the supervisor's /bin/sh spawn
  pipes were never close-on-exec, so every child inherited all earlier
  children's parent-side pipe ends (fabric sat at 67 stale fds; children
  even carried fds from the launching terminal). `cloexecInheritedFds()`
  runs in supervisor startChild, fabric's runExecutor and procutil
  runCmd — fabric 72→7 fds, flat across runs; the executor sandbox is
  now hermetic (RLIMIT_NOFILE=64 no longer tripped on inherited pipes).

- **Parallel waves resolve paths against the conversation workspace** —
  the `x-harness.parallel` fan-out skipped applyWorkspace, so parallel
  safe tools (read, read_many, files, grep, git_*) resolved relative
  paths against the harness root instead of the session workspace (bench
  transcripts caught DS t06-stackvm reading the 29KB Niffler README
  instead of the task repo — ~15k wasted tokens).

- **supervisor: a retired session runner could brick its conversation** —
  the rpNever retirement reap deleted `children[i]` instead of the
  recorded index, leaving a stale process-nil entry that `ensureRunner`
  read as "spawning" forever; the next turn then failed with
  "session runner for <id> did not come up", while unrelated supervised
  children (store, bash) silently dropped out of the supervisor. The reap
  now removes the retired child's own entry, and the runner idle clock
  stamps at turn end so a long turn is not counted as idle.

- **llm: Anthropic cache reads surfaced in the usage breakdown** — the
  Anthropic adapter normalized `cache_read_input_tokens` into
  `prompt_tokens` but never set the OpenAI-style
  `usage.prompt_tokens_details.cached_tokens`, so Claude sessions
  carried no cached-input breakdown downstream (conversation status
  events, expert token accounting, bench, clients). Reads now map to
  `cached_tokens`; cache-creation input is excluded (a write, not a
  hit).

- **persistMsg conflict resolution preserves the stored copy** — the typed
  `storePutRev` helper persisted the caller's raw value, so a
  rev-conflict retry dropped `conversationId`/`createdAt`/`telemetry`;
  it now persists the stored copy with the updated fields merged.

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
