# OCTOFRIEND-STEAL — what to borrow from Octo

Analysis of [octofriend](https://github.com/synthetic-lab/octofriend) (`~/git/octofriend`),
Synthetic's coding assistant: single-process Bun/TS TUI, zero telemetry, any
OpenAI-/Anthropic-compatible provider. Two marquee ideas: **provider-neutral
conversation IR with "compiler" lowering**, and **custom-trained micro-models
that repair the main model's failures**. This doc maps what's worth stealing
into Niffler terms, with effort estimates.

## The steal list (priority order)

### 1. Repair-model hook in `edit` — recover what the cascade can't

Octo: when an edit's `search` string doesn't match the file, a tiny fine-tuned
model (`syntheticlab/diff-apply`) gets `{file, broken edit}` and returns the
corrected search — re-validated, applied silently, main loop never sees the
failure (`source/compilers/autofix.ts`, wired in `source/agent/trajectory-arc.ts`).
Malformed tool-call JSON gets the same treatment from a second micro-model
(`fix-json`) before the main model ever sees an error.

Niffler today: the deterministic fallback cascade in `components/edit` rescues a
closed set of known slips (trailing whitespace, indentation drift, unicode
punctuation, double-escaping, block-anchor + Levenshtein). Strong, free, but a
learned repair generalizes to unseen transcription errors.

Borrow: a repair **tier after the cascade** fails — cascade (free) → repair
model (cheap) → E_NOT_FOUND to the main model (expensive). The seam already
exists: match failure → hook → re-validate → apply. See "Repair-model hook:
what it entails" below for the two implementation options (hosted small model
= ~a day; trained micro-model = a real project, template committed in-repo).

Effort: 1 day for option A (hosted model), weeks for option B (train our own).
Measurable in bench: E_NOT_FOUND rescue rate + rounds-to-green on full30.

### 2. History-time read dedup at prompt-build

Octo rewrites history when building each request (`compilers/optimize-files.ts`
+ `octo-ir-prompts.ts`): every read of a path that was read earlier in the
conversation is collapsed to the literal string `"File was successfully read."`
— only the **latest** read per file keeps its content; every mutation echoes
just `"$path was updated successfully."`.

Niffler today: `[unchanged]` stubs fire at *execution* time (same-bytes
re-reads), but every distinct-content read of a file keeps its full bytes in
history forever. A long session that revisits files accumulates redundant
copies on the wire.

Borrow: post-process the message list before each LLM call — for `read` tool
results, keep only the newest copy per resolved path, replace earlier ones with
a one-liner. Niffler wrinkle: single-read results are bare strings (no path
echo), so correlate `tool_call_id` → read args → resolved path while walking.
Keep edit diffs in history (they're ground truth Octo throws away).

Effort: ~1 day in core prompt-build + tests. Measurable via the ctx accounting
events (prompt-token growth rate over turns).

### 3. Compaction-by-summary instead of whole-turn trim

Octo auto-compacts at 90% context by **summarizing** the dropped history into a
first-class checkpoint message (streamed LLM call), with explicit
"resume exactly where you left off" instructions
(`source/libocto/compilers/autocompact.ts`).

Niffler today: `core/conversation.nim trimContext` drops whole turns (keeping
tool_call_id pairing) and inserts a `[context trimmed]` marker — lossy, task
state gone.

Borrow: compaction component that summarizes what trim would delete, inserting
the summary where the dropped turns were. The trim threshold machinery, usage
accounting, and context events already exist.

Effort: 2–3 days (summary call must share the session's provider; watch the
chicken-and-egg when the window is already nearly full — summarize with the
same model at low effort, or a second flash provider).

### 4. LSP component — compiler/lint errors without burning test runs

Two reference designs now exist. Octo ships per-server dynamic tools
(`lsp-diagnostics`, `lsp-definition`, ... registered only when a server is
detected; diagnostics included). DeepSeek's harness (`~/git/deepseek-harness`,
see the dsh addendum below) takes the opposite, and for us better, shape: **one
`lsp` tool with an `operation` enum**, a provider registry keyed by file
extension, and language support as **configuration, not code** — which matches
the requirement that adding language X must be a plugin/config act, never a
schema change.

Niffler has zero LSP today. Diagnostics is the highest-value single tool
(compile/lint errors without a test round); navigation (definition/references)
is the precision win once edits start touching unfamiliar code.

Borrow plan, requirements, prior art, and the plugin-friendly design: see
"LSP component: requirements and prior art" and "dsh addendum" below.
Effort: diagnostics+definition MVP ~500–800 lines (2–4 days incl. tests);
`onDemand: true` tools fit the catalog; graceful "no server for *.xyz" errors
handle unconfigured languages.

