# Store v2 — SQL backends, SDK tightening, DuckDB as observer

> Plan for the `feat/code-hygiene` branch. Status: design; nothing shipped yet.

Two entangled goals, one branch:

1. **Code hygiene**: pay down the duplication that has accumulated in
   components and SDKs (the ledger below), and expand both SDKs so
   components shrink.
2. **Store v2**: reimplement the `store` component in Go on SQL — SQLite by
   default, TiDB as a network alternative — with goose migrations, and put
   DuckDB where it actually belongs: observing the bus, not serving it.

## What does not change

The store's **bus contract is the artifact** (docs/WIRE.md; the current
`components/store/main.nim` header says so itself). `put/get/list/del`,
`expectRev` optimistic concurrency, `rev` per (kind, id), list ordered by
id, the kinds core depends on (`component`, `conversation`, `message`,
`approval`, `agentjob`, `slash`, plus the newer `sessionmeta`,
`fabricprog`, `plugin`) — all unchanged. Consumers (core/conversation.nim,
core/dispatch.nim:715, agent, fabric, plugins, cli, UIs) keep speaking
`svc.store.call`. Storage engine and implementation language are private
to the component.

Single-writer enforcement stays **at the bus level** (flock on the store
file, same rationale as the comment in today's main.nim: two stores in the
`store` queue group would alternate inconsistent views). SQLite's own
locking is belt-and-suspenders; the flock is the invariant.

## Why SQL

Barrel (Bitcask KV) has served fine, but it buys nothing that SQL doesn't
and costs real things:

- every consumer must do prefix scans client-side through one fixed index;
- no transactions across documents (put writes doc + rev counter in two
  steps today — a crash between them leaves a dangling doc);
- no introspection (`sqlite3 var/store.db 'select …'` beats `strings`
  carving on the barrel file, the current offline-recovery story);
- the TiDB variant (below) wants a real schema anyway, and one schema
  serves both drivers.

## Backend 1: SQLite (default) — `store` in Go

- **Language: Go, one binary.** `llm`, `models`, `provider` are already Go;
  the Go SDK has `Component`, `Tool`, `RequestOK`; the builder has
  first-class Go support (auto `replace niffler.dev/sdk => ../../sdk/go`).
  Go's `database/sql` + two drivers gives us one binary, two backends,
  zero Nim SQL-driver friction. This also matches the chetter stack
  (`../chetter` uses Go + goose + go-sql-driver/mysql against TiDB).
- **Driver: `modernc.org/sqlite`** — pure Go, no cgo. Existing Go
  components carry no cgo deps; keep the zero-prereq build story intact.
  (`mattn/go-sqlite3` is faster but cgo — rejected for the builder path.)
- **Migrations: goose as a library**, embedded via `embed.FS`, applied at
  startup. Niffler components must be zero-manual-steps (no ops CLI);
  chetter runs goose as a CLI, but here the component owns its schema.
  Same migration style, different runner.

### Schema (migration 0001)

```sql
CREATE TABLE docs (
  kind       TEXT        NOT NULL,
  id         TEXT        NOT NULL,
  rev        INTEGER     NOT NULL DEFAULT 0,
  value      TEXT        NOT NULL,  -- JSON document
  updated_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, id)
);
CREATE INDEX idx_docs_kind_id ON docs (kind, id);
```

- `put`: one transaction — sqlite `BEGIN IMMEDIATE`, `SELECT rev` then
  `UPDATE docs SET rev = rev + 1, value = ? WHERE kind = ? AND id = ?
  AND rev = ?`; rows-affected = 0 → rev-conflict (or not-found when the
  row is absent). Kills today's two-step doc+rev-counter write.
- `get`: row → `{ok, rev, value}`; missing → `not-found`.
- `list`: `WHERE kind = ? AND id LIKE prefix||'%' ORDER BY id LIMIT ?`
  (LIKE prefix with `%` is safe here — ids are ours, alphanumeric + `:` +
  `-`; no `_` wildcards in generated ids, but escape anyway for defense).
- `del`: `DELETE`; returns ok regardless (idempotent, as today).
- Envelope shapes identical to today's tool results (tests assert byte-level).

### File + env

`var/store.db` (new; barrel file stays `var/barrel-db` until migration).
`NIF_STORE_BACKEND=sqlite|tidb` (default sqlite). Flock moves to
`var/store.db.lock`. The component still registers as **`store`** — core,
dispatch, agents, and UIs never learn the backend exists.

## Backend 2: TiDB — same binary, same schema

`NIF_STORE_BACKEND=tidb` + `NIF_STORE_TIDB_DSN` (MySQL protocol,
`go-sql-driver/mysql` — the exact chetter driver pair). Same goose
migrations (TiDB is MySQL-compatible; the flatout-backend skill's
TiDB-vs-MySQL notes apply: keep it to tables, indexes, no procedures).
`put` uses `SELECT … FOR UPDATE` inside the transaction.

What TiDB buys us here: a **shared, network store** — several harnesses
(dev machine + CI runner + a remote core) can attach to one DSN instead of
each owning a private barrel file, and later migrations can add FTS/vector
columns for retrieval work. It is admittedly overkill for one harness —
that's fine; it's the fan option, and it costs one driver + a DSN because
the schema is shared. Component behavior must stay byte-identical
(existing `t_store` runs against both backends via env swap).

