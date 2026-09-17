# MAKI-STEAL — what to borrow from Maki

Analysis of [maki](https://github.com/tontinton/maki) (clone:
`~/git/harnesses/maki`), tontinton's Rust coding agent: ratatui TUI, smol
async loop, Lua plugin system (neovim-mirrored API), monty Python sandbox,
tree-sitter everywhere. ~7k lines of agent Rust + ~20 Lua plugins. The whole
codebase is organized around one thesis (its own words, `site/docs/content/token-economy`):
**a tool result does not cost its tokens once — it costs them again on every
turn until compaction** — so attack both multipliers: how much each step adds,
and how many steps there are.

The marquee ideas: the **`index` tool** (tree-sitter skeletons as a read
prefetch), **`code_execution`** (our fabric, but Python), **summary compaction
with a byte-budgeted tool-result collapse**, **partial output survives
interrupts**, and **tree-sitter-parsed bash permission scopes**. Measured
claims from the author: index adds 59 tok/turn, saves 224 tok/turn on reads
(net −165); rtk bash filtering saves ~50% of bash output tokens.

## The steal list (priority order)

### 1. `index` tool — tree-sitter skeleton with exact line ranges

Maki (`plugins/index/`): one tool, input is just `path`. Output is a compact
skeleton — imports, types with field lists (capped at 8), function signatures,
impl/trait/class methods — each line suffixed with `[150-165]` exact line
ranges, sections grouped (`Functions:`, `Types:`, `Impls:`), ~70–90% smaller
than the file. The prompt hints instruct: *index first, then `read
offset/limit` on the ranges you need*. Per-language extractors are small Lua
modules (`plugins/index/lang/{rust,python,go,typescript,…}.lua`, ~30
languages) keyed off tree-sitter node types, with a shared `indexer.lua`
engine; directories list instead (dirs first, instruction files filtered out);
unsupported extensions fail with "use read instead"; files >2 MB refuse.

Niffler today: no skeleton tool, no tree-sitter anywhere (only name-checked in
`docs/research/AIDER.md`). Models binary-search with `read offset/limit` or
burn full-file reads.