### 5. Background process tools

Octo: `background-process` (start detached with a label) + `manage-background-process`
(poll **drains only output appended since the last poll**, optional wait-up-to-N-ms
for activity, kill with grace period, list; exit events surface as activity).
Long-running servers/watchers stop blocking turns.

Niffler today: bash blocks with a timeout; dev servers are awkward.

Borrow: a `processes` component (or bash extension): spawn detached, drain-per-poll,
kill. Effort: ~2 days. Also useful to the bench (test watchers).

### 6. Quota/balance guard

Octo parses provider quotas (5-hour rolling + weekly credits) into UI state
(`source/utils/quota.ts`). Directly motivated by today's bench 402: three cells
died mid-run on an exhausted DeepSeek wallet. Our preflight probes 401/402/403
once; a **mid-run balance probe** (or credit estimate from per-cell usage) would
stop the run at a boundary instead of stranding cells.

Effort: hours for a bench-side running-cost guard; a provider-quota component
depends on what each provider exposes (DeepSeek: balance endpoint; Synthetic:
quota endpoint; llmgateway: nothing standard).

### 7. The IR/lowering architecture (the big refactor)

Octo stores the conversation as provider-neutral IR; "compilers" lower it to
chat-completions / Anthropic / Responses formats with per-target quirks
isolated and compiletest fixtures. Payoffs: mid-conversation model/provider
switching without history surgery; one chokepoint for history optimizations
(steal #2 lives here); strict invariants checkable in one place (e.g. their
documented rule: never orphan a tool message from its tool_call_id — strict
backends 400 on it).

Niffler's transcripts are OpenAI-shaped (assistant `tool_calls`, `usage`).
The models/provider components already isolate endpoints; the transcript
format is the remaining coupling. Neutral-IR is worth it when mid-session
model switching across providers becomes a priority — not urgent.

### Smaller items

- **Batch atomicity with skip records**: if any tool call in a parallel batch
  fails validation, ALL are skipped and the model retries with explicit
  `tool-skip-output` records ("One of your other tool calls was invalid...").
  Protective for multi-edit plans; costs independence between calls.
  Niffler applies what succeeds. Consider for edit-only batches.
- **`create` refuses existing files** (distinct from whole-file `rewrite`,
  whose description frames it as the "struggling, last resort" escape hatch).
  Niffler's `write` does both with no distinction.
- **Vision reads**: images attached to tool output with modality gating and
  graceful omission notes. Niffler refuses binaries outright.
- **Web-search tool** with typed highlights/published dates; dynamic tool
  presence driven by config.
- **Strict SKILL.md frontmatter validation** (name pattern must match
  directory, description length caps) — niffler skills are comparable; steal
  the validation strictness.

## Where Niffler is already ahead

- **Staleness**: byte digests + seen-store persisted across restarts vs their
  in-memory mtime timestamps (mtime lies; `touch` defeats it).
- **`undo_last_edit`** — persisted, stale-refusing. Octo has nothing.
- **Verbatim reads** (no line numbers) for exact-match editing. Octo
  line-numbers its reads and then requires the model to strip prefixes for
  exact `search` — an error factory (which their diff-apply model exists to
  absorb; niffler avoids creating it).
- **Read batching**: canonical `reads` array with union semantics. Octo's
  `read`/`partial-read` are one-file-per-call, no batch form.
- **The bus**: NATS components, session store + replay, expert advisory peer,
  fabric fan-out, and the bench harness. Octo is a single-process app: no
  session store, no expert, no bench.
- **Cascade cost**: deterministic rescues are ~free; their repair always pays
  a model call per failed edit.

## Repair-model hook: what it entails

Option A — **hosted small model, no training** (~1 day):
- `edit` gains a repair hook: cascade exhausted → build the repair prompt
  (file bytes + broken edit, response = `{success, search}` or `{success:false}`,
  ambiguity must refuse) → call a configurable flash model at temperature 0 →
  validate → apply. Config: which provider/model, cost cap, enable flag.
- Cost: one small-model call per *unrescued* failed edit (~0.5–2k tokens).
  With the cascade ahead of it, that's rare.
- This is a complete, shippable feature; the trained model can replace it later.

Option B — **train a micro-model** (the Octo path; weeks, not trivial, but the
pipeline is the interesting part and their template is committed):
1. **Data**: generate broken edits synthetically from real repos — take valid
   search/replace pairs that match, corrupt the search with the real failure
   taxonomy (whitespace/tab drift, indentation shift, unicode punctuation,
   truncation, double-escape, stale bytes), label with the ground-truth fix;
   ~10% ambiguous → labeled `{success:false}` (teaching refusal matters).
   Octo: up to 5 breaks, 90/10 train/eval, over their repo + a repos/ corpus.
   Niffler corpora: this repo, bench task repos, and — uniquely — **real failed
   edits mined from the store** (actual model transcription failures, not just
   synthetic ones).
