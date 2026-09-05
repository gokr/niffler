# Store v2 — three stores, one contract, SDK tightening, DuckDB as observer

> Plan for the `feat/code-hygiene` branch. Status: design; SDK additions in
> progress. Revision 2: SQLite and TiDB stores are **additional** engines —
> the barrel store stays and remains the default until comparison data says
> otherwise.
>
> Progress: **M3 and M4 landed on `main`** — `components/store-sqlite` and
> `components/store-tidb` (both Go, goose migrations, `NIF_STORE_BACKEND`
> boot switch in core, `make test-store-sqlite` / `test-store-tidb` running
> the same contract; TiDB verified live against v8.5.0). The SDK refactor
> pass (M2) and the default-flip decision (M7) remain open.

Two entangled goals, one branch:

1. **Code hygiene**: pay down the duplication that has accumulated in
   components and SDKs (the ledger below), and expand both SDKs so
   components shrink.
2. **Store v2**: three interchangeable store engines behind one bus
   contract — the current barrel store (Nim/Bitcask), a new SQLite store
   (Go, goose migrations), a new TiDB store (Go, same schema, MySQL
   protocol) — plus DuckDB where it actually belongs: observing the bus,
   not serving it.

## What does not change

The store's **bus contract is the artifact** (docs/WIRE.md; the current
`components/store/main.nim` header says so itself). `put/get/list/del`,
`expectRev` optimistic concurrency, `rev` per (kind, id), list ordered by
id, the kinds core depends on (`component`, `conversation`, `message`,
`approval`, `agentjob`, `slash`, plus `sessionmeta`, `fabricprog`,
`plugin`) — all unchanged. Consumers (core/conversation.nim,
core/dispatch.nim:715, agent, fabric, plugins, cli, UIs) keep speaking
`svc.store.call`. Storage engine and implementation language are private
to the component; only the wire answers matter.

Single-writer enforcement stays **at the bus level**: each local engine
flocks its own file (barrel: `var/barrel-db.lock`; sqlite:
`var/store.db.lock`) for the same reason as today's comment — two stores
in the `store` queue group would alternate inconsistent views. The
selection mechanism below guarantees only one store boots per harness, so
the flock remains a last line of defense, not a policy. TiDB needs no
flock: the DSN is shared network state, and rev-based optimistic
concurrency (`SELECT … FOR UPDATE` + `expectRev`) is the arbiter — two
harnesses sharing one TiDB is a *feature*, not a bug.

## Three stores, one name

All three register as component **`store`** with the same hidden tools —
core, dispatch, agents and UIs never learn which engine is live. Selection
is a boot-time choice:

- `make build` produces all three binaries: `var/bin/store` (barrel, as
  today), `var/bin/store-sqlite`, `var/bin/store-tidb`.
- The manifest keeps its single `store` entry. Core resolves that entry's
  binary through `NIF_STORE_BACKEND` (unset/`barrel` → `var/bin/store`;
  `sqlite` → `var/bin/store-sqlite`; `tidb` → `var/bin/store-tidb`;
  anything else → refuse to boot with a clear error). One small core
  change at manifest resolution; the llm-openai comment-out dance stays
  available as a manual fallback.
- Trying a store = `NIF_STORE_BACKEND=sqlite make run`. Comparing two
  stores = boot twice against the same dataset. Nothing else moves.

Default remains barrel — the working shape must never change under a
hygiene branch until the alternatives prove themselves on the same tests
and the same data.

## Document store vs SQL store — the tradeoffs

The user-facing question, answered honestly. The contract is documents
either way; the difference is what the bytes sit on.

**Barrel (Bitcask KV + JSON docs) — doc-oriented:**

- schema-free: a new kind or a new field is just a write; no migrations
  exist, none can break
- key-ordered prefix scans are the *only* query surface — anything
  cross-document (how many tool calls yesterday? messages of one role?)
  is a client-side scan over the bus
- no multi-key transactions: `put` writes doc + rev counter in two steps
  today — a crash between them leaves a dangling doc (or a lost rev)
- introspection = `strings` carving on the file
- dead simple, zero deps beyond the already-present bitbarrel, fast
  point reads, append-only writes

**SQLite/TiDB with a JSON column — "document-in-relational":**

- same document flexibility (the `value` column is JSON text), *plus*
  SQL around it: count/filter/join/aggregate over kinds without moving
  data over the bus
- real transactions: `put` becomes one atomic statement, closing the
  two-step crash window
- introspection: `sqlite3 var/store.db '…'`; TiDB plugs straight into the
  chetter ops stack (same driver, same SQL tools)
- migrations discipline via goose — a new process in the repo, and a
  schema is a convention people must not quietly break
- the cost of JSON-in-TEXT: the DB cannot index *inside* documents
  natively. Mitigations: SQLite JSON1 (extract + expression indexes),
  TiDB's JSON type + generated columns — and when a field earns an index,
  promoting it to a real column is a goose migration, not a rewrite
