# STEAL-WAVE-2 — what the harness shelf shipped since our last read

Status: **proposal**, unscheduled. Candidates here are promoted into
[PLAN.md](../PLAN.md) only with a bounded scope and an acceptance gate; the
steady unscheduled list stays in [BACKLOG.md](BACKLOG.md).

## Why this document exists

Every steal doc we have ([MAKI](MAKI-STEAL.md), [DSH](DSH-STEAL.md),
[OCTOFRIEND](OCTOFRIEND-STEAL.md), [CODEWHALE](CODEWHALE.md),
[REASONIX](REASONIX.md), [PI-NEXT](PI-NEXT.md),
[PI_FEATURE_SCAN](PI_FEATURE_SCAN.md)) was written against a *pinned* commit
of a checkout in `~/git/harnesses`. On 2026-10-29 those pins were all moved
forward for the first time since 2026-10-09 — up to 8 369 new commits in one
repository. This note reads that delta only: the ideas that did not exist when
the original steals were written, plus the ones upstream has since
*independently converged on* (which raises their confidence for us).

Method: `git log <old-pin>..HEAD` per checkout (subjects, then the diffs and
docs of the commits that mattered), filtered against what Niffler actually has
today in `core/` and `components/`. Numbers in parentheses are commit
subjects you can read in the clone.

## The ranked list

### 1. Fabric: background runs, durable runs, resumable runs

**Evidence.** pi-fabric, five commits in nine days: *move running
`fabric_exec` programs to the background* (`db676bb3`), *`fabric_exec` as a
replay-safe durable extension* (`cc030182`), *resume interrupted
`fabric_exec` from a crash journal* (`d6894e84`), *rerun an interrupted
read-only `fabric_exec` once* (`15682b51`), *let programs park and resume an
idle hosted run* (`8710f953`).

**What Niffler has.** `components/fabric/fabric.nim` runs one guest
synchronously to an absolute deadline (`maxTimeoutMs = 300_000`, default 4
min) and kills the whole process group on expiry. A 20-minute fan-out across
200 files cannot be expressed; a run that hits the cap loses everything it
computed, because only `finish()` reaches the conversation.

**Why it matters here more than upstream.** Our benchmarks hand exactly this
job to fabric (t28–t30 fan-out, ~450 KB intermediates). The 5-minute ceiling
is the reason those tasks fall back to scripted bash.

**Shape.** `fabric {background: true}` → returns `runId` immediately; guest
progress lands as `ev.fabric.run` events; the settlement arrives as a notice
in the same lane as `agent` settlement (so the existing wake/drain machinery
carries it). Durability: a `fabricrun` store record written at launch and on
each finished call, so a runner restart can resume a replay-safe (read-effect
only) program and otherwise report the partial result rather than nothing.

**Effort.** 3–5 days. **Gate.** `make test-fabric` plus one bench cell
(t29-logrollup) green under `background: true`.

### 2. Batch independent reads into one assistant message

**Evidence.** The `full31-syn-ds41-droid` run (2026-10-29): Droid issues
**4.4 tool calls per assistant message** and finishes a task in 1.9 LLM
messages; Niffler issues 1.2 and takes 6.5. Droid's model reads files
(`read` 4.6/cell), ours shells out (`bash` 4.2/cell). The comparison is in
`bench/reports/full31-syn-ds41-droid-analysis.md`.

**Why it is a steal and not a bug.** Niffler already dispatches parallel tool
calls (`x-harness.parallel` on `read`/`grep`; 1.4 multi-call messages per
cell, max 5 calls in one message) — the machinery works. The difference is
batch *size*: Droid's t06 stream opens with five `tool_call` frames after one
assistant message; our t06 transcript batches pairs. The base prompt already
says "batch independent calls in one reply", so the missing ingredient is
specificity, not the rule.

