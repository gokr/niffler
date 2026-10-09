# Pi Durable vs Niffler — durability frameworks, side by side

> What [Pi Durable](https://earendil.com/posts/pi-durable/) is, what Niffler
> already does, and where the two genuinely diverge.
>
> Basis: Pi Durable as announced 2026-10-01 (the RFC post shipped together
> with Pi 1.0; Pi Durable is an **experimental** package, API subject to
> change). Niffler claims are read from this repo at `main`, 2026-10-06
> (post-0.4.0), cited by path. Siblings of this document:
> [PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) is the difference map against the Pi
> *coding agent* (0.85.1, 2026-09-13), [PI_FEATURE_SCAN.md](PI_FEATURE_SCAN.md)
> the feature-level borrow list, and [FRONTIERHARNESS.md](FRONTIERHARNESS.md)
> the measured pilot (Niffler 0.4.0 vs Pi 0.99.2). This file is the third
> Pi artifact: the *framework*, not the agent.

## What Pi Durable is

Pi Durable is a TypeScript **library** for building agentic applications —
"storage plus the machinery to run conversations", importable in-process
(~15k lines without tests). The announcement's feature list:

- **Pluggable storage** behind a small interface: memory, SQLite, JSONL, plus
  a conformance suite; SQLite/JSONL use no Node APIs, so an adapter runs them
  in Bun or a Cloudflare Durable Object. One process owns a storage; other
  clients attach to that process. Only the working set (active transcripts,
  live tasks, pending submissions) is kept in memory.
- **Durability at step granularity**: every model request, tool call and
  compaction is a **task** that checkpoints before it moves on. A dead process
  is reopened over the same storage and unfinished tasks resume from their
  last checkpoint — an interrupted model request is re-sent (partial answer
  kept, marked aborted), a tool reruns only if it declared `replay: "safe"`,
  otherwise the model is told it was interrupted. `requestId` makes
  submissions exactly-once. Tasks have phases, durable timers, waiting on
  other tasks (`failFast`), and an ownership tree whose aborts propagate
  bottom-up. Foreground tasks belong to the current turn's work (Esc aborts
  them); background tasks outlive it.
- **Extensions**: named bundles of prompt sections, tools, hooks and tasks;
  conversations store names, never code. The system prompt is rebuilt from
  sections before every request (changes recorded positionally in the
  transcript). `beforeTool`/`afterTool` hook chains can rewrite, block or
  replace results, with a `memo` for crash-safe decisions. Installing under
  an existing name hot-swaps the code; the running call finishes on the old
  code.
- **Documents**: typed JSON app state (todos, plans) committed *atomically
  with the transcript*, with per-document fork policies and UI subscriptions.
- **Background compaction**: a summary is prepared before pressure and placed
  at the next turn boundary; the conversation only waits if the next request
  would not fit. `reset()` starts a new context from a handoff note;
  `search_history` reaches past it. Older messages always stay in storage.
- **Multiplayer**: any number of clients attach to a conversation, get the
  current view first and deltas after; any client can steer (`whenBusy:
  "steer"`) or queue.
- **Execution environments** are an interface too: the harness can live on
  one machine while its tools run on another, per-conversation `cwd`.
- **No built-in subagents** — the post builds one as "a few lines of code"
  (a conversation owned by the tool call that started it).

## 1. The one-line difference

**Pi Durable is a library that makes one process durable; Niffler is a system
of processes that makes the store durable.**

Pi Durable gets crash tolerance from write-ahead task checkpoints *inside*
the harness process — resume means reopening the same storage in a new
process and replaying unfinished steps. Niffler gets it from an
out-of-process store plus disposable session runners: a conversation's
in-memory context is a *projection* of `store` records, and a killed runner
loses only the in-flight turn (`AGENTS.md` § Session runners). The other
inversion: Pi Durable's extensibility is in-process TypeScript with a hot
registry; Niffler's is the bus — write source, `builder.build`,
`core.spawn`, mid-conversation, in Nim/Go/TypeScript.

Both stances are coherent. The interesting question is which Pi Durable ideas
are *load-bearing* for a system like ours, and which are already here under
different names.

## 2. Equivalence map