- TiDB-only extras: network-shared persistence (many harnesses, one
  store), scale-out, and FTS/vector columns later for retrieval work

Net: for Niffler's current workload the doc store genuinely suffices —
which is exactly why barrel stays default and SQL is an *additional*
option. SQL starts paying when we want cross-document questions, real
transactions, operational visibility, or a shared store. The three-store
setup is what lets us measure that instead of argue about it.

## Store 2: SQLite — Go

- **Language: Go, one binary.** `llm`, `models`, `provider` are already Go;
  the Go SDK has `Component`, `Tool`, `RequestOK`; the builder has
  first-class Go support (auto `replace niffler.dev/sdk => ../../sdk/go`).
  `database/sql` + two drivers = one codebase, two SQL engines. Matches
  the chetter stack (`../chetter`: Go + goose + go-sql-driver/mysql on
  TiDB).
- **Driver: `modernc.org/sqlite`** — pure Go, no cgo. Existing Go
  components carry no cgo deps; keep the zero-prereq build story intact.
  (`mattn/go-sqlite3` is faster but cgo — rejected for the builder path.)
- **Migrations: goose as a library**, embedded via `embed.FS`, applied at
  startup. Niffler components must be zero-manual-steps; chetter runs
  goose as a CLI, here the component owns its schema.

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
  (ids are ours — alphanumeric + `:` + `-`; escape LIKE metachars anyway
  for defense).
- `del`: `DELETE`; idempotent, as today.
- Envelope shapes byte-identical to today's tool results — `t_store`
  asserts the contract, run against all three engines.

### File + env

`var/store.db` (sqlite) / `NIF_STORE_TIDB_DSN` (tidb). Backend selection
is the `NIF_STORE_BACKEND` boot switch above, not a runtime flag.

## Store 3: TiDB — same binary, same schema

MySQL protocol via `go-sql-driver/mysql` (the chetter pair). Same goose
migrations (TiDB is MySQL-compatible; the flatout-backend skill's
TiDB-vs-MySQL notes apply: tables/indexes only, no procedures/triggers).
`put` uses `SELECT … FOR UPDATE` inside the transaction.

What TiDB buys: a shared network store across harnesses (dev + CI +
remote), the user's existing TiDB ops stack, and a path to FTS/vector
columns. Overkill for one harness — fine, that's the point of an
*additional* engine: it costs one driver + a DSN because the schema and
the wire answers are shared.

## DuckDB — the observer, not the store

Short answer: **DuckDB is the analytics sink, not the document store.**
The intuition to use it as an observer is the right one.

- DuckDB is columnar/OLAP: its design center is batch analytical scans
  over accumulated data, not the store's workload (small row-at-a-time
  writes, hot point reads, key-ordered prefix scans, optimistic-concurrency
  upserts). Its multi-process write story is explicitly single-writer; the
  strong suit is queries, not serving OLTP-ish callers.
- As a store it would be strictly worse than SQLite on our workload and
  give up every SQLite advantage (WAL concurrency, tiny footprint,
  ubiquitous tooling) for nothing we use.
- As an **observer** it's genuinely interesting: a component (mode of
  `observe`, or a sibling `observe-duckdb` sink) that tails `ev.*` —
  turns, tool calls, token deltas, approvals, logs — and materializes them
  into `var/observe.db` (or parquet), never answering `svc.store.call`.
  Then: session latency percentiles, tool-usage distributions, token-cost
  rollups, approval-denial rates, catalog churn. `observe` stays the live
  inspection tool; DuckDB is the offline lab. A read-only bus consumer is
  the cheapest possible component shape.

If a read-only DuckDB *view* of a store is ever wanted, it attaches to
the sqlite file as a second reader — still not a writer.

## Moving data between engines

No migration lock-in: every engine speaks the same wire contract, so the
copy tool is bus replay. `tools/store-copy.nim` (a plain SDK client, not
a core change): `list` every kind from the running store, `put` each doc
into the target — wait, the target *is* the running store; so the tool
instead: **export** (`list` all kinds → JSONL file, keyed by kind) and
**import** (JSONL → `put`). Copy = export from engine A, boot with engine
B, import. Revs are preserved by carrying them via `expectRev`-less put
only when the target is empty; the tool refuses to import into a
non-empty store by default (`--force` to overlay). Reads are direct bus
calls — no barrel code in Go, no driver code in Nim, nothing engine
specific anywhere but the engines themselves.

## SDK expansion (the simplification half)

Ledger of what actually exists today (surveyed, not guessed):