2. **Training**: small base (1–7B), SFT/LoRA (axolotl / unsloth / HF TRL),
   temperature 0, GPU time in the hours not days for this size.
3. **Serving**: HF or any OpenAI-compatible host behind the same repair hook
   as option A — the hook makes the swap trivial.
4. **Eval**: unit eval on held-out broken edits + end-to-end in the bench
   (rescue rate, rounds-to-green, added cost/latency per rescue).

Verdict: do A now, decide on B with real rescue-rate data from the bench.

## LSP component: requirements and prior art

What a minimal diagnostics component needs (the wire protocol is simple; the
fiddly parts are state and lifecycle):

- **JSON-RPC 2.0 over stdio with LSP framing** (`Content-Length:` headers,
  `\r\n\r\n` delimiter, base-none encoding).
- **Lifecycle**: `initialize` (capabilities negotiation, workspaceFolders,
  rootUri = conversation workspace), `initialized`, `shutdown`/`exit`;
  spawn per (server, workspace root) lazily on first tool call; restart on
  crash; kill on component stop.
- **Text sync**: `textDocument/didOpen` (send current bytes + version),
  `didChange` (full-text sync is fine — set the capability), `didClose`.
- **Diagnostics**: accept `textDocument/publishDiagnostics` push notifications
  and/or poll `textDocument/diagnostic` pull; wait until the version reported
  covers the current file version, with a timeout; format severity + line/col
  + message + source. Cold starts (gopls on a big repo) can take tens of
  seconds — surface "warming up" instead of a timeout error.