Borrow: an `index` component. Tree-sitter is a plain C library — Nim FFI is
trivial; grammars compile to per-language `.so` files we can vendor or load
from `lib/tree-sitter-*`. Language support must be **config, not code** (the
house rule): a manifest mapping extension → grammar → extractor. The extractor
rules themselves (which node kinds are signatures vs bodies, field caps,
section grouping) can start as a generic default + per-language overrides
instead of 30 hand-written Lua files. The doc-worthy nuance is Maki's output
contract: **every line carries exact start-end ranges**, so a single index
call replaces an entire explore-then-read round trip. Also steal `index` on a
directory path → listing (Maki's tool doubles as `list`), and the read-plugin
hint "use `wc -l` first to size your limit".

Effort: ~3–5 days for the FFI + generic extractor + rust/python/ts/go
overrides; measurable in bench as read-tokens/turn and rounds-to-green.

### 2. `code_execution` refinements — what monty does better than fabric

Maki (`plugins/code_execution/init.lua`, `maki-interpreter/`): pydantic/monty
(Rust-embedded Python subset) sandbox; every tool becomes an **async Python
function**, generated from the tool's JSON schema (`read(path, offset, limit)
-> str`, defaults rendered as `= None`, hyphens→underscores for MCP). The
sandbox preamble defines a custom `gather()` that awaits each call in its own
`try` — because stock `asyncio.gather` cancels siblings on first failure,
throwing away results the model already paid for; failures come back as
`[ERROR] …` strings inside the results list. Tool signatures are injected into
the tool description at request build (`describe()` callback), so advertised ==
callable by construction. Timeouts: **awaiting a tool call does not count**
against the script budget (the clock stops while parked in the host); memory
capped (50 MB), output capped (2000 lines/50 KB), fresh sandbox per run.

Niffler today: Fabric runs LLM-written **Nim** as a compiled native guest
with a framed stdio bridge, leases, selected-tool typed wrappers and a
`finish()` value. The guest has no NATS credentials and resource limits, but
approved code remains bash-class trust rather than a security sandbox. Its
trade-off is explicit compilation: models write Python more fluently than Nim,
and a compile error costs a round trip Maki never pays.

Borrow (into fabric, no rewrite needed):
1. **Keep error-isolated fan-out (`batch`) prominent** — Niffler now has a
   bounded `batch(...)` helper that returns per-call `ok/err` results without
   aborting siblings. Plain sequential `callTool` loops remain fail-fast by
   design when each result changes the next step.
2. **Tool-await time doesn't count against the guest deadline** — fabric's
   kill timeout currently includes time parked in the parent dispatch gate.
   Monotonic deadlines exist in the bridge; subtracting nested-call wait time
   makes long fan-outs viable under a tight guest budget.
3. **Signature injection is shipped** — selected tools receive generated,
   schema-pinned typed wrappers in `fabricmeta`; retain the idea when extending
   the structured guest API.
4. **Python guest dialect** (bigger call, flag for later): a monty-style
   embedded Python guest alongside the Nim guest. Monty itself is Rust (not
   linkable from Nim cheaply), but Wasm-based Python (wasmtime + CPython
   wasm, or RustPython) would give models their native scripting language
   while keeping the guest sandbox. Worth a research spike only after 1–3.

Effort: 1 day for (1)+(3), ~1 day for (2), spike for (4).

### 3. Summary compaction — the parts OCTOFRIEND-STEAL #3 didn't specify

Maki (`maki-agent/src/agent/compaction.rs`): compacts at
`context_window − reserved` where `reserved = max(compaction_buffer (20%),
min_output(model))` — the floor tracks the model's output cap so a
small-window model never compacts into an unserviceable request. The
compaction request itself is a **rewritten, shrunken transcript**: images
stripped, thinking stripped, tool results collapsed to a
**64 KB byte budget** for the recent tail (a count-based budget kept 3 huge
results and discarded 30 cheap ones — one giant MCP dump blew the window on
every retry), then the summary prompt. If that *still* overflows, it retries:
collapse tool results to 0, then drop oldest rounds — **retry-by-pruning**
rather than resending the same oversized request. The summary output budget is
capped at 16 384 (not the turn budget — no point reserving tens of thousands
on the most context-pressed request of the session). After compaction: a
synthetic user message asks the model to continue/restore todos, plus optional
`post_compaction_instructions`. The pre-rewrite log is archived to
`sessions/archive/<id>/<n>.jsonl` (newest 3, 32 MB cap) so dropped turns are
never lost. Empty summary ⇒ hard error, never swap history for nothing.

Niffler today: `core/conversation.nim trimContext` drops whole turns behind a
`[context trimmed]` marker (lossy); `docs/research/COMPACTION.md` §2 covers
the store/migration side. OCTOFRIEND-STEAL #3 already proposes
summary-compaction; Maki adds the load-bearing details.

Borrow: the four specifics — (a) reserved = max(buffer%, model min_output);
(b) **byte-budget** tool-result collapse (not count) with collapse-then-truncate
retry ladder; (c) fixed summary output budget; (d) archive-before-rewrite to
`var/sessions/archive/`. The compaction request should reuse our provider
retry policy and honor `Retry-After`.

Effort: folds into the OCTOFRIEND #3 estimate (2–3 days); these details add
~½ day and prevent the classic "compaction OOMs at 95%" failure.

### 4. Partial output survives interrupts — paid-for work is never wasted

Maki (`plugins/lib/maki/partial.lua` + every tool's `on_cancel` path): Esc on
a long tool, or its deadline firing, and everything it printed **so far**
still reaches the model, tagged `[cancelled by user; output above is partial]`
or `[timed out after Ns; …]`. Bash keeps its streamed lines, code_execution
its script output, a task subagent its half transcript. The wording is
deliberate: never claim output the model cannot see above the marker, never
call a bare cancel a timeout (the model must know whether retrying can help).

Niffler today: cancellation exists (`llm.cancel`, dispatch abandonment) but
partial tool output is discarded; the next turn starts from nothing.

Borrow: on tool cancel/timeout, return accumulated stdout (truncated) plus the
marker as the tool result. Touches the dispatch reply path once.

Effort: ~1 day. Bench-visible on long greps/builds.

### 5. Tree-sitter-parsed bash permission scopes

Maki (`plugins/bash/init.lua` `permission_scopes`, `maki-agent/src/permissions.rs`
`generalize_bash_segment`): `git diff && rm -rf /` parses into **two scopes** —
`git *` and `rm *` — via tree-sitter-bash, not string matching. Details that
make it sound: pipeline/list/redirect nodes are *walked through* (a trailing
`2>&1` hangs off the whole chain in the AST — treating it as a leaf would let
a `cd *` allow-rule cover whatever follows the `&&`); block forms (`if`,
`while`, subshells, command substitution) **stay whole and force a prompt** —
a `<cmd> *` rule is only safe when `<cmd>` names one program; redirects
attach to the last command of the chain; a bodiless `> log` becomes its own
scope (it truncates!); **any unknown node type forces a prompt** (safe
default); allow-always generalizes only command-word segments — never shell
keywords, never wildcards over blocks.

Niffler today: bash is approval-gated per command string (`components/bash`);
rules match whole commands, so `git *` grants everything the model can spell
after `&&`.

Borrow: segment bash scopes at approval time. We don't need tree-sitter on
day one — a conservative splitter (`&&`, `||`, `;`, `|` at top nesting level
only; anything with `$(...)`, backticks, or keywords ⇒ whole command, prompt)
captures 80% of the value with 100 lines of Nim; tree-sitter-bash later via
the same FFI as steal #1. The generalize rules (never wildcard
keywords/blocks/redirects) are the part to copy verbatim.

Effort: 1–2 days conservative, +2 days tree-sitter grade.

### 6. Subagent model tiers + structured outputs + visibility

Maki (`plugins/task/init.lua`, `maki-lua/src/api/agent.rs`): `task` takes
`model_tier: weak|medium|strong` — resolved via `resolve_model` which **clamps
to the parent tier** (`requested.min(parent.tier)`; a Haiku session cannot
spawn an Opus subagent), falling back through the provider's model registry.
`output_schema` installs a session-local `structured_output` tool on the
subagent; invalid calls are inline schema errors the subagent fixes in-run;
if it finishes without calling the tool, it gets **nudged** (max 2) before
the parent sees a failure. `thinking` inherits from the parent, also capped.
Concurrency bounded by a semaphore (default 8). UI: every subagent gets its
own chat window (`/tasks`, Ctrl-X) — "full visibility of subagents" is a
stated philosophy. Cost relay: live per-turn cost on the tool header while
running, one total per run on completion.

Niffler today: `agent_run`/`agent_spawn` subagents exist with depth guards and
steer, but they run the parent's model and return free-text.

Borrow: tier ladder + clamp on `agent` tool inputs; optional `output_schema`
validated by `components/schema_validation` with the nudge loop; live cost
annotation on the running tool header. The tier→model mapping belongs in
`components/models` (registry already exists).

Effort: 1 day tier+clamp, 1–2 days schema/nudge, ½ day cost relay.

### 7. Retry budgets split by what the error costs

Maki (`maki-providers/src/retry.rs`, the repo's newest commits): five
budgets — transient 5xx/network **unbounded** (an overnight agent should
survive a provider outage); 429 **with** `Retry-After` unbounded (sit out the
window the server named, capped at 1 h); 429 **without** a hint **bounded**
(no hint = spend cap; documented not to clear until next billing period);
stream-timeout bounded (**tokens may already be billed** — every retry costs
money); connect-refused bounded (indistinguishable from "local server not
started"; a typo'd `base_url` must end in an error, not an infinite spin).
`Retry-After` honored between a floor and a cap; each budget has its own
counter so budgets can't eat each other.

Niffler today: `core/retry.nim` — one shared budget, string-matching
classification, exponential backoff, no `Retry-After`.

Borrow: the Budget taxonomy verbatim; parse `Retry-After` (seconds or HTTP
date); keep unknown failures non-retrying (we already do).

Effort: 1 day.

### 8. Context-load hygiene: lazy subdir instructions, deferred MCP, memory tags

Three mechanisms, one principle — *the left column of every request stays
small; bodies live on disk until asked* (`site/docs/content/context`):

- **Lazy subdirectory instructions** (`maki-agent/src/agent/instructions.rs`
  `find_subdirectory_instructions`): at session start, load instruction files
  git-root→cwd (one per dir, priority AGENTS.md > CLAUDE.md > 8 others, plus
  gitignored `AGENTS.local.md`). The first time the agent *reads* a file under
  a subdir whose instruction file was never loaded, Maki pulls it in —
  monorepo rules cost nothing until someone works there. Bonus: directory
  listings **filter instruction files out** of the listing and re-inject them
  as annotations (`plugins/lib/maki/dir_listing.lua`), so they're discovered
  without polluting `ls` output.
- **Deferred MCP tools** (`site/docs/content/mcp`): >10 tools across servers
  ⇒ model sees one `tool_search` tool; matches load and stay for the session;
  subagents keep their own loads. Threshold configurable (`defer_tools`),
  per-server `always_load`. (Niffler's progressive tool discovery — direct
  set + `discover`/`invoke` + sticky promote — is the same idea, more
  general; the steal is the **threshold**: at ≤10 tools, searching costs more
  than it saves.)
- **Memory tool** (`plugins/memory/`): project-scoped (git-root hashed
  FNV-1a-64) markdown notes with snake_case **tags**; the system prompt
  carries **only the tag line** (50 tags max, 20 KB per file enforced with
  rewrite-hint errors); bodies load via `memory read`. Write rules for the
  memory dir pre-registered so notes don't prompt. A prompt hint tells the
  model to save gotchas proactively; compaction's post-message says "save
  important context to memory before it's lost" — memory is compaction's
  escape hatch.

Niffler today: no per-subdir instruction lazy-load; no memory tool (store/*
are persistence backends); discovery threshold absent.

Borrow: all three, but sized to us — subdir lazy-load is a `core/
conversation` + read-tool hook (~1 day); memory is one small component + a
`store` namespace (~2 days); discovery threshold is a constant + a check
(hours).

### 9. Per-turn pricing, peak-hour schedules, `/usage`

Maki (`maki-providers/src/pricing.rs`): **a turn is priced once, when it
runs; history is never re-priced** (DeepSeek doubles rates in peak UTC hours
— a total re-priced later would be a guess). Schedules are `const` windows
(`hours(22, 2)` wraps past midnight; a typo is a build error — their test
catalog uses `hours(1, 4)` / `hours(6, 10)`); multiplier applies
surcharge-only. Headless JSON carries `total_cost_usd`;
`/usage` breaks the session down.

Niffler today: usage events exist (`ev.*`), no per-turn priced ledger, no
schedules.

Borrow: price-at-turn-time invariant + stored per-turn cost on the session
record (our sqlite store makes this trivial); optional schedule table.
Effort: 1 day.

### 10. SSRF guard with DNS pinning

Maki (`maki-lua/src/api/net.rs`): webfetch blocks private/loopback/link-local/
metadata IPs — **including after redirects** (followed by hand, every hop
re-vetted) — with `allowed_private_hosts` opt-out. The load-bearing detail is
`DnsPin`: resolve once, vet that address, then **connect to the pinned IP**.
Without it, a zero-TTL DNS record answers public to the guard and
169.254.169.254 to curl a microsecond later (classic rebinding).
`https://example.com@127.0.0.1/` userinfo tricks handled.

Niffler today: `components/fetch` — http/https only, redirects followed, **no
SSRF guard at all**. The agent can be prompt-injected into reading
`http://169.254.169.254/...` or localhost services.

Borrow: block-list check on connect-time IP + DNS pin + manual redirect
re-vetting. stdlib `net` gives us everything; ~1 day.

### 11. Claude-Code-wire-compatible headless mode

Maki (`site/docs/content/headless`, `maki-agent/src/headless.rs`):
`--print --output-format {text,json,stream-json}` with byte-identical Claude
Code JSON fields (`total_cost_usd`, `num_turns`, `session_id`, …) — plus
`--input-format stream-json` speaking the Claude Code SDK protocol, so
orchestrators (Conductor, Windsurf, custom) work unmodified. Their pitch:
"scripts that parse Claude Code output work unchanged."

Niffler today: headless JSON exists but with our own schema.

Borrow: an adapter output mode matching Claude Code's wire format — it makes
niffler a **drop-in replacement** in every script/CI/orchestrator built for
the de-facto standard. Pure serialization work. Effort: ~1–2 days.

### 12. The prompt-slot system

Maki (`maki-agent/src/prompt.rs`): the system prompt is a template with named
**slots** (`{{tool_usage}}`, `{{efficient_tools}}`, `{{instructions}}`,
`{{after_instructions}}`…). Plugins contribute fragments via
`register_prompt_hint({slot, content})`; slots are either *singleton* (last
registration wins; built-in default used when none) or *aggregate* (all
entries joined). Two slot kinds per prompt (main/research/plan), rendered per
audience. This is how `index`/`code_execution`/`batch` teach the model their
existence without hardcoding: the plugin registers a hint into
`efficient_tools`, and the prompt renderer composes it.

Niffler now has named prompt slots in `components/systemprompt`: internal
components register aggregate or singleton fragments through `prompt_hint`,
and new conversations render them in deterministic source/key order. Existing
conversation prompts remain frozen; a registration affects only prompts
composed after it. The memory component remains deliberately deferred while
its scope and retrieval authority are researched.

## Where Niffler is already ahead

- **fabric security**: guest process with no NATS/creds, leases, depth
  guards, RLIMIT, quota-managed artifact spill — strictly stronger than
  monty's time+memory sandbox (monty has no filesystem/network at all, but
  also no native escape hatch).