**Shape.** A concrete shape beats an adverb: say what a good batch looks like
("if you need three files, ask for three in one message"), and put it beside
the tool description (`read`'s `- paths:` form, `x-harness.hint`) rather than
only in the preamble. Same edit as #3's neighbour finding: the base prompt's
"Use bash for execution/computation, not `cat`/`sed` file I/O" is equally
ignored — our bash heads across 31 cells are `pwd` 26, `cd` 20, `cat` 19
against `read` 2.0/cell. Both are wording experiments, both are measurable on
the same lane, and both need no core change.

**Effort.** Half a day including the re-run. **Gate.** On the same 31 tasks:
fewer LLM messages per cell at equal pass rate, `bash` calls per cell down,
`read` calls per cell up, and no rise in uncached input.

**Caveat to keep honest.** Droid's batching is only half its story — it also
carries a 60k-token fixed prefix, which is why its *total* tokens are 1.75×
ours. We want its round-trip count without its prefix, and that is exactly
what a batching hint can deliver.

### 3. Instruction budget with visible truncation

**Evidence.** CodeWhale *per-scope instruction budgets with visible
truncation* (`7b9d55d65`, docs `32fb2d120`); *skills: tell the model when the
ambient index shortens descriptions* (`423dff6af`). codex *omit descriptions
from skill catalogs* (`2edc8dcb0`).

**What Niffler has.** `components/systemprompt` walks the ancestor chain
(16 files, first hit per directory) into one blob with a single 200 000-byte
truncation marker. One monorepo `AGENTS.md` can therefore evict every other
instruction file, silently, and the truncation is invisible to the model.

**Shape.** A per-file byte budget (config domain on `systemprompt`) with a
`N lines elided` marker *inside* that file's section, plus a total budget that
scales the per-file allowance. Same treatment for skill descriptions in
`discover`'s registry: first sentence + `x-harness.hint`, already the rule,
extended to a byte cap per entry.

**Effort.** 1 day. **Gate.** Unit test on the composer + one prompt-preview
diff showing the marker.

### 4. Spend cap across the session tree

**Evidence.** pi_agent_rust *enforce shared model spend limits across session
trees* (`f28fc46e`), *persist late model charges to their source sessions*
(`32e8884f`), *modality-aware spend accounting* (`9eb1c397`). OpenHands
*condenser and verification per profile* (agent profiles carry the policy).

**What Niffler has.** Delegation is bounded by *shape*, not by cost:
`NIF_AGENT_MAX_DEPTH`, `NIF_AGENT_WAKES`, per-call timeouts. Usage is tracked
per conversation (the header's `promptTokens`/`cachePrompt`/`cacheRead`
counters, folded from provider-reported `usage`), but there is no ceiling and
no accumulated total across a delegation tree.

**Shape.** Accumulate provider-reported cost into `sessionmeta.spend`
(children roll into their root at settlement, late charges reconciled the way
`32e8884f` describes), and let `agent_spawn`/`agent_run` refuse with a normal
tool error once `NIF_AGENT_SPEND_USD` (per tree) is exceeded. Read-effect
tools stay allowed so a capped child can still report.

**Effort.** 2–3 days. **Gate.** A test that spawns children against a mock
provider and asserts the third spawn is refused with the accumulated number.

### 5. Durable turn queue instead of an instant `busy`

**Evidence.** MiMo-Code *turn-queue: durable scheduling and subagent waiting*
(`949a3bcc`); codex *retry transient environment startup failures on the next
turn* (`4e2dfd223`).

**What Niffler has.** A second turn in the same conversation is refused with
`busy` — the human's message is *dropped* unless the UI retries. The refusal is
correct for the fabric/agent nested-call path (which must not block), wrong for
a person typing while a long turn runs.

**Shape.** `session {queue: true}` (UIs set it) appends a queued message record
and returns `queued`; when the turn closes, the runner starts the next queued
turn. The invariant "turns never nest" holds unchanged; ordering is store
order; a cancel clears the queue.

**Effort.** 1–2 days. **Gate.** Contract test: two overlapping calls, one
turn, both delivered, in order.

### 6. An ACP endpoint (editor/agent protocol)

**Evidence.** gemini-cli (`packages/cli/src/acp`), qwen-code (*feat(acp): run
the stop point of fresh prompts on the client's chain*, `cc2a80e61`),
pi_agent_rust (*feat(acp): route native file tools through editor buffers*,
`22e682c8`), and Droid ships `--output-format acp` / `--input-format
stream-jsonrpc` in v0.251.0. ACP (Agent Client Protocol, Zed's) is becoming
the standard editor↔agent seam.

**What Niffler has.** Nothing — `grep -ri acp` finds no hits outside vendor
trees. Our integration story is "write a NATS client", which is fine for UIs
and impossible for editors.

**Shape.** A thin ACP adapter as a *component* (`acp`), not core: it speaks
ACP on stdio and forwards `session`/`steer`/`approval` to the existing
subjects. Nothing new in core; the protocol stays outside the envelope.

**Effort.** 2–3 days for initialize/session/prompt/update/cancel;
`session/request_permission` maps onto the existing approval subject.

### 7. Sandbox hardening bundle (five small, independent fixes)

**Evidence.** CodeWhale, all since the pin: *give read-only shell runs outbound
network* (`092312398`), *keep sandboxed background jobs alive after their
spawning worker exits* (`ff466b2ed`), *protect git hooks, git config and
`.codewhale` from sandboxed writes* (`0e9c5beba`), *mask a symlinked credential
directory at its resolved path* (`6f1e1094c`), *say when bubblewrap could not
set up the sandbox* (`0fcfc1e46`), plus a NoNewPrivs child matrix. codex:
*skip read-only volume-root expansion in the MXC sandbox* (`23934d31b`).

**What Niffler has.** Opt-in bwrap guard (`niffler-sandbox`) with launch-time
checks, env clearing, network isolation and exact-path masks from
`NIF_BASH_SANDBOX_MASKS`; guarded background execution is *refused*
(`guard.nim`: "run synchronously"); unmasked host root readable (documented,
deliberate).

**Shape.** Each item is a small, testable change to `bash` +
`niffler-sandbox`: (a) masks matched on the *resolved* path as well as the
literal operator path, so a credential directory reached through a symlink is
still masked (upstream's `6f1e1094c` is the bug report); (b) deny writes to
`.git/hooks`, `.git/config`, `.gitattributes` — a sandboxed command must not
be able to install a hook that later runs *outside* the sandbox; (c) a
read-only mode that keeps a network namespace, for fetch-style read tools;
(d) a bwrap setup failure reports *why* on stderr instead of a bare refusal
(the `guard.nim` messages are already specific — the gap is inside the
helper); (e) "background commands are refused" is correct today, and
`ff466b2ed` is the prerequisite work for ever lifting it (children must
outlive their spawning worker *and* keep PDEATHSIG discipline).

**Effort.** Half a day each. **Gate.** The existing sandbox matrix in
`tests/`, one row per item.

### 8. `ask_user` — a structured question, not a y/N approval

**Evidence.** Droid v0.251.0's `AskUser` tool; pi-fabric *let a parent hold a
routed child question with no expiry* (`8afe5d00`) and *give a routed Pi child
the question tool* (`67b4d39e`); CodeWhale's handoff envelopes.

**What Niffler has.** `x-harness.approval` (terminal y/N, session private
subject, deny when nobody is reachable). That answers "may I?", never "which
of these three?".

**Shape.** `ask` tool: `{question, options[], default}` → the runner publishes
to the same private UI subject family as approval, waits with the same idle
pumping, and on timeout returns the default marked `unanswered: true`. The
turn stays resumable; no new store kind.

**Effort.** 2 days. **Gate.** Contract test with a scripted UI answering, and
one with nobody answering (default + marker).

### 9. Goal / loop autonomy — a decision, not a task

**Evidence.** opencode `/goal` *with a client-side done check* (`8de032397`)
and *schedule prompts from agents* (`fbb47c995`) + *scheduled tasks storage*
(`4585c316c`); CodeWhale's durable goal object (`a7fe9d831`, `2497fdd86`,
`3824cdea0` *scheduled messages as turns*); Droid's `Loop` tool (cron
expressions, pause/resume/cancel) and `--mission` (worker + validator models).

**What Niffler has.** A wake turn for pending settlements and nothing else
autonomous. That was deliberate: every autonomous turn is an unbounded cost
and an unbounded safety surface, which is why #3 and #4 above are prerequisites.

**Shape if we do it.** A `goal` field on the conversation header (frozen
prefix untouched — it is not prompt text), a supervisor idle tick that starts
a turn only when a goal is open *and* the wake+spend budget allows, and the
same decline path as wakes (persist nothing, report why). Loop/cron is the
same mechanism with a time trigger, so it should reuse `processes`' idle seam
rather than add a scheduler daemon.

**Recommendation.** Do not start here. Ship #3 and #4 first, then re-read
this section — the same features without a spend cap are the failure mode the
whole design avoids.

### 10. MCP: per-conversation scoping and elicitation

**Evidence.** codex *per-chat leases for shared MCP connections*
(`8fdf64729`), *apply session plugin overrides during MCP config refresh*
(`2e764b794`); pi_agent_rust *user-approved form elicitation* (`edfdc48f`),
*sampling through the invoking agent* (`d5ea9d07`); MiMo *deferred MCP tools
through `mcp_tool_use`* (`cd72e855`) with *concise readiness hints*
(`4e58a801`).

**What Niffler has.** `mcp-bridge` with env refs, a cached catalog, lazy
per-session connect and idle close (`b.detachAndClose`, `idleMs`), so
lifecycle is already conversation-aware. Two gaps: `grep -i
'elicit|sampling|roots'` in `components/mcp` and `components/mcp-bridge`
finds **nothing** — an MCP server that issues `elicitation/create` or
`sampling/createMessage` has no path to a person today — and the tool surface
(`expose: ondemand|direct`, `NIF_MCP_DIRECT_THRESHOLD`) is server-global
config, not resolved per conversation.

**Shape.** (a) A per-conversation enable/disable + effect overlay resolved at
catalog build, so two conversations can use one server with different
surfaces, re-resolved by `mcp_refresh` without a process restart; (b)
elicitation/sampling mapped onto the same private UI lane as approval (#7) —
a sampling request is a model call the *client* makes, so it must be
attributed to the calling session's usage or refused.

**Effort.** 2–3 days for (a); (b) only after #7 lands.

### 11. Compaction: byte-budgeted tool-result tail

**Evidence.** CodeWhale *compaction: token-budgeted recent tail, older-span
summary, think-tag-safe validation* (`2166fc24c`) — the same lesson Maki
documents (`MAKI-STEAL.md` #3): a *count*-based recent tail keeps three huge
results and drops thirty cheap ones.

**What Niffler has.** `compaction_propose` with a checkpoint renderer,
`strictlyReduces` validation and a permitted-cut rule that is boundary-shaped
(`permittedCuts`: balanced tool pairing + the newest user request kept
verbatim). What it does *not* have is a byte budget on the snapshot it asks
the compactor to summarize: `chunkSnapshotContent` only splits the snapshot to
fit NATS payloads. The oldest-content problem is therefore not "the retained
tail is count-based" (it is request-shaped, which is right); it is that **one
450 KB tool result inside the newest request makes the compactor's *input*
450 KB**, on the single most context-pressed request of the session, where the
Maki note recommends collapsing tool results to a byte budget first and
retrying with a smaller one if the request still overflows.

**Effort.** 1 day. **Gate.** A unit test with one giant tool result plus thirty
small ones: the compactor request stays under the byte budget and the
checkpoint still validates.

## Already covered — do not re-derive

- Subagent continuation, forks, settlement notices, team/mailbox: DSH-STEAL
  §2–§4 shipped (continuations, forks) or remain scheduled there.
- Compaction-by-summary, repair-model hook, LSP read ops, background process
  tools, quota guard: OCTOFRIEND-STEAL #1–#6, mostly shipped.
- `index`/tree-sitter skeleton tool, monty-style Python guest: MAKI-STEAL #1,
  #2 — still unshipped, still worth it, unchanged by this pull.
- Checkpoints/rewind, memory component, semantic rename: BACKLOG.md rows.
  (Droid's `droid.get_rewind_info`/`execute_rewind` RPCs and octofriend's
  ESC-rewind are *evidence* for those rows, not new rows.)

## Considered and not recommended

- **codex "Guardian review of recorded exec calls"** (`3535c22b4`) and
  Droid's `--validator-model`: a second model judging another model's exec is
  valuable at zero humans, but our approval gate already escalates to a human
  when one is reachable, and `jev`/`expert` occupy the advisory seat. Revisit
  only with evidence from unattended runs, not on the strength of the idea.
- **opencode `session_part` storage** (`c1b5f1b41`): an indexing win for a
  200k-star TS monolith, not a problem our store has.
- **Droid-style 46-tool catalog**: measured, not assumed — see the note below.

## A measurement worth carrying into the next prompt-diet

While adding the Droid bench lane (v0.251.0, Synthetic DeepSeek V4.1 Flash)
the first-prompt footprint was recorded per cell alongside Niffler's: Droid's
median first prompt is **60 396 tokens** (31 tasks, 36.5k–137k) against
Niffler's **3 048** (3 017–3 145). Its tool list is 46 entries including
`ToolSearch`, `Skill`, `Task`, `Loop`, `AskUser`, `ProposeMission`,
`CreateWorkstream`. That is the cost of a large fixed surface, and it is the
argument for keeping `discover` + `x-harness.hint` (progressive discovery)
instead of growing the direct set — not an argument for more tools, however
good each individual one is.

The same run shows what a large surface *buys*: Droid issues 4.4 tool calls
per assistant message against Niffler's 1.2, so it finishes in 1.9 LLM
messages where we take 6.5 — and per cell it ends up sending *less* uncached
input (3.4k vs 7.0k) with the same wall clock (30 s vs 29 s) at a 20% higher
cost. Batching is the lever worth copying here, not the tool count; details
in `bench/reports/full31-syn-ds41-droid-analysis.md`.

## Harness shelf: what is missing

`~/git/harnesses` covers the terminal-agent field well but misses four
categories we now cite:

| candidate | why it belongs on the shelf |
|---|---|
| `oraios/serena` (30.8k) | semantic code toolkit over MCP/LSP — the prior art for the semantic-rename row in BACKLOG |
| `charmbracelet/crush` (28.9k) | Go, single binary, LSP-first tool surface — closest architectural peer we do not read |
| `cline/cline` (71k) | now SDK + CLI + IDE; checkpoint/rewind and plan/act modes at scale |
| `aaif-goose/goose` (55.9k) | the most mature MCP extension/recipe client |
| `SWE-agent/SWE-agent` (20.7k) | the canonical ACI research harness; how tool interfaces are evaluated |
| `zed-industries/zed` (92k) | ACP's home (see #5) — read the protocol, not the editor |
| `coder/xum` (2.1k) | parallel isolated agents — fleet prior art (`claude-squad` is stale) |

Closed-source lanes belong in the *bench*, not the shelf: Claude Code
(`anthropics/claude-code` repo is issues-only), Droid (installed), Cursor,
Amp, Devin.

## Recommended next three

1. **#2 batch independent reads** — half a day, no new surface, and the first
   item on this list with a number already attached to it (1.2 → Droid's 4.4
   tool calls per message). Re-measure on the same lane.
2. **#1 fabric background/durable runs** — the one item here that changes what
   the *agent* can do, and t29/t30 are the tasks that measure it.
3. **#3 instruction budget** (one day, protects the prompt prefix we already
   fight for) together with **#11 compaction tail** (one day, same argument) —
   cheap, measurable, no new surfaces.

Then **#5 turn queue** as the first correctness fix: a real user-visible drop,
with a two-line contract test.