- **Niffler integration**: `newComponent("lsp")`, read-only tools (no
  approval), `workspace: pathFields` for path resolution, `onDemand` tools,
  server registry config (command, extensions, root markers — Octo's
  `lsp-server-registry.ts` is a good list to copy), graceful
  "no language server for *.xyz" errors. Share one server process across
  sessions in the same workspace (they're expensive), guard with a lock;
  isolate per workspace.
- **Trap**: LSP positions are **UTF-16 code units**, not bytes or runes —
  matters the moment we return ranges the model might act on; for diagnostics
  text output it only matters for non-ASCII files.
- MVP = `lsp_diagnostics` only. Then `lsp_definition`/`lsp_hover`/
  `lsp_references`/`lsp_document_symbol` (each is one request type), then
  call hierarchy (needs `prepareCallHierarchy` + incoming/outgoing).

Prior art:

- **Go** (strongest ecosystem, as servers): `gopls` is the reference
  implementation of a language server; `go.lsp.dev/protocol` is a complete
  client+server protocol library; `sourcegraph/jsonrpc2` and
  `golang.org/x/tools/internal/jsonrpc2` (copied widely) for the transport.
  If the component were written in Go (niffler already builds Go components:
  `nats-server`, `mcp`), `go.lsp.dev/protocol` gives the whole protocol for
  free — client side included.
- **Nim**: `nimsaem/lsp` (nimble `lsp`) — protocol types + JSON-RPC, used by
  `nimlangserver`/`nimlsp`; maintenance is modest but it covers the protocol
  layer. `nimlangserver` itself is proof the hard parts work from Nim.
  Hand-rolling framing + the handful of requests we need in Nim is also
  realistic (Octo did exactly that in TS in 615 lines).
- **TypeScript**: `vscode-languageserver-protocol` / `vscode-jsonrpc` are the
  canonical client+server; Octo uses only `vscode-languageserver-types` for
  types and hand-rolled the client — evidence a minimal client is small.
- **Python**: Microsoft's `multilspy` — an LSP client wrapper built
  specifically for coding agents (multi-server, sync wrappers). The closest
  prior art for "LSP as an agent tool"; worth reading for the state-machine
  and "wait for diagnostics version" logic regardless of implementation
  language.

Recommendation: diagnostics-first MVP in a `lsp` component; if written in Go,
start from `go.lsp.dev/protocol`; if Nim, hand-roll framing + copy dsh's
seam/provider/tool split (see the dsh addendum below — it is the better
template for us).

## Design principle: language X is always a plugin or config

Now an architecture invariant (AGENTS.md, "Language-agnostic core"): shared
components never encode knowledge of specific languages — no language lists,
grammars, or per-language branches. Concretely for the LSP component:

- **Core `lsp` component = the generic seam.** It owns framing, lifecycle,
  capability negotiation, transient document sync, and the normalized
  result/error contract. It knows nothing about any language.
- **Registry = data.** Server entries (command, extension → languageId map,
  initializationOptions) live in config, shipped with sane defaults (gopls,
  typescript-language-server, pyright, rust-analyzer, clangd, nimlangserver,
  bash-language-server) and user-extensible by editing config — adding Solidity
  or OCaml is a config entry, never a code change.
- **Exotic transports = plugin components.** Anything that answers the same
  normalized `lsp.query` contract (HTTP-hosted server, in-process analyzer,
  bespoke indexer) can register as a provider plugin; the stdio driver is just
  the first provider.
- **Model surface stays fixed.** One `lsp` tool with an `operation` enum,
  regardless of how many servers/languages are configured — dsh's rule that
  "a provider swap never changes how the model asks".

The same pattern (registry + provider seam + fixed tool surface) is the
template for any future language-aware feature: formatters, tree-sitter
navigation, build/test invocation profiles.

## dsh addendum (deepseek-harness) — how DeepSeek does LSP

`~/git/deepseek-harness` is DeepSeek's open-source agent harness (`dsh`): a
pnpm monorepo on Cordis ("everything-is-a-plugin", `ctx.<service>` seams).
Its LSP subsystem (`packages/lsp/{lsp,lsp-stdio,tool-lsp}`, design doc
`docs/subsystems/lsp.md`) is the cleanest reference design we found.

**Structure — capability seam, not a monolith:**

- `lsp` — the service (`ctx.lsp`): a provider registry plus one normalized
  `query()`. Knows no protocol, no processes.
- `lsp-stdio` — one generic provider: drives *any configured* stdio language
  server (framing, connection, instance lifecycle, LSP↔normalized translate;
  ~1.6k lines incl. tests). Ships zero servers — deployments configure them.
- `tool-lsp` — the single model-facing tool. Owns the name, schema, prompt
  guidance, rendering, caps.

**Rule: "providers register capabilities, not tools."** A provider swap never
changes how the model asks. The seam exposes exactly four operations and **no
generic JSON-RPC escape hatch** — LSP vocabulary cannot leak to the model.

**The four operations (closed union):** `goToDefinition`, `findReferences`,
`goToImplementation`, `hover`. Navigation only — **no diagnostics, no symbols,
no call hierarchy** (their doc: "they need different schemas"). We want
diagnostics more than they do; take their shape and add it as a fifth
compile-enforced operation.

**Notable mechanics worth copying:**

- One `lsp` tool with an `operation` enum — never per-server dynamic tools
  (Octo's approach), so the frozen toolset and prompt guidance never change
  when servers are added.
- Coordinate conventions at the boundary: model-facing **one-based** UTF-16
  cursor; wire **zero-based** UTF-16; conversion lives in the tool, stated in
  the description ("an off-symbol position may return no results").
- **Transient document lifecycle**: `didOpen` (current bytes) → request →
  `didClose` per query, no file watching or persistent sync state; capability
  check (`supportsTransientOpen`) with a clear error if the server can't.
- **One server instance per (provider, canonical workspace)**; queries
  serialize through a single queue per instance so a cancellation can kill the
  teardown without killing unrelated work; distinct instances run in parallel;
  pool + single-flight.
- `findReferences` always includes the declaration — enforced inside the
  provider, no caller flag (removes a model footgun).
- Result caps: `maxLocations` (100), `maxResultChars` (16000), tool timeout
  60s; rendered output carries truncation metadata.
- Structured `LspError` codes (`LSP_UNAVAILABLE`, `LSP_CONFLICT`,
  `LSP_MALFORMED_RESPONSE`, ...) — callers route on codes, never messages.
- `resolvedWorkspaceUri` on location results — symlink-safe relativization.
- System-prompt guidance positions LSP as a precision aid, not a default:
  "Use search/read for ordinary navigation. Use lsp when textual matches are
  ambiguous or before a change requires precise definitions, implementations,
  or references."

**Other dsh things worth noting (not analyzed in depth):**

- `bash-persistent` / `pwsh-persistent`: shell state (cwd, exported env)
  persists across calls per agent — same family as Octo's background
  processes; dsh also has `terminal_open/read/close/list` for named
  persistent sessions (a `gdb` or REPL session that survives turns).
- `run_code` (sandboxed code runtime), `read_image`, plan mode
  (`exit_plan_mode`), `ask_user_question`.
- `cordis_define/undefine/run/inspect_*` tools: the agent can **modify its own
  plugin graph at runtime** — the most radical self-extension story we've seen;
  Niffler's `builder`/`core.spawn`/`core.remove` already cover the same ground.