| Pi Durable | Niffler | Note |
|---|---|---|
| Storage interface; one owner, attachers | `store` component, single-writer (flock for sqlite; DSN + row locks for tidb), everyone else over the bus (`AGENTS.md` § store) | Same shape; our attach surface is RPC, theirs a library |
| SQLite/JSONL/memory backends + conformance suite | sqlite (default) / tidb behind one contract (`NIF_STORE_BACKEND`) | tidb gives us the networked backend theirs lacks |
| Many conversations, none blocking another | turns never nest per conversation; separate conversations concurrent; core never blocks on a runner | — |
| Fork at any transcript point, zero-copy | `agent` fork — one-time seed copy (the documented store-ownership exception), provenance in `sessionmeta.fork` | Their fork is user-facing (Slack thread); ours is subagent machinery with authorization |
| Subagents (none built-in; ~10 lines) | full machinery: `agent_run`/`agent_spawn`, push settlement with wake budget (`NIF_AGENT_WAKES`), lineage authorization, append-only continuation | Our strongest "already have it"; theirs is an application-level idiom |
| Steering (`whenBusy: "steer"`) | steer as an appended message in the running turn | — |
| Multiplayer: current view + deltas; late join | any bus client can call `session`; UIs register as clients; `ev.session.*` events; late join = resume from store | Same capability, less formalized (no view/subscribe commit-op API) |
| Malleability: `registry.install` hot-swap | write → `builder.build` → `core.kill`/`core.spawn`, mid-conversation, any language | Process granularity, cross-language; running in-flight calls may fail on `core.kill` where theirs finish on old code |
| History survives compaction | compaction/trim only change the provider projection; every message stays in the store, notices mark dropped spans (`docs/MANUAL.md` § compaction) | Identical guarantee |
| Overflow: compact and retry once | deterministic ladder — tool-result prune → replaceable compactor → oldest-turn trim → error admission, re-measured; manual `/compact` | Ours is richer and the compactor is a replaceable component contract |
| Codemode (model writes code that drives tools) | `fabric` — Nim guest program, typed tool wrappers, `batch()` fan-out, budgets; only `finish()` reaches the chat (`docs/FABRIC_GUIDE.md`, [FABRIC.md](FABRIC.md)) | See §4 — the governance posture differs, not the idea |

## 3. The philosophical split: frozen prefix vs rebuilt sections

Pi Durable rebuilds the system prompt from extension sections before every
request and leans on providers' mid-conversation prompt changes to keep the
cache warm. Niffler freezes the prefix (system prompt + direct toolset
persisted at conversation start) and requires every later contributor to be
**append-only** — steer, advice, discovered schemas, settlement notices enter
as messages; the named exceptions are `reset:prune|compact|trim|tools`
(`AGENTS.md` § Prompt-cache discipline).

Both claim cache validity. Ours is the conservative bet — the prefix is
*byte-stable by construction*, and even a skill load appends to history
rather than touching the head. Theirs buys real liveness (a changed
`AGENTS.md` section is picked up next request) at the cost of trusting every
provider's incremental-prompt support. If a Niffler feature ever seems to
need "re-render the prompt", the house answer is: append a message instead.

## 4. Genuine gaps

These are the five places Pi Durable has something Niffler does not.

1. **Step-level durability.** The big one. Their unit of resume is the step
   (one model request, one tool call) with a checkpoint before each; ours is
   the turn — "killing it loses only the in-flight turn." A crash mid-tool
   call in Niffler means redoing the turn, with no way to tell the model
   whether a tool reran. Our `contextreceipt` store kind is a request-scoped
   exactly-once guard, but only for the overflow-recovery path.
2. **Replay-safety declarations.** `replay: "safe"` on a tool is a *semantic*
   annotation about crash reruns. Our `x-harness.effect: "read"|"write"`
   looks adjacent but governs fabric batch scheduling, not crash semantics —
   it answers a different question.
3. **Intervention hooks.** Our `hooks` component is deliberately
   observe-only (shell commands on bus events, `docs/MANUAL.md` § Hooks).
   Theirs is a chained before/after seam that can rewrite arguments, block
   calls, and memoize decisions. `x-harness.approval` is one hardcoded
   instance of what they express as a hook.
4. **Durable user-defined tasks.** Phases, checkpointed state, timers that
   survive restarts, failFast waiting, ownership trees with bottom-up abort,
   foreground-vs-background semantics. Our fragments — background subagents,
   `processes` reaping, the `onIdle` seam — cover pieces, not the primitive.
   "A reminder that fires tomorrow" has no native Niffler answer.