## DuckDB — the observer, not the store

Short answer: **DuckDB is the analytics sink, not the document store.**
The intuition to use it as an observer is the right one.

- DuckDB is columnar/OLAP: its design center is batch analytical scans
  over accumulated data, not the store's workload (small row-at-a-time
  writes, hot point reads, key-ordered prefix scans, optimistic-concurrency
  upserts). Its multi-process write story is explicitly single-writer; the
  strong suit is queries, not serving concurrent OLTP-ish callers.
- As the store it would be strictly worse than SQLite on our workload and
  would give up every SQLite advantage (WAL concurrency, tiny footprint,
  ubiquitous tooling) for nothing we use.
- As an **observer** it's genuinely interesting: a component (mode of
  `observe`, or a sibling `observe-duckdb` sink) that tails `ev.*` —
  `ev.session.turn/toolcall/token`, `ev.approval.*`, `ev.log.*`,
  `ev.catalog.updated` — and materializes them into a local DuckDB file
  (`var/observe.db` or parquet), never answering `svc.store.call`.
  Then: session latency percentiles, tool-usage distributions, token-cost
  rollups, approval-denial rates, catalog churn — real analytics the
  current in-memory `observe` ring buffer cannot do. `observe` stays the
  live inspection tool; DuckDB is the offline lab. This also fits the
  architecture: it's a read-only bus consumer, which is the cheapest
  possible component shape.

If a read-only DuckDB *store* is ever wanted (e.g. clone the store for
analysis), it attaches to the store's file as a second reader — still not
a writer.

## Migration: barrel → SQLite

The old store retires (history keeps it). Data to preserve: `component`
records (spawned plugins!), `plugin`, `conversation`/`message` transcripts,
`slash` checkpoint, `approval` memories, `fabricprog` library.

Tool: `tools/store-migrate.nim` — a Nim script that links bitbarrel (the
dep already lives in the old component), reads `var/barrel-db` directly
(no lock needed: read-only, and the new store has not started), and
replays every `d:<kind>:<id>` doc as `store put` over the bus to the new
store. Revs re-derive from the `r:` counter. Then rename
`var/barrel-db` → `var/barrel-db.migrated` and boot normally.
No bus-replay tricks, no dual-writer windows, no barrel code in Go.

## SDK expansion (the simplification half)

Ledger of what actually exists today, so the work is concrete:

| Duplication | Where |
|---|---|
| `configInt` (env parse + clamp) | `components/logfile/main.nim:31`, `components/observe/main.nim:70` — and ad-hoc env parsing in most others |
| store call boilerplate: `comp.request("store", "get", …)` + error text + JSON field poking | agent (≈11 call sites), `components/fabric/fabric.nim`, `components/plugins/main.nim`, `core/conversation.nim`, `core/dispatch.nim:715` — each with its own "store unreachable" wording |
| fresh-`HttpClient`-per-call pattern (the AGENTS.md invariant against stale pooled connections) | fetch, observe, plugins, skills — each hand-rolls user-agent + timeout |
| subject-string building (`"svc." & name & ".call"`) | scattered across components and core |

SDK additions, both SDKs (Nim and Go, mirrored 1:1 per the wire-spec
culture):

1. **`storeclient`** (both SDKs): typed `storeGet/storePut/storeList/storeDel`
   on `Component`, mapping `rev-conflict`/`not-found` to first-class
   results, with a `storeUnreachable` message defined once. This is the
   biggest single simplification — most core and agent code that touches
   the store collapses to one-liners, and the "fail closed" sites
   (agent lineage, dispatch depth guard) read clearly.
2. **`config` helpers** (both SDKs): `configInt/configStr/configBool`
   with default + clamp, reading process env — kills the duplicated
   helpers and makes component config uniform.
3. **`http` helper** (Nim SDK): `fetchText(url, timeout, userAgent)` that
   creates a client per call, encoding the stale-pool invariant once
   instead of four times.
4. (Candidate, not committed) `serviceSubject(name)` / `toolCall(name)`
   subject helpers so core and components stop concatenating wire
   addresses inline.

Then the refactor pass: logfile + observe onto `configInt`; agent, fabric,
plugins, conversation, dispatch onto `storeclient`; fetch/observe/plugins/
skills onto the http helper. Behavior-neutral — `make test` must stay
green at every commit, and t_store asserts the store contract is
untouched.

## Milestones

- [ ] **M1** — this doc lands on `feat/code-hygiene` (worktree
  `../niffler-code-hygiene`).
- [ ] **M2** — SDK additions (Nim + Go `storeclient`, config helpers, http
  helper) with unit tests; refactor the duplication ledger; `make test`
  green.
- [ ] **M3** — Go `store` (SQLite, goose embedded, flock, byte-identical
  results); `t_store` green against it; barrel store removed; migration
  tool `tools/store-migrate.nim`; run it on a live harness once.
- [ ] **M4** — `NIF_STORE_BACKEND=tidb` variant; `t_store` green against a
  TiDB DSN (docker in CI, user's cluster manually).
- [ ] **M5** — DuckDB observer: `observe` sink mode (or sibling component)
  materializing `ev.*` into `var/observe.db`; a few stock queries shipped
  as examples.
- [ ] **M6** — README milestone table updated; docs/MANUAL.md persistence
  section rewritten for SQLite/TiDB.