| Duplication | Where |
|---|---|
| `configInt` (env parse + clamp) | `components/logfile/main.nim:31`, `components/observe/main.nim:70`; ad-hoc `getEnv` parsing at 16 more call sites across components |
| store call boilerplate: `comp.request("store", "get", …)` + error text + JSON field poking | 19 call sites: agent (≈11), `components/fabric/fabric.nim`, `components/plugins/main.nim`, `core/dispatch.nim:715`, plus conversation.nim's `dispatchToolCall("get", …)` store ops — each with its own "store unreachable" wording |
| fresh-`HttpClient`-per-call pattern (the AGENTS.md invariant against stale pooled connections) | fetch, observe, plugins, skills — each hand-rolls user-agent + timeout |
| `"svc." & name & ".call"` subject building | 6 sites across components and core |
| repeated error-code strings | e.g. `"cannot read job (store unreachable): "` ×3 in agent alone; `"no such probe"` ×4 in observe |
| JSON defensive-poking chains (`.getStr("").len > 0`, `.getBool(false)`) | 21 sites in core/*.nim alone — typed helpers would read better |
| Go component boilerplate | llm/main.go (832), provider/main.go (964), models/main.go (285), llm-openai (216) each hand-roll tool schemas + `x-harness` maps + result shaping over the same SDK surface |

SDK additions, both SDKs (Nim and Go, mirrored 1:1 per the wire-spec
culture):

1. **`storeclient`** (both SDKs): typed `storePut/storeGet/storeList/
   storeDel` on `Component`, mapping `rev-conflict`/`not-found` to
   first-class error types (Nim: distinct exceptions; Go: sentinel
   errors), with "store unreachable" defined once. The biggest single
   simplification — most core/agent/fabric/plugins store code collapses
   to one-liners, and the "fail closed" sites (agent lineage, dispatch
   depth guard) read clearly.
2. **`config` helpers** (both SDKs): `configInt/configStr/configBool`
   with default + clamp, reading process env — kills the duplicated
   helpers and makes component config uniform.
3. **`http` helper** (Nim SDK): `fetchText(url, timeout, userAgent)` that
   creates a client per call, encoding the stale-pool invariant once
   instead of four times.
4. (Candidate) `serviceSubject(name)` subject helpers so components and
   core stop concatenating wire addresses inline.

Then the refactor pass: logfile + observe onto `configInt`; agent, fabric,
plugins, conversation, dispatch onto `storeclient`; fetch/observe/plugins/
skills onto the http helper. Behavior-neutral — `make test` must stay
green at every commit, and `t_store` runs against all three engines.

## Milestones

- [x] **M1** — plan on `feat/code-hygiene` (worktree
  `../niffler-code-hygiene`).
- [ ] **M2** — SDK additions (Nim + Go `storeclient`, config helpers, http
  helper) with unit tests; refactor the duplication ledger onto them;
  `make test` green.
- [x] **M3** — `store-sqlite` (Go, goose embedded, flock, byte-identical
  results) as an *additional* engine; `NIF_STORE_BACKEND` boot switch in
  core; `t_store` green against barrel and sqlite; barrel stays default.
  Shipped: JSON-in-TEXT stored verbatim, single atomic put (BEGIN
  IMMEDIATE upsert/compare-and-set), flock on `var/store.db.lock`,
  schema mirrored from the barrel engine's tool schemas. Deviations,
  both accidental barrel behaviors (documented in the component header):
  no tombstone ghosts, list limit < 1 clamps to one item instead of
  barrel's critbit post-increment quirk.
- [x] **M4** — `store-tidb` engine; `t_store` green against a TiDB DSN
  (docker in CI, user's cluster manually). Shipped: MySQL protocol via
  go-sql-driver, same docs schema (MEDIUMTEXT, utf8mb4_bin — binary
  collation is required for byte-exact ids/ordering), `SELECT … FOR
  UPDATE` upsert under pessimistic transactions, `ClientFoundRows` for
  correct CAS, no flock (network state; row locks arbitrate), DSN from
  `NIF_STORE_TIDB_DSN` (session forced to UTC unless the DSN picks a
  zone). Verified live: TiDB v8.5.0 in docker (single-node), full
  contract + unit tests + core boot probe.
- [ ] **M5** — `tools/store-copy.nim` (JSONL export/import) so datasets
  move between engines; a small comparison script (same synthetic load,
  wall-clock + file size per engine). *Partial: comparison shipped as
  `tools/bench_stores.nim` (bus-contract bench, both engines). Measured on
  the dev box, end-to-end over NATS — sqlite leads every phase ~2-6x, but
  the gap is dominated by per-request overhead of the component stacks
  (barrel's floor is ~2 ms/request even for no-op reads; list amortizes to
  ~27 µs/item vs sqlite's similar batch cost), not document I/O. Disk:
  barrel 0.4-0.5 MB, sqlite 1.4 MB (+WAL high-water during writes,
  checkpointed away on clean close). Boot to registered: 22 ms vs 7 ms.
  Both are far beyond the harness's needs; the copy tool itself remains
  open.*
- [ ] **M6** — DuckDB observer: `observe` sink mode (or sibling component)
  materializing `ev.*` into `var/observe.db`; stock queries shipped as
  examples.
- [ ] **M7** — README milestone table + docs/MANUAL.md persistence
  section rewritten for the three engines; decide (with data) whether the
  default flips.