5. **Documents + background pre-compaction.** Typed app state committed
   atomically with the transcript, fork policies, UI subscriptions — our
   store is a generic doc store (kinds include "your own durable state"), so
   this is an ergonomics/atomicity gap, not an existence gap. And their
   compaction runs in the background *before* pressure so a conversation
   never waits; our ladder runs at pressure, inside the turn.

## 5. Where Niffler goes further

- **Language freedom as architecture.** Pi Durable answers "why TypeScript
  again?" with bootstrap pragmatics; we never had to answer — the envelope
  codec is 77 lines of `std/json` (`sdk/envelope.nim`) mirrored 1:1 by three
  SDKs, and components are processes, so any language with a NATS client can
  join.
- **The self-extension loop.** Write → build → spawn → discover → invoke,
  with `x-harness.*` contract extensions (approval, onDemand, effect,
  noSpawn, workspace, …) enforced at dispatch. Their registry is in-process
  TS only.
- **Progressive tool discovery** (`discover` / sticky `invoke`) — a frozen
  direct set plus on-demand reachability, which their model doesn't need
  because all extensions live in one catalog with per-conversation selection.
- **Subagent governance.** Settlement push (not poll), bounded wake turns,
  lineage authorization with explicit refusal codes, fork provenance — the
  parts the Pi post leaves to the application author.
- **Replaceable compaction** as a component contract with its own test lane
  (`make test-compaction`), and the networked store backend.

## 6. Codemode, concretely

The Pi Durable ecosystem's codemode and our `fabric` are the same idea: the
model writes a program that drives tools, aggregation happens in the
program's memory, and only the distilled result enters the conversation. The
difference is posture. Fabric is **governance, not sandbox** (`FABRIC.md`):
the program is human-approved as a whole (per-digest, bash-class trust), and
every nested call re-enters the session's approval/audit/deadline gate —
which is why `fabric` refuses to run without a live session context (the
runner injects `__session`: turn deadline, nested-call lease, cancel
matching). Fixed-verb tools like `plugin_update` have no such requirement;
their governance attaches to the verb, so anything on the bus — the harness,
`cli`, a cron — can call them. Slash-command aliases make this visible:
they are declarative data (`docs/WIRE.md` § Slash commands) that UIs expand
into a plain `svc.<component>.call`.

That asymmetry is also the answer to "should the harness run fabric
itself?": core could synthesize a session, but then core — the thin control
plane — would own approval and budgets for arbitrary code runs. The designed
path is graduation: a stabilized fabric program (`fabricprog`, the
model-curated sketchbook) becomes a real component via `builder.build` +
`core.spawn`, at which point it is an ordinary fixed-verb tool every caller
can reach.

## 7. If it lands here

Borrow list, in the shape our architecture requires — each as a bus
contract, never a core edit:

- **Step-level replay** — a `replay` field beside `x-harness.effect`
  (`"safe"` | `"never"`), plus runner-side tool-intent records so a resumed
  turn can tell the model what reran. Biggest delta, biggest design lift.
- **Intervention hooks** — generalize `hooks` from observe-only to a
  before/after chain component that answers a normalized contract (block /
  rewrite / pass) over the bus.
- **Durable tasks** — a `tasks` component (phases, timers via `onIdle`,
  waiting, ownership) whose records live in the store next to conversations.
- **Documents** — a fork policy + transactional tie on store `put`s made by
  a conversation's turn; subscription is already `ev.*` + store reads.
- **Pre-compaction** — a background rung offered by the compaction seam
  before pressure, placed at the next turn boundary.

All of it must preserve the frozen-prefix invariant (§3) — the Pi Durable
prompt-section model is the one idea we should *not* borrow; it resolves the
same cache problem in the opposite direction from our documented bet.

## Sources

- Pi Durable announcement: <https://earendil.com/posts/pi-durable/> (RFC,
  2026-10-01; Pi 1.0 shipped the same day)
- [PI-VS-NIFFLER.md](PI-VS-NIFFLER.md) — the coding-agent comparison this
  document extends to the framework
- [FABRIC.md](FABRIC.md) / [docs/FABRIC_GUIDE.md](../FABRIC_GUIDE.md) — the
  codemode counterpart
- `AGENTS.md`, `docs/WIRE.md`, `docs/MANUAL.md` — the Niffler side, quoted
  by invariant