- **Parallel dispatch** already exists (`x-harness.parallel` waves over
  distinct NATS inboxes, model-order commit, component replicas) — Maki's
  `batch` is a model-facing wrapper around the same primitive; we'd only add
  the sectioned per-child output format if models prove unable to emit
  parallel calls natively.
- **Progressive tool discovery** (`discover`/`invoke`, sticky promote,
  tool profiles) generalizes Maki's `tool_search` (which is MCP-only).
- **LSP component** ships; Maki has none.
- **Hashline-edit** anchors; Maki's edits are string-match + fuzzy fallback.
- **Durable background subagents** (`agent_spawn`/`agent_wait` + events);
  Maki subagents live only inside their parent session.
- **Multi-harness architecture** (NATS bus, 4 SDKs, replicas) vs Maki's
  single process — different weight class; not comparable directly.

## Smaller items worth a look

- **`fuzzy_replace` indent-drift rebase** (`plugins/lib/maki/fuzzy_replace.lua`):
  when `old_string` matches only after forgiving indentation drift, the
  replacement is **rebased into the file's frame** — drift map learned per
  column, unseen columns extrapolated from the deepest seen ancestor,
  `written_in_file_frame` detection avoids double-correcting. A deterministic
  complement to our edit cascade (which fixes old_string but would paste
  new_string with the model's wrong indentation). ~1 day in `components/edit`.
- **Tool result `restore()` + `state` round-trip**: every tool implements a
  restore function fed persisted state, so resumed sessions re-render tool
  outputs at full fidelity (batch even re-parses legacy sectioned text when
  state is missing). Our session replay could adopt the state round-trip.
- **`question` tool**: multi-question form UI, multiSelect, auto "custom
  answer" option, "(Recommended)" first convention, dismissal returns a
  distinguished result. Better than our yes/no approval modal for
  preference-gathering.
- **`read` micro-hints**: required `offset`/`limit` (no free-form reads),
  truncation messages that state the exact `offset=` to continue, "do not
  reread the same range". Zero-cost prompt engineering with measurable
  read-token wins.
- **`glob` sorts by mtime, newest first** — recently-touched files first is
  the right prior for "what is the model about to work on".
- **rtk integration** (`plugins/bash/init.lua`): rewrite bash through
  [rtk](https://github.com/rtk-ai/rtk) when installed (2 s budget, unsupported
  `find` flags guarded, skipped for `cargo … -- `). ~50% bash-output savings
  claimed; Maki plans native filtering anyway — so do we, watch their design.
- **`/btw`**: one-shot side question using chat history as context, answer
  not added to history. Trivial in our session model, nice UX.
- **Skill discovery compatibility** (`plugins/skill/init.lua`): reads
  `.claude/skills`, `.opencode/skills`, `.agents/skills` in addition to its
  own — zero-friction skill reuse across harnesses. We already read SKILL.md;
  add the sibling dirs.
- **Markdown slash commands with scope cascade** (`/project:<name>`,
  `/user:<name>`, git-root overrides cwd, `$ARGUMENTS`, frontmatter): we have
  commands; the scope-cascade + alias-via-`run_command` pattern is tidy.
- **`maki.pack.add` git packages with `pack-lock.json`** (install prompt
  before UI starts, commit pinning, name-conflict refusal, credential-in-URL
  refusal, project configs may not add packages): a cleaner supply chain than
  copy-paste plugin installs; our hermetic `file://` installs could grow the
  git+lockfile layer.
- **maki-docgen**: tool/plugin/lua-api/keybinding docs **generated from
  source** with a CI drift check (`just gen-docs-check`). Same spirit as our
  schema_validation; worth doing for the plugin API.
- **`edit_lines`/`insert_lines`** as opt-in line-number sub-tools (explicitly
  "do not use with batch") — complements string-match edit for big files; the
  opt-in gating keeps every request's tool-schema tax down.
- **Concurrent sessions with live-status picker** (`/sessions`: working /
  needs-input / idle, rows frozen while open, background-finish toasts) — our
  session model supports it; the UI affordances are the steal.

## Appendix — numbers Maki publishes (quote with care)

| Claim | Number | Source |
|---|---|---|
| index net token effect | +59 tok/turn added, −224 saved on reads (net −165) | README |
| index size vs full read | 70–90% smaller | tools doc |
| rtk bash savings | ~50% of bash output tokens (bash = 12% of total ⇒ ~6%) | README |
| batch cap | 25 children, no nesting | plugins/batch |
| code_execution limits | 30 s default (tool-await excluded), 50 MB, 2000 lines/50 KB | plugins/code_execution |
| compaction buffer | 20% of window, floored at model min_output | compaction.rs |
| tool-result collapse budget | 64 KB for recent tail | compaction.rs |
| summary output budget | 16 384 tokens | compaction.rs |
| compaction retry ladder | collapse-to-0 → drop oldest round ×3 attempts | compaction.rs |
| session archive retention | 3 newest per session, 32 MB | context doc |
| memory caps | 50 tags, 20 KB/file | memory_helpers.lua |
| MCP defer threshold | 10 tools across servers | mcp doc |
| subagent caps | 8 concurrent, 2 nudges, 3 schema errors | plugins/task |
| Retry-After cap | 1 h | retry.rs |
| task model-tier cost claim | strong ≈ 5× medium | task schema |

## Suggested sequencing

1. **Steal 4** (partial output) + **Steal 7** (retry budgets) — small,
   independent, immediately measurable.
2. **Steal 1** (`index`) — biggest token win; needs the tree-sitter FFI that
   Steal 5 also uses.
3. **Steal 3** (compaction details) — folds into the OCTOFRIEND #3 work.
4. **Steal 2.1–2.3** (fabric refinements) — quick wins while fabric is warm.
5. **Steal 10** (SSRF) + **Steal 11** (headless compat) — security and
   interoperability before the next feature wave.
6. **Steal 8** (context hygiene trio) + **Steal 12** (slots) — after the
   plugin API settles.
