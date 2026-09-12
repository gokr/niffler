# Changelog

All notable changes to Niffler are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
aims for [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
  via `prepare.mjs --input var/bench/swe/tasks-multi.jsonl`.

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
  SYNTHETIC_API_KEY. Cost uses borrowed V4.1 list pricing (0.15/0.6/0.003) —
  unverified against Synthetic's catalog. First run — Sym10, one-shot,
  `--thinking high`, official Docker grading: **niffler 10/10** (first perfect
  pilot score; 13091 solved, previously unsolved by every GLM lane; 13031 in
  392s vs 851-1122s) vs **claudecode 8/10** (11618, 13091). Report:
  `bench/reports/swe-sympy10-dsv41-high-report.md`.

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
