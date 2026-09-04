# Plan — open work

The general todo list: everything explicitly deferred or still open, in one
place. Completed capabilities are tracked as checked milestones in the
[README](../README.md) (update that when you finish something here); design
history lives in [research/](research/README.md).

## In progress

- **Code hygiene + store v2** (`feat/code-hygiene`) —
  [research/STORE_V2.md](research/STORE_V2.md): SDK storeclient/config/http
  helpers + duplication cleanup; three interchangeable store engines behind
  one contract (barrel stays default; Go SQLite + TiDB engines with goose
  migrations, picked via `NIF_STORE_BACKEND`); DuckDB as a bus observer.
- **Level 1 UI dynamism** — `x-ui` schema hints + a generic renderer
  registry, so a component can shape how its tools render in the web UI.

## Fabric — explicitly deferred follow-ups

The fabric/agent architecture is complete and tested
([research/FABRIC.md](research/FABRIC.md), [FABRIC_GUIDE.md](FABRIC_GUIDE.md)).
These are the consciously deferred deltas, none of which block the shipped
mechanism:

1. **Fabric mid-run cancellation.** `agent_stop` already cancels child turns
   for real (llm.cancel + a `__cancel` steer; bash kills its whole process
   group). A *fabric program* itself still cannot be cancelled mid-run:
   NATS request/reply has no cancel semantics, so kill-on-timeout remains
   the only stop — a stopped turn abandons the result but the guest runs out
   its deadline. Revisit with durable workers.
2. **Durable-agent hardening.** Per-job time budgets, lazy restart recovery,
   reasoning-effort selection, per-session tool allowlists, and per-turn
   round/call/token budgets have shipped. Still open: structured-output
   schemas, canonical working directories, and optional isolated git
   worktrees for subagents — all need deeper core session-surface design.
3. **Resource-scoped batch effects.** `x-harness.effect: "read"` tools run
   concurrently in `batch(...)` (and may overlap one write); writes are
   mutually exclusive **globally**. Relaxing global write exclusion needs
   resource-scoped effect declarations — bash is a universal writer, so
   component identity does not imply resource disjointness.
4. **Durable trace retention.** `ev.fabric.*`/`ev.agent.*` lifecycle events
   and child logs are diagnostic only (age/size-capped, swept at boot and per
   run). Durable retention/cleanup for traces and events would need
   store-backed records — today's logs are not an audit trail.
5. **Sandboxing.** A separate milestone if and when *untrusted* guests are
   required (restricted VM, WASM, or OS isolation). Today the guest is
   trusted code in `bash`'s trust class; approval plus source lint is the
   boundary, not a technical impossibility of reaching past the bridge.

## Quests — things Niffler should do itself (or that we do on a slow day)

1. **store-sqlite comparison** — port `components/store/main.nim` to SQLite
   (e.g. nim-community/libsql), same tools, run both, compare. The contract
   is the artifact; Niffler can read its own sources, build, spawn and
   benchmark the variant — a true dogfooding quest.
2. **pipewrap** — stdio/NDJSON bridge so plain scripts become components
   (no SDK port needed). The wire spec already describes the transport
   ([WIRE.md](WIRE.md)).
3. **Level 2 UI dynamism** — builder compiles Svelte components to JS
   modules, the catalog registers ui-modules, the bridge serves `var/ui/`,
   the SPA blob-imports (see `ui/README.md`).
4. **store-tidb** — same tools, SQL tables, FTS + vector search for
   conversation memory; sharing across harnesses/hosts.
5. **Component package template repo** — the niffler-weather repo layout +
   release CI as a `gh repo create`-able template; optionally a curated
   index repo for `plugin_search` ranking.
6. **JS components without a compile step** — sdk/ts + builder `lang: "ts"`
   have shipped; running TS directly via tsx remains a possible follow-up.
