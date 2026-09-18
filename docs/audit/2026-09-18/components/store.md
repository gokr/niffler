# Audit — the store: `components/store` (Nim front door) + `components/store-sqlite` + `components/store-tidb`

Audited against the tree at commit `808308ca89c3bbfcb8d10ddcd7a789f6fe00f8e8`
(2026-09-19 00:06), whose `docs/MANUAL.md` was **2850 lines**.

**Revision note — the MANUAL moved while this audit ran.** The consolidation
fleet committed twice during the audit (HEAD now `a66dbfa`, MANUAL = **3072
lines**), and its store-related edits landed in two places: the shipped row
(:59) and the migrating section (:319-348). Every line number in this report
was re-anchored to that 3072-line revision at the end of the audit, and quotes
are still the durable anchor (the docs-audit convention). Two of this report's
draft findings are **already fixed** by that consolidation and are marked so in
§4.3 and §5:

- the shipped-components row now states that all four store tools are on-demand
  and `del` additionally hidden (the §The store sentence at :2869 still says
  only "`get` and `list` are on-demand");
- the migrating section's four example commands were replaced by a flags list
  that does name `--to <engine>` (it still omits `--quiet`/`--version`, and it
  still does not mention `--force` — correctly, since that flag is dead).

**Three directories, one bus component.** They are three engines behind one
contract, and this report names the owning directory for every tool, knob and
behaviour:

| Directory | Language | Binary | Engine | Data | Lock |
|---|---|---|---|---|---|
| `components/store/` | Nim (234 lines) | `var/bin/store` | **barrel** (embedded BitBarrel, Bitcask KV + critbit index) | `var/barrel-db` | flock on `var/barrel-db.lock` |
| `components/store-sqlite/` | Go (517 lines + `migrations/00001_init.sql`) | `var/bin/store-sqlite` | **sqlite** — **the default** | `var/store.db` (WAL) | flock on `var/store.db.lock` |
| `components/store-tidb/` | Go (505 lines + `migrations/00001_init.sql`) | `var/bin/store-tidb` | **tidb** (MySQL protocol; live-verified against TiDB v8.5.0 by the `STORE_V2.md` author — **not** by this audit, see §7) | network DSN | **no flock** — row locks |

Adjacent code that is not itself a store directory but is load-bearing for this
audit, and is therefore cited where a MANUAL claim depends on it: the boot-time
engine selection and the un-migrated-barrel guard in `core/niffler.nim:444-502`,
the paging helper `storeListAll` in `core/dispatch.nim:224-266`, and the offline
mover `tools/store_migrate.nim` (503 lines).

Evidence base: the three component sources, both `migrations/*.sql`,
`tools/store_migrate.nim`, `core/niffler.nim`, `core/dispatch.nim`,
`sdk/niffler/sdk.nim` (+ `jsonx.nim`, `subjects.nim`), `sdk/go/{wire,storeclient}.go`,
`manifest.yaml:8-18`, `Makefile:127-152`, `tests/t_store.nim`,
`tests/t_store_paging.nim`, `tests/helpers.nim:291-330`, `.env.example:58-70`.
`docs/research/STORE_V2.md` was used for intent only (it is explicitly *not*
audited here); every claim below was re-checked against code.

## 1. What the store offers

### 1.1 The document model — kind / id / value / rev

One flat namespace over two keys per document; the engine is invisible to the
bus. Barrel spells the keys out (`components/store/main.nim:66-67`):

```
d:<kind>:<id>   → the JSON document, stored verbatim
r:<kind>:<id>   → the revision counter, a decimal integer
```

`rev` starts at **1** on the first `put` and increments on every update
(`main.nim:107-112`; sqlite `main.go:329-338` `INSERT … ON CONFLICT … rev = docs.rev + 1 …
RETURNING rev`; tidb `main.go:296-327` `SELECT rev … FOR UPDATE` then insert-at-1 or bump).
`kind` and `id` are uninterpreted strings (ids sort lexicographically — ASCII
byte order in barrel/sqlite, `utf8mb4_bin` collation in tidb,
`components/store-tidb/migrations/00001_init.sql:14`), and `value` is opaque
JSON. The bus contract — not a schema — is the artifact
(`components/store-sqlite/main.go:10-17`); the two SQL engines store the
document as verbatim TEXT (`MEDIUMTEXT` in tidb), never as a native JSON column,
so key order and number formatting survive
(`store-sqlite/migrations/00001_init.sql:12`, `store-tidb/main.go:20-46`).

`expectRev` is optimistic concurrency: `expectRev` > 0 requires the current rev
to match, else the call fails with code **`rev-conflict`** — with `currentRev`
in the result when the document exists (`main.nim:102-106` + `getRev`; sqlite
`main.go:302-323`; tidb `main.go:258-288`). All three engines answer a
mismatch-on-missing-document with `error: "not found"`, `code: "rev-conflict"`
(barrel `main.nim:103-105`, sqlite `main.go:313-316`, tidb `main.go:278-281`) —
same code, same message, contract-identical. `expectRev: 0`/absent is an upsert.

### 1.2 The single-writer rule and the flock

Exactly one process owns a file-backed store; everyone else speaks envelopes
(`components/store/main.nim:39-51`, `components/store-sqlite/main.go:162-176`).
Both take an **exclusive non-blocking `flock` (LOCK_EX|LOCK_NB)** on
`<datafile>.lock` — `var/barrel-db.lock` for barrel, `var/store.db.lock` for
sqlite — and `exit(1)` with a "stop the other harness (`make down`) or kill the
stale store process" message when it is already held. The fd is kept open for
the process lifetime (closing releases the lock), so the kernel drops the lock
on crash and a stale lock file never wedges a boot.

The reason is stated in both headers and is a bus-level one, not a data-level
one: two stores would join the same NATS queue group and alternate two
inconsistent in-memory/on-disk views (the classic flapping session sidebar,
`main.nim:44-49`). SQLite additionally has WAL + `BEGIN IMMEDIATE` +
`busy_timeout`, so the *file* stays consistent even if the rule is broken
(`store-sqlite/main.go:17-21`); the flock is the last line of defence. tidb has
no flock at all — the DSN is shared network state by design, and row locks plus
the rev counter arbitrate (`components/store-tidb/main.go:12-17`): two harnesses
on one TiDB is a feature, while exactly one store process per *bus* is still the
rule.

The store's own self-test proves the rejection: `tests/t_store.nim:44-51` boots
a second store against the same root and asserts a non-zero exit.

### 1.3 Engine selection — `NIF_STORE_BACKEND`, and what the default is

All three engines register as the component name **`store`** with identical tool
names (`sdk.New("store", "0.1.0")` in both Go files, `newComponent("store",
"0.1.0")` in Nim) — nothing downstream (core, agent, fabric, UIs, cli) learns
which one is live. `manifest.yaml:14-18` keeps the single `store` entry
(`binary: var/bin/store`, `autostart`, `required`, `restart: on-failure`), and
**core rewrites that entry's binary at boot** (`core/niffler.nim:484-496`):

| `NIF_STORE_BACKEND` | binary booted | note |
|---|---|---|
| unset or `sqlite` | `var/bin/store-sqlite` | **the default** |
| `barrel` | `var/bin/store` | the manifest's own entry |
| `tidb` | `var/bin/store-tidb` | needs `NIF_STORE_TIDB_DSN` |
| anything else | — | `quit("core: unknown NIF_STORE_BACKEND '…' (sqlite|barrel|tidb) — refusing to boot", 1)` (`core/niffler.nim:491-492`) |

Two subtleties worth recording:

- **unset is a default, not a demand** (`core/niffler.nim:493-501`): if
  `store-sqlite` is not built (e.g. a checkout that built only the Nim
  components) core warns and falls back to the manifest binary `var/bin/store`.
  An *explicit* `NIF_STORE_BACKEND=sqlite` with a missing binary instead falls
  through to the generic "missing binary for store" warning — deliberately never
  a silent switch to a different database.
- The test suite mirrors the same resolver twice
  (`tests/helpers.nim:291-330`), including the missing-binary fallback, so a
  sandbox test never seeds one engine while core reads another.

### 1.4 What changes per engine

| | barrel | sqlite | tidb |
|---|---|---|---|
| storage | `var/barrel-db` (Bitcask data file, critbit index mode set at open, `main.nim:61`) | `var/store.db` (WAL, `synchronous(NORMAL)`, `busy_timeout` 10 s, single pooled conn) | tables in a TiDB/MySQL database named by the DSN |
| concurrency | flock; `put` = **two** `db.set` calls (doc key, then rev key) | flock; `put` = **one** statement per branch (upsert `INSERT … ON CONFLICT … RETURNING`, or one CAS `UPDATE`) | **no flock**; `put` = CAS `UPDATE` (expectRev>0) or `SELECT … FOR UPDATE` + insert/bump inside a transaction |
| crash window | yes — a crash between the two `db.set`s updates content without its revision, leaving the doc *invisible* forever (`list` skips `rev == 0` as a tombstone, `main.nim:155`) | none; doc+rev move together | none |
| deletes | tombstone: `db.delete` writes an empty record, the key stays in the file (`bitbarrel/barrel.nim:569-573`); the store hides it by `rev == 0` | row is gone (`DELETE FROM docs`) — no rev-0 ghosts (`store-sqlite/main.go:50-56`) | row is gone |
| `list` internals | `keysByPrefix(prefix, min(limit,1000), cursor)` over the critbit index; the cursor is **strictly exclusive** (`key <= cursor` skipped, `bitbarrel/storage/critbitindex.nim:351-369`) | `WHERE kind = ? AND id LIKE ? ESCAPE '\' [AND id > ?] ORDER BY id LIMIT ?` | same query, `utf8mb4_bin` columns |
| `limit` < 1 | returns **1** item with `hasMore: true` (critbit's `collected >= limit` check fires after the first key) | clamps to 1 | clamps to 1 |
| schema | none, ever | goose `00001_init.sql`, embedded (`//go:embed migrations/*.sql`), applied at startup, one line printed per applied migration | same, `goose.DialectMySQL` |
| introspection | `strings` carving | `sqlite3 var/store.db 'select kind, count(*) from docs group by kind'`, DuckDB attach (read-only second reader) | ordinary SQL against the cluster |

Both deliberate sqlite divergences are declared in its header and are
**accidental barrel behaviours being fixed, not contract changes**: no
tombstone ghosts, and `limit < 1` clamped to one (`store-sqlite/main.go:50-56`).
One further divergence exists that is *not* a fix — it is a crash: barrel's
`put` does `$value` on the raw arg (`main.nim:110-111`), and `$` on a nil
`JsonNode` is a SIGSEGV in Nim 2.2.12 (verified: `nim c -r` of `import std/json;
var n: JsonNode; echo $n` → `SIGSEGV … (Attempt to read from nil?)`, exit 139;
the SDK's pump only catches `CatchableError`, `sdk/niffler/sdk.nim:720-727`),
so a `put` with no `value` **kills the barrel store process** (supervisor
restarts it) while sqlite/tidb return `put needs kind, id and value`
(`store-sqlite/main.go:292-294`, `store-tidb/main.go:257-259`).

### 1.5 Migration, and the refusal to boot over an un-migrated barrel

Switching engines moves nothing. Core therefore refuses to start when the
engine it is about to run is sqlite (explicitly or by default), `var/bin/store-sqlite`
exists, `var/store.db` does **not** exist and `var/barrel-db` does — with the
exact message reproduced in the MANUAL, and exit 1 (`core/niffler.nim:444-470`).
The guard is deliberately narrow: it does not fire when the sqlite binary is
missing (that path warns instead) and does not fire when `var/store.db` already
exists.

`niffler-store-migrate` (`tools/store_migrate.nim:1-24`) is the offline mover.
Verified behaviour:

- It starts its **own** private nats-server (ephemeral port, reads the ports
  file, prefers the bundled build that accepts `--max_payload 8388608`) and its
  own engine processes with `NIF_ROOT` + `NIF_NATS_URL` injected
  (`store_migrate.nim:152-236`), so no harness needs to be running. A live
  harness is not detected explicitly; it fails indirectly because the running
  store holds the flock (`waitRegistered` then dies "source engine … did not
  register", `:330-332`).
- Source and target engines are started **one at a time** (they would share the
  queue group, `:310-312`), the source is read with a paging `list`, the doc set
  is held in memory, then the target is started and every document is replayed
  with a plain `put` (`:340-369`).
- It **never writes to the source** (`:6-9`, and the read path only calls
  `list`).
- It **refuses to overlay an existing target**: `if fileExists(targetDb) → die
  "target … already exists … refusing to overlay (move it aside or use a fresh
  root)"` (`:296-299`). For the tidb target `dbName` is the string
  `"store-tidb.db"`, a marker that is never created, so that check can never
  fire (see §5, `code-bug?`).
- It verifies per-kind counts after the write phase and dies on a mismatch
  (`:371-386`).
- Migration is one-directional in practice: the source is always
  `engineFor(root, "barrel")` and a root holding only `store.db` dies with
  "root already uses sqlite … nothing to migrate" (`:283-294`).
- `--force` is parsed (`:444-445`) and documented in the file header (`:11`) but
  **read nowhere** — it is a no-op (see §5).

## 2. Its tools

Four tools on every engine — `put`, `get`, `list`, `del` — plus the SDK's
hidden `selftest`, which only the barrel engine implements
(`sdk/niffler/sdk.nim:155-167`). The barrel engine registers its five in
`components/store/main.nim`, sqlite in `components/store-sqlite/main.go`,
tidb in `components/store-tidb/main.go`; the schemas of the four contract tools
are word-for-word identical across the three (so the LLM sees the same
description whichever engine is live).

| Tool | barrel (`components/store/main.nim`) | sqlite (`components/store-sqlite/main.go`) | tidb (`components/store-tidb/main.go`) | x-harness, verbatim | args | result |
|---|---|---|---|---|---|---|
| `put` | `:78-115` (schema `:78-88`, registered `:90`) | `:247-339` (schema `:247-266`, handler `:268`) | `:212-327` (schema `:212-231`, handler `:233`) | `{"onDemand": true, "sessionId": true}` (`main.nim:89`; `main.go:264`; `main.go:229`) | `kind`, `id`, `value` (all required), `expectRev` (default 0) | `{ok, rev}` — new revision |
| `get` | `:117-127` | `:345-378` | `:334-365` | `{"onDemand": true}` (`:117`; `main.go:358`; `main.go:347`) | `kind`, `id` | `{ok, rev, value}` or `{ok: false, error: "not found", code: "not-found"}` |
| `list` | `:129-169` | `:386-480` | `:375-469` | `{"onDemand": true}` (`:129`; `main.go:404`; `main.go:393`) | `kind` (required), `idPrefix`, `limit` (default 100, cap 1000), `after` | `{ok, items: [{id, rev, value}], hasMore, nextAfter?}` |
| `del` | `:171-179` | `:486-517` | `:475-505` | `{"hidden": true}` (`:171`; `main.go:498`; `main.go:487`) | `kind`, `id` | `{ok: true}`, idempotent |
| `selftest` | `:181-232` (barrel supplies the handler; the SDK registers the tool) | not registered (four tools only) | not registered | `{"hidden": true}` (`sdk/niffler/sdk.nim:167`) | `deep` (default false) | `{ok, summary, checks: [{name, ok, detail, ms}]}` |

**The hidden flag is real, not cosmetic.** `del` carries only `hidden: true`, so
it is never in a conversation's frozen direct toolset and core's `invoke`
refuses it exactly as if the name were unknown (same error text for unknown and
hidden tools, `core/dispatch.nim:286-290`) — it is reachable only by core's own
direct `svc.store.call` (`core/dispatch.nim:268-270`). `selftest` is the one
deliberate exception to global tool-name uniqueness (docs/WIRE.md) and is
addressed per component subject by `/doctor`.

**`put`'s `sessionId: true` is what makes the write fence work.** Core injects
`__session = {"session": <live conversation id | "">}` for any schema carrying
`x-harness.sessionId` (`core/dispatch.nim:1650-1656`; it is private context, not
part of the request prefix). All three engines then refuse a **session-bound**
call whose `kind` is not `fabricprog` with
`{ok: false, error: "sessions may only put curated kinds (fabricprog); '<kind>' is
harness-managed", code: "forbidden-kind"}` (barrel `main.nim:100-106`, sqlite
`main.go:281-290`, tidb `main.go:246-255`). Direct bus callers — `cli`, tests,
core — carry an empty session and keep full access; that asymmetry is the whole
design (no live session can corrupt transcripts or component records), and it is
also why `core`'s own writes through `storePutRev` are unaffected.

**`selftest`** is registered by the barrel engine only (`main.nim:181-232`;
neither Go engine calls the Go SDK's equivalent — I checked both `main.go`
files and `sdk/go/storeclient.go`/`component.go` for a `SelfTest` helper: none is
used by `store-sqlite`/`store-tidb`). Its content is a genuine roundtrip on a
throwaway `selftest` document (put → read back verbatim → rev counter is 1 →
visible under the kind prefix → delete removes both keys), reported as
per-check `{name, ok, detail, ms}` with `summary: "engine roundtrip ok (<binary
basename>)"`. `deep` is accepted and ignored, which is allowed by docs/WIRE.md
("quick mode … under ~10s; `deep` may run real probes") but means a `deep`
call against sqlite/tidb gets a "no selftest tool" report from `/doctor`.

### 2.1 Paging semantics (identical on all three engines, by construction)

- `limit` defaults to **100** (barrel: the proc signature `limit: int = 100`,
  `main.nim:130`; sqlite/tidb: `if limit == 0 { limit = 100 }`, `main.go:428`,
  `main.go:417`) and is **capped at 1000** (`min(limit, 1000)` barrel
  `main.nim:151`; `if limit > listCap { limit = listCap }` with `listCap = 1000`,
  sqlite `main.go:82,433`, tidb `main.go:72,422`).
- `after` is an **exclusive id cursor**: barrel skips `key <= "d:<kind>:<after>"`
  (critbit `:353-354`), sqlite/tidb add `AND id > ?`. The reply's `nextAfter` is
  the **last returned item's id**, ready to be passed back verbatim.
- `hasMore` means "the page came back full" on all three engines — barrel's
  `keysByPrefix` sets it when `collected >= limit`
  (`bitbarrel/storage/critbitindex.nim:366-369`), sqlite/tidb compute
  `len(items) >= limit` (`main.go:474` / `:463`). A full page may therefore have
  no successor; the caller fetches one more page and stops on an empty one.
- `nextAfter` is emitted only when `hasMore` is true **and** the page is
  non-empty (`main.nim:167-168`, `main.go:476-478`, `main.go:465-467`) — so
  "`nextAfter` absent ⇒ no more data" holds on every engine.
- The barrel page advances the cursor from the last returned **key**, not the
  last returned *item*, so a page whose documents are all tombstoned still moves
  forward instead of stranding the caller (`main.nim:154-165`; the code notes
  that a trailing spurious `hasMore` is harmless because the follow-up page comes
  back empty).
- Consumers are expected to loop: `storeListAll` in `core/dispatch.nim:224-266`
  and the SDK client (`sdk/niffler/sdk.nim:355-387`) both page to exhaustion
  with a runaway guard (10 000 pages core, 100 000 in the migrate tool).

### 2.2 The `list` *result* differs from the SQL engines' *rows* in one way only

barrel re-serializes the stored text through Nim's JSON (`parseJson(db.get(...))`,
`main.nim:157`), so key order and number formatting can be normalized; sqlite and
tidb hand back the stored bytes as `json.RawMessage` (`main.go:376`, `:365`) —
byte-identical to what was put in. Both are "the same JSON document" to a JSON
consumer, which is why the contract test passes against all three
(`components/store-sqlite/main.go:36-40`).

## 3. Configuration — every `NIF_*` read by each engine

**barrel (`components/store/main.nim`)** — reads **no store-specific variable**.

| Var | Where | Default | Effect |
|---|---|---|---|
| `NIF_ROOT` | via `rootVarDir("barrel-db")` → `rootDir()`, `sdk/subjects.nim:35-40` | `"."` (the process cwd; core always sets `NIF_ROOT`) | the data path is `<NIF_ROOT>/var/barrel-db`, the lock `<NIF_ROOT>/var/barrel-db.lock` (`main.nim:58,43`) |
| `NIF_NATS_URL` | SDK pump, `sdk/niffler/sdk.nim:786` | `nats://127.0.0.1:4222` | the bus the component serves |
| `NIF_ROOT`-relative `.env` | `sdk/niffler/sdk.nim:790` | — | `.env` in cwd and `<NIF_ROOT>/.env` are loaded, existing env wins |

No timeout, size, TTL or index knob exists for the barrel engine: `bmCritBit`
mode is hardcoded (`main.nim:61`) and the barrel config is otherwise
`defaultBarrelConfig()`. BitBarrel's default TTL applies (`defaultTtl`) but the
store never passes a TTL, so documents do not expire.

**sqlite (`components/store-sqlite/main.go`)** — also **no store-specific
variable**; the file, the lock and every pragma are code-resident.

| Var | Where | Default | Effect |
|---|---|---|---|
| `NIF_ROOT` | `main.go:127-129` | `"."` (then `<root>/var` is `MkdirAll`ed, `:130-133`) | data `<NIF_ROOT>/var/store.db`, lock `<NIF_ROOT>/var/store.db.lock` (`main.go:81,135-136`) |
| — | `main.go:140-145` | hardcoded DSN | `_txlock=immediate`, `_journal_mode=WAL`, `_busy_timeout=10000` (ms), `_pragma=synchronous(NORMAL)` |
| — | `main.go:152-153` | — | `SetMaxOpenConns(1)`, `SetMaxIdleConns(1)` — one connection, so exactly one SQLite write lock and no `SQLITE_BUSY` in practice |

**tidb (`components/store-tidb/main.go`)** — exactly one variable.

| Var | Where | Default | Effect |
|---|---|---|---|
| `NIF_STORE_TIDB_DSN` | `main.go:71,99-105` | **none** — empty ⇒ boot fails with "… not set (e.g. \"root@tcp(127.0.0.1:4000)/niffler\") — the TiDB engine has no local default" | the cluster connection: `go-sql-driver/mysql` DSN, e.g. `root@tcp(host:4000)/niffler` |
| — | `main.go:113` | forced `ClientFoundRows = true` | so the CAS `UPDATE` reports *matched*, not *changed*, rows — without it a same-value conflict would look like success |
| — | `main.go:114-116` | `Timeout 5s`, `ReadTimeout 60s`, `WriteTimeout 30s` | connect/read/write budgets (not configurable by env) |
| — | `main.go:119-125` | forces `time_zone = '+00:00'` **unless the DSN sets `time_zone`** | deterministic `updated_at` across hosts; an explicit DSN choice is never overridden |
| — | `main.go:133-135` | `SetMaxOpenConns(1)`, `SetMaxIdleConns(1)`, `SetConnMaxLifetime(10m)` | one session (so the `FOR UPDATE` transaction stays on one connection) |

**core-side, read by `core/niffler.nim` (not by any engine):**

| Var | Where | Default | Effect |
|---|---|---|---|
| `NIF_STORE_BACKEND` | `core/niffler.nim:451,485-496` | unset ⇒ sqlite | picks the binary (see §1.3); unknown value refuses to boot; also arms the un-migrated-barrel guard (`:451`) |

**Test/build only** (not consulted by a running harness):
`NIF_STORE_BIN` — an explicit store binary for the contract tests, read by
`tests/helpers.nim:295-300` and passed by `Makefile:494,502`; `NIF_REPO_ROOT`
for the sandboxes. `NIF_STORE_BACKEND` is also honored by the tests
(`helpers.nim:298-311`).

**Timeouts the tools do not declare:** none of the four store tools carries
`x-harness.timeoutMs`; callers pick the budget. Core's own store client uses
`timeoutMs = 5000` per call (`core/dispatch.nim:188-199`), and the migrate tool
uses 60 s (`tools/store_migrate.nim:236`).

## 4. How `docs/MANUAL.md` covers it today

### 4.1 Every place the store appears (current line numbers, MANUAL = 3072 lines)

| MANUAL | What it says there |
|---|---|
| `## Layout of a running system` :33 | `var/store.db` row :44 — "the SQLite store's data file (default engine) — **single-writer** … Older harnesses/migrated roots use `var/barrel-db` instead" |
| `### Shipped components` :55 | the `store` row :59 (now: "All four tools are on-demand, and `del` is additionally hidden") |
| `### Minimal boot profile (--minimal)` :168 | `store` named as one of the three minimal components :179 |
| `### Store engines` :267-318 | the engine inventory + the `list` paging paragraph |
| `### Migrating between engines` :319-348 | the boot-guard message, the offline mover, the flags list |
| `## State and configuration` :350 | table rows :359 (`Environment / .env`), :361 (**The store**), :365 (`var/`) |
| `## Environment variables` :384 | :387 (`NIF_STORE_BIN` declared script-only), :398 (`NIF_STORE_BACKEND`), :399 (`NIF_STORE_TIDB_DSN`), :482 (repeat) |
| `## Progressive tool discovery` :1840 | `### Shipped policy` :2039 — on-demand list :2053 (store `get`/`list`), hidden list :2061-2066 (store `del`), :2066-2067 ("Store `put` is on demand (it carries `x-harness.sessionId` …)") |
| `## Recovery` :2829 | :2832-2835 — a store that refuses to start means the lock is still held (`var/store.db.lock` / `var/barrel-db.lock`) |
| `## The store` :2864-2909 | the document model, the fence, the kind table, the backend paragraph, the paging pointer |
| `## Troubleshooting` :3058 | :3067 two writers on one data file, :3068 the un-migrated-barrel refusal |
| `## Testing` :2911 | the store's engine matrix is not mentioned (see §5) |
| elsewhere | :700 `approval` kind, :908 never replicate the store, :929 `component` kind, :975 `plugin` kind, :1090/:1236 `provider` kind, :1655/:1730 `mcp` kind, :2008 `session` kind |

### 4.2 The exact current text of the three anchors

**(a) `## The store` (docs/MANUAL.md:2864), first paragraph :2866-2875 (unchanged by the consolidation):**

```
`store` is a component like any other — a document store over the bus with
`put` / `get` / `list` / `del` and rev-based optimistic concurrency
(`put` accepts `expectRev` and fails with `rev-conflict` on mismatch).
`get` and `list` are on-demand tools; `del` is hidden — core deletes records,
the model cannot. A **session-bound caller may only write curated kinds**
(`fabricprog` today): every other kind is harness-managed and refused with
`forbidden-kind`, so no live session can corrupt transcripts or component
records. Direct bus callers (cli, tests, core) keep full access.
Kinds in use by core and its components (the store tools' own docstrings name
only a subset — this table is the complete list):
```

**:2899-2905 (backend paragraph) and :2907-2909 (paging pointer):**

```
Backend is the selected engine — SQLite at `var/store.db` by default,
BitBarrel at `var/barrel-db` with `NIF_STORE_BACKEND=barrel`, or the
DSN-shared TiDB engine (`NIF_STORE_TIDB_DSN`, no flock — row locks and the
rev counter arbitrate between harnesses). **Exactly one process owns that
file** — never run two file-backed `store` processes against the same
database (a second core booted against the same root would do exactly that;
use a temp `NIF_ROOT` copy for experiments).

`list` is a page, not a complete view (see [Store engines](#store-engines)):
everything in core that must see a whole kind goes through `storeListAll` —
a single capped `list` silently truncated long transcripts on resume.
```

**(b) the shipped-components row, docs/MANUAL.md:59 — as it reads *now*, after the consolidation added the on-demand clause (the middle sentence is the one this report's earlier draft wanted):**

```
| `store` | Nim/Go | required | document store over the bus (`put/get/list/del`, rev-based concurrency). All four tools are on-demand, and `del` is additionally hidden — core deletes records, the model cannot. Engines register under the same name with identical tools: `store-sqlite` (Go, SQLite + goose migrations, `var/store.db`) is the **default**; `barrel` (`var/bin/store`) and `tidb` remain selectable with `NIF_STORE_BACKEND` — see [Store engines](#store-engines) |
```

**(c) the state/configuration table, docs/MANUAL.md:357-366** (store-relevant rows, verbatim; the section opens at :350 with "Niffler has no single config file. State is spread across five places, chosen by lifetime…"):

```
| **The store** (kind table in [The store](#the-store)) | conversation headers, messages, the `provider` registry (credentials included), frozen per-conversation toolsets, the slash table, plugin/component install records, subagent job/lineage records, fabric programs, MCP server configs | durable — the harness's database |
```
*(:361)*

```
| **`var/`** (gitignored) | `bin/` built binaries, `logs/` bus JSONL + child logs, `models/` catalog cache, `nats-url`/`nats-pid` bus claiming, `processes/` spools, `repomap-tags/` per-file tags cache (`{mtime, tags}` JSON keyed by the sha1 of the absolute path; empty results are never cached), `fetch/`, `captures/`, `store.db` (the store engine's file — exactly one owner) | runtime, regenerable |
```
*(:365 — the `var/` row gained `processes/` detail in the consolidation; it still names only `store.db` and neither lock file)*

**(d) and the two rows the same table's `Environment / .env` row points at — docs/MANUAL.md:398-399, verbatim (unchanged):**

```
| `NIF_STORE_BACKEND` | store engine selected at boot: `sqlite` (default → `var/bin/store-sqlite`), `barrel` (→ `var/bin/store`), `tidb` (→ `var/bin/store-tidb`); anything else refuses to boot. All engines register as component `store` with identical tools — see [Store engines](#store-engines). An un-migrated barrel makes core refuse to boot with the `niffler-store-migrate` instructions; `barrel` here is the escape hatch | `sqlite` |
| `NIF_STORE_TIDB_DSN` | TiDB/MySQL DSN for the `tidb` store engine, e.g. `root@tcp(127.0.0.1:4000)/niffler` (docker single-node: `docker run -p 4000:4000 pingcap/tidb`). Required for that engine — no local default; the component refuses to boot without it. Sessions are forced to UTC unless the DSN sets `time_zone` | unset |
```

### 4.3 The three items the brief names: present, correct, or missing?

**The kind table (:2877-2897) — PRESENT AND CORRECT, row by row.** I checked
all 19 rows against every store write site in the tree (core, agent, plugins,
fabric, provider, mcp, compaction, the store's own self-test) and found no
missing kind and no wrong id/value:

| MANUAL row | evidence |
|---|---|
| `conversation` `conv-<ts>` | `core/conversation.nim:249,425` |
| `message` `<convId>:<seq>` | `core/conversation.nim:266` — the id is `convId & ":" & align($seqNo, 6, '0')`, i.e. **zero-padded to 6 digits** (the one detail the row omits, see the delta list) |
| `component` `<name>` | `core/dispatch.nim:340,366` |
| `plugin` `<pkg name>` | `components/plugins/main.nim:141-144` |
| `provider` nickname + `active` | `components/provider/main.go:37-38,403` |
| `session` `<sessionId>:tools` | `core/conversation.nim:495,510,1276` |
| `slash` `slash` | `core/niffler.nim:562` (catalog checkpoint) |
| `agentjob` / `agentnotice` / `sessionmeta` | `components/agent/main.nim` (24/18/20 call sites) |
| `fabricprog` | `components/fabric/fabric.nim` (2 sites) and the store's own fence |
| `profile` | `core/dispatch.nim:398,416,424` |
| `approval` `<sessionId>:<key>` | `core/niffler.nim:580`, `core/approval.nim:126-129` (`tool` or `tool:<digest>`) |
| `contextreceipt` | `core/conversation.nim:304` |
| `compaction_input` (+ `:p<idx>` pages) | `core/conversation.nim:1533-1537` |
| `context_projection` | `core/conversation.nim:1688` |
| `spill` | `core/conversation.nim:1305` (id = `nextMsgKey()`, so `<convId>:<n>`) |
| `mcp` | `components/mcp/types.go:12` (`const kindMCP = "mcp"`), used at `main.go:573-581` |
| `selftest` | `components/store/main.nim:189,198-232` |

**The plaintext-credential note (:2883) — PRESENT AND CORRECT for `provider`,
INCOMPLETE for the store as a whole.** `apiKey` really is a plaintext field of
the stored record (`components/provider/main.go:11,63,384`), and redaction
does happen only in tool output. But the same store holds a second kind with
user-supplied secrets: an `mcp` record's `env` and `headers` maps are stored
verbatim (`components/mcp/types.go:19-21`; only `${NAME}` references stay
symbolic) and only *listings* redact them (`docs/MANUAL.md:1730-1731`, the
`mcp_add` schema text at `components/mcp/main.go:85-88`). Since §The store is
where the "the store file itself is the secret" rule is stated, the sentence
should cover both kinds — and, because that rule is the whole protection, also
say plainly that any copy of `var/store.db` / `var/barrel-db` is a copy of the
credentials: a manual backup, a benchmark root (`var/bench/**/niffler-root`),
a cloned or migrated root. There is no redaction, expiry or rotation path for a
stored credential beyond deleting the file (`make clean` removes all of `var/`,
which takes conversations with it; `--recover` wipes only component records).

**The migration instructions (:319-348) — PRESENT, WELL-SHAPED, AND WRONG IN
THREE PLACES.** The reproduced core error block (:326-332) is byte-accurate
against `core/niffler.nim:462-469`, and `--scan`'s search scope (:344-345) is
accurate (`tools/store_migrate.nim:108-147`). What is false:

1. :337-339 "It reads **every document** from the source engine over the bus
   contract (so **any engine pair works, including TiDB**)" — the kind set is a
   hardcoded 18-name probe list (`tools/store_migrate.nim:398-407`) that
   contains neither `spill` nor `contextreceipt`, so those documents are read by
   nobody and **silently dropped**. Measured: a barrel root seeded with
   `conversation`, `message`, `spill`, `contextreceipt` and `mcp` (one doc each,
   the store itself answering 5× `{"ok":true,"rev":1}`) migrated with
   `total: 3 documents read` … `wrote 3 documents into store.db` …
   `verified: every kind matches the source count` … `done.` — i.e. 2 of 5
   documents lost **with a success report**, because the verification loop only
   re-counts the kinds it discovered. The source engine is also always
   `engineFor(root, "barrel")` (`:283-294`): a root whose data is in SQLite dies
   with "root already uses sqlite … nothing to migrate" even when `--to barrel`
   is passed (measured), so sqlite→barrel and tidb→anything do not work at all.
2. :345-346 "Migration refuses to overlay an existing target database" — true in
   effect for the default target, but by accident and for the wrong reason: the
   reachable refusal is the *source* check `both store.db and barrel-db exist …
   ambiguous source; move one aside first` (`:290-292`), which is exactly the
   state a *successful* migration leaves behind (measured: the second run dies
   there). The overlay check itself (`:296-299`) can never fire for
   `--to sqlite` (the source check already guarantees `store.db` is absent) and
   for `--to tidb` it tests `fileExists(<root>/var/store-tidb.db)` — a marker
   file that nothing ever creates (`:78-84`), so migrating *into* a shared
   cluster overlays silently, with rev-bumping upserts.
3. :347-348 "The same export/replay path moves data in **either direction**" — same
   as (1): only barrel→sqlite/tidb exists.

And one trap the section does not mention at all: after migrating, the root
holds **both** `var/barrel-db` and `var/store.db`, and every later
`niffler-store-migrate --root` on it dies with "ambiguous source" — including
the user who followed the documented rollback (`NIF_STORE_BACKEND=barrel`),
kept using barrel for a while, and now wants to migrate again.

## 5. DELTA list

Rows are `- MANUAL: <exact quote> | CODE: <path:line> | FIX: <verb + wording>`,
one finding per line, grouped under a `## ` heading that is the **exact current
MANUAL heading** the finding lands in (they are H2 siblings of this list for
that reason). Every row carries a verbatim MANUAL quote so the ledger can
re-anchor it even after the manual moves. `FIX: none (verified)` marks a
check that passed. Qualifiers in the FIX field carry the class where the
parser cannot infer it: `(claim is false)`, `(code bug)`, `(small)`.

## Layout of a running system

Rows from three subsections of this section: the `var/store.db` layout row
(:44) and the shipped-components row (:59); `### Store engines` (:267-318);
`### Migrating between engines` (:319-348) — including two findings whose home
is the offline mover itself (its kind probe list drops whole kinds; `--force`
is a dead flag).

- MANUAL:44 "| `var/store.db` | the SQLite store's data file (default engine) — **single-writer**: exactly one `store` process may open it. Older harnesses/migrated roots use `var/barrel-db` instead |" | CODE: `core/niffler.nim:444-470` (the guard requires `store.db` to be absent), `tools/store_migrate.nim:296-312` (a migrated root keeps both files) | FIX: update — "Older, un-migrated harnesses still use `var/barrel-db`; a migrated root keeps that file untouched next to `var/store.db` (which is what the engine then reads). Each engine also locks its own file: `var/store.db.lock` / `var/barrel-db.lock`."
- MANUAL:44 "**single-writer**: exactly one `store` process may open it" | CODE: `components/store-sqlite/main.go:162-176`, `components/store/main.nim:39-51`, `tests/t_store.nim:44-51` | FIX: none (verified) — the flock, its non-blocking exit(1), and the second-writer rejection are all real; the same rule is stated again at :3067.
- MANUAL:59 "Engines register under the same name with identical tools" | CODE: `components/store/main.nim:181-232` (barrel registers a hidden `selftest`), `components/store-sqlite/main.go:106-117` and `components/store-tidb/main.go:79-90` (four tools only; no `SelfTest` exists in `sdk/go`) | FIX: update — "the same four tools (`put`/`get`/`list`/`del`); the barrel engine additionally registers the hidden `selftest` (the Go engines do not — `/doctor` reports them as not implementing one)".
- MANUAL:59 "`store-sqlite` (Go, SQLite + goose migrations, `var/store.db`) is the **default**; `barrel` (`var/bin/store`) and `tidb` remain selectable with `NIF_STORE_BACKEND`" | CODE: `core/niffler.nim:485-496`, `manifest.yaml:14-18` | FIX: none (verified) — manifest `required: true`, `restart: on-failure`, and the default is genuinely sqlite.
- MANUAL:275 "core resolves the manifest entry's binary accordingly and refuses to boot on an unknown value" | CODE: `core/niffler.nim:493-501` | FIX: add — "An unset `NIF_STORE_BACKEND` is a default, not a demand: if `var/bin/store-sqlite` was never built, core warns and boots the manifest binary `var/bin/store` (barrel) instead. An explicit value is a demand — a missing binary is only warned about, never silently substituted with another engine's database."
- MANUAL:289 "its `put` is a two-key sequence" ("… a crash between them can update content without its revision", :289-291) | CODE: `components/store/main.nim:107-112,121-123,155` | FIX: add — "…and for a *new* document the doc key is written with no rev key, which both `get` and `list` read as absent (`rev == 0`): the document is unreachable until it is written again."
- MANUAL:277 "**sqlite** (default, `var/bin/store-sqlite`, Go): the same document contract on SQLite" | CODE: `components/store-sqlite/main.go:140-153`, `migrations/00001_init.sql` | FIX: add (small) — the bullet stops at "one atomic statement": say the pragmas are code-resident, not configurable (`_txlock=immediate`, WAL, `synchronous(NORMAL)`, `busy_timeout` 10 s, one pooled connection), and that the goose migration is applied automatically at startup (the file prints one line per applied migration).
- MANUAL:292 "**tidb** (`var/bin/store-tidb`, Go): the same schema over the MySQL protocol (go-sql-driver)" | CODE: `components/store-tidb/main.go:108-135,143-163` | FIX: add — the DSN user needs the rights goose requires to create its version table and apply migrations (on a fresh database, and again whenever a new migration ships); connect/read/write timeouts are hardcoded (5 s / 60 s / 30 s); the engine runs on a single pooled connection (one session, so the `FOR UPDATE` transaction's statements stay together), so N harnesses on one cluster hold N connections and share no pool.
- MANUAL:302 "No flock — the cluster is shared state by design; row locks (`SELECT … FOR UPDATE`, pessimistic transactions) arbitrate writers and the rev counter stays the optimistic-concurrency check." | CODE: `components/store-tidb/main.go:12-17,258-327` | FIX: none (verified) — accurate, including the `ClientFoundRows` requirement behind "rev counter stays the check".
- MANUAL:294-296 "`NIF_STORE_TIDB_DSN` points at the cluster (`root@tcp(host:4000)/niffler`; single-node docker: `docker run -p 4000:4000 pingcap/tidb`)" | CODE: `components/store-tidb/main.go:99-107` | FIX: none (verified) — empty DSN refuses to boot with that example in the message.
- MANUAL:310 "`list` is a **page**, not a complete view: `limit` defaults to 100 and is clamped to 1000, and the reply carries `hasMore` plus a `nextAfter` id cursor." | CODE: `components/store/main.nim:151-168`, `components/store-sqlite/main.go:428-478`, `components/store-tidb/main.go:417-467` | FIX: none (verified) — `limit` default 100 / cap 1000, exclusive `after`, `hasMore` = page-full, `nextAfter` absent when `hasMore` is false. Both local engines passed `tests/t_store_paging.nim` in this audit (2500 docs, 3 pages, tombstone hole; run: barrel + sqlite, see §7).
- MANUAL:337 "It reads every document from the source" ("engine over the bus contract (so any engine pair works, including TiDB),", :338) | CODE: `tools/store_migrate.nim:398-407` (an 18-name hardcoded probe list; `spill` `core/conversation.nim:1305` and `contextreceipt` `core/conversation.nim:304` are absent), `:364-386` (the verification only re-counts discovered kinds) | FIX: update (claim is false) — "It reads every document **of the kinds it probes** (a fixed candidate list — a kind added later is silently skipped, and the per-kind verification cannot notice); the same offline export/replay path is what any engine pair would use."
- MANUAL:337-338 "(so any engine pair works, including TiDB)" | CODE: `tools/store_migrate.nim:283-294` (the source is always `engineFor(root, "barrel")`; a SQLite-only root dies "root already uses sqlite … nothing to migrate") | FIX: update (claim is false) — "the migration direction implemented today is barrel → sqlite (or `--to tidb`, see the DSN caveat below); moving out of SQLite or TiDB is not wired up."
- MANUAL:345 "Migration refuses to overlay an existing" ("… target database;", :346) | CODE: `tools/store_migrate.nim:290-299, 78-84` (the reachable refusal is the *source* check "both store.db and barrel-db exist … ambiguous source"; the overlay check tests `fileExists(<root>/var/store-tidb.db)`, a marker nothing creates) | FIX: update — "Migration refuses to run on a root that holds both `var/barrel-db` and `var/store.db` (the state a previous migration leaves) and never writes to the source; for `--to tidb` there is no local target to protect — the replay upserts into the DSN database."
- MANUAL:347 "The same export/replay path moves data in either" ("… direction.", :348) | CODE: `tools/store_migrate.nim:283-299` | FIX: remove — measured: `--root <sqlite-only root> --to barrel` dies "root already uses sqlite … nothing to migrate".
- MANUAL:335 "`niffler-store-migrate` (in `var/bin`) runs **offline**" ("… and it never edits the source data", :337) | CODE: `tools/store_migrate.nim:152-236, 310-369` | FIX: none (verified) — own nats on an ephemeral port, engines started one at a time, source only ever `list`ed.
- MANUAL:340 "(`--root`, `--to <engine>`, `--dry-run`, `--scan [<top>]`, `--all [<top>]`)" | CODE: `tools/store_migrate.nim:396-420, 430-450` (the parser also accepts `--force`, `--quiet`, `-q` and `--version`) | FIX: add — `--quiet`/`--version` exist and are unlisted; do **not** list `--force`: it is parsed and then read nowhere (the header promises it at `:11`, nothing honours it). Add the trap in the same paragraph: a migrated root holds both `var/barrel-db` and `var/store.db`, so re-running the tool on it — e.g. after the documented rollback (`NIF_STORE_BACKEND=barrel`) plus new barrel history — fails "ambiguous source; move one aside first"; the way back is to move the stale `var/store.db` aside (or delete it).
- MANUAL:344 "`--scan` finds the top directory, sibling clones, and benchmark trees" | CODE: `tools/store_migrate.nim:108-147` | FIX: none (verified) — prunes `.git`/`node_modules`/`nimcache`; a root counts as un-migrated only when `barrel-db` exists and `store.db` does not (`:90-106`).
- MANUAL: absent (the migrate tool's `--force` does nothing) | CODE: `tools/store_migrate.nim:11,40,289,444-445` (declared, documented in the header, parsed, never read) | FIX: add (code bug) — either honour `--force` (overlay the target / tolerate a live store) or delete the flag and the two claims; the usage text does not list `--force` at all, so the header is the only place it is promised.
- MANUAL: absent (migrate drops kinds outside its probe list) | CODE: `tools/store_migrate.nim:398-407` vs the live kinds `spill` (`core/conversation.nim:1305`) and `contextreceipt` (`core/conversation.nim:304`) | FIX: add (code bug) — measured silent loss with a success report (§4.3); extend `kindProbes()` (and consider a kind-count tripwire that fails the run when the source's own probe list disagrees with what it discovered).

## State and configuration

- MANUAL:365 "`store.db` (the store engine's file — exactly one owner)" | CODE: `components/store-sqlite/main.go:81,136`, `components/store/main.nim:43,58`, `tools/store_migrate.nim:90-96` | FIX: update — "…`store.db` (the SQLite engine's file) or `barrel-db` (the barrel engine's) — whichever `NIF_STORE_BACKEND` selected, plus its `.lock`, which exactly one `store` process may hold at a time."
- MANUAL:361 "conversation headers, messages, the `provider` registry (credentials included)" | CODE: `docs/MANUAL.md:2877-2897` (the kind table) | FIX: none (verified) — the summary matches the table and the table matches the code.

## Environment variables

- MANUAL:398 "store engine selected at boot: `sqlite` (default → `var/bin/store-sqlite`)" | CODE: `core/niffler.nim:451-470` (guard), `:493-501` (fallback) | FIX: add — "An unset value that cannot be satisfied (no `var/bin/store-sqlite`) warns and falls back to `var/bin/store`; the un-migrated-barrel guard fires only for unset/`sqlite` and only while `var/store.db` does not exist yet."
- MANUAL:399 "TiDB/MySQL DSN for the `tidb` store engine" | CODE: `components/store-tidb/main.go:108-116,133-135,143-163` | FIX: add — "The DSN needs the rights goose requires to apply its migrations (a fresh database, and again whenever a new migration ships). Its connect/read/write timeouts (5 s/60 s/30 s) and its single pooled connection are code-resident, not env-tunable."
- MANUAL:387 "are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness" | CODE: `tests/helpers.nim:291-311`, `Makefile:494,502` | FIX: none (verified) — `NIF_STORE_BIN` is read only by the test helpers.
- MANUAL: absent (no statement that the store engines have **no** per-engine knobs) | CODE: `components/store/main.nim` (only `NIF_ROOT`/`NIF_NATS_URL` via the SDK), `components/store-sqlite/main.go:127-153`, `components/store-tidb/main.go:99-135` | FIX: add (small) — one line in §Store engines: "The engines have no store-specific environment knobs: file path, lock path, pragmas and timeouts are code-resident (`NIF_ROOT` decides the root, `NIF_STORE_BACKEND` the engine)."

## Recovery

- MANUAL:2832-2835 "a `store` that refuses to start means another process still holds the lock (`var/store.db.lock` / `var/barrel-db.lock`), not a stale file" | CODE: `components/store-sqlite/main.go:162-176`, `components/store/main.nim:39-51` | FIX: none (verified) — both lock file names are exactly right, and the kernel releases the lock on crash.

## The store

Rows for the section itself (:2864-2909) plus one finding about the store's
own tool surface (the barrel `put` crash) that has no MANUAL sentence yet.

- MANUAL:2869 "`get` and `list` are on-demand tools; `del` is hidden — core deletes records, the model cannot." | CODE: `components/store/main.nim:89` (`put`: `{"onDemand": true, "sessionId": true}`), `:117`/`:129` (get/list onDemand), `:171` (del hidden); the same flags verbatim in `components/store-sqlite/main.go:264,358,404,498` and `components/store-tidb/main.go:229,347,393,487` | FIX: update — "`put`, `get` and `list` are on-demand (discover-only); `del` is hidden — core deletes records, the model cannot. `put` also carries `x-harness.sessionId` (that is what makes the write fence below possible)." (The fuller statement already exists at :2066-2067; this keeps §The store from contradicting it.)
- MANUAL:2866-2867 "`store` is a component like any other — a document store over the bus with `put` / `get` / `list` / `del` and rev-based optimistic concurrency" | CODE: `components/store-sqlite/main.go:106-117`, `components/store-tidb/main.go:79-90`, `sdk/niffler/sdk.nim:155-167` | FIX: add (small) — the store also registers the hidden `selftest` tool on the barrel engine (`components/store/main.nim:181-232`): a real put/get/rev/list/del roundtrip core's `/doctor` can call.
- MANUAL:2883 "Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only" | CODE: `components/provider/main.go:11,63,384` (true for `provider`), `components/mcp/types.go:19-21` + `components/mcp/main.go:85-88` (`mcp` `env`/`headers` values are stored verbatim too) | FIX: update — "Credentials are stored in **plaintext** — the store file itself is the secret — and redaction happens in the tool responses only. That covers the `mcp` records' `env`/`headers` values as well as `provider` keys, so any copy of `var/store.db`/`var/barrel-db` is a copy of them."
- MANUAL:2880 "| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |" | CODE: `core/conversation.nim:266` (`convId & ":" & align($seqNo, 6, '0')`) | FIX: update — "`<convId>:<seq>`, the sequence zero-padded to six digits (`…:000042`); the padding is what makes id-ordered paging match message order (see the boundary note in §6 — past 999 999 messages the width grows and lexicographic order stops matching)."
- MANUAL:2870 "A **session-bound caller may only write curated kinds**" ("(`fabricprog` today):", :2871) | CODE: `components/store/main.nim:100-106`, `components/store-sqlite/main.go:281-290`, `components/store-tidb/main.go:246-255`, `core/dispatch.nim:1650-1656` | FIX: none (verified) — the fence, the `forbidden-kind` code and the "direct bus callers keep full access" asymmetry are all exactly as written, on all three engines.
- MANUAL:2899 "Backend is the selected engine — SQLite at `var/store.db` by default" | CODE: `core/niffler.nim:485-496`, `components/store-sqlite/main.go:81,135`, `components/store/main.nim:58`, `components/store-tidb/main.go:71` | FIX: none (verified).
- MANUAL:2907-2909 "everything in core that must see a whole kind goes through `storeListAll`" | CODE: `core/dispatch.nim:224-266` (+ call sites in `core/conversation.nim:399`, `core/dispatch.nim:451,695`) | FIX: none (verified) — the helper pages the cursor to exhaustion with a 10 000-page runaway guard.
- MANUAL: absent (barrel `put` without `value` kills the process) | CODE: `components/store/main.nim:110-111` (`$value` on a nil `JsonNode`), `sdk/niffler/sdk.nim:723-725` (the pump catches `CatchableError` only) | FIX: add (code bug) — measured: `put {"kind":"probe","id":"novalue"}` against `var/bin/store` returns no reply (the caller times out) and the process exits **139 (SIGSEGV)**; the same call against `store-sqlite` returns `{"error":"put needs kind, id and value"}` and the process stays up. Guard `value == nil` in the barrel handler (the Go engines already do). No MANUAL wording is needed beyond the "identical tools" qualifier under Shipped components.

## Testing

- MANUAL: absent (the store's three-engine contract is not mentioned) | CODE: `Makefile:491-503` (`test-store`, `test-store-sqlite`, `test-store-tidb` — the TiDB one prints `SKIP` without `NIF_STORE_TIDB_DSN`), `tests/t_store.nim:15-22`, `tests/t_store_paging.nim:1-13` | FIX: add (small) — "The store contract is one test run against every engine: `make test-store` (the selected/default engine), `make test-store-sqlite`, `make test-store-tidb` (needs `NIF_STORE_TIDB_DSN`, otherwise SKIP); `t_store_paging` pins the `after`/`hasMore`/`nextAfter` cursor semantics that resume and migration depend on."
- MANUAL: absent (a phantom make target in the test's own header) | CODE: `tests/t_store_paging.nim:11` ("`make test-store-paging` re-runs it against SQLite") | FIX: add (code bug) — no such target exists (`grep -n store-paging Makefile` → 0 hits); the test runs inside `make test-server` via `TEST_NIM := tests/smoke.nim $(wildcard tests/t_*.nim)` (`Makefile:447`) and is re-run against another engine with `NIF_STORE_BIN=…`. Fix the comment (or add the target).

## Troubleshooting

- MANUAL:3067 "| two stores fight over the same data file (`var/store.db` or `var/barrel-db`) | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |" | CODE: `components/store/main.nim:44-51`, `components/store-sqlite/main.go:32-38` | FIX: none (verified).
- MANUAL:3068 "| boot refuses: \"this harness has conversation history in var/barrel-db\" | the default engine changed to SQLite and your history is still in barrel — run `niffler-store-migrate --root <path>` (the error prints it), or set `NIF_STORE_BACKEND=barrel` to keep the old engine |" | CODE: `core/niffler.nim:462-469` | FIX: none (verified) — the captured message matches byte for byte, including the `--scan` hint and the exit code.

## 6. Not user-facing, and boundary notes

**Should stay out of the MANUAL** (implementation detail, no user action): the
barrel key layout (`d:`/`r:`, `components/store/main.nim:66-67`), the tombstone
key mechanics and the critbit index mode, the `limit < 1` quirk of the critbit
bound (`components/store-sqlite/main.go:50-56` explains it once and that is
enough), the goose file names, the exact SQL of each branch, the core guard's
predicates beyond the one-line summary proposed above, and the migrate tool's
in-memory doc set / 10 000-page guard.

**Boundary notes found while auditing (no MANUAL wording needed, no user hits
them today, listed so the next reader does not rediscover them):**

- **Message ids break lexicographic order at 1 000 000 messages.** The id is
  `convId & ":" & align($seqNo, 6, '0')` (`core/conversation.nim:266`); from
  sequence 1 000 000 the string grows to seven digits, and `"…:1000000"` sorts
  *before* `"…:999999"`. Since `list` is ordered by id and resume pages it with
  the exclusive `after` cursor, a conversation that large would resume with
  messages out of order and could skip the ones that sort behind the cursor. Not
  reachable in practice (a million messages in one conversation), and the fix is
  one line (`align($p.seqNo, 12, '0')` or an unpadded numeric id), but it is the
  one place where "ids sort lexicographically" (docs/WIRE.md "Store contract")
  is load-bearing for correctness rather than convenience.
- **`hasMore` is "page came back full", not "another page exists".** All three
  engines behave this way, so every complete walk ends with one extra empty
  `list` call. Both in-tree loops terminate correctly (`core/dispatch.nim:224-266`,
  `tools/store_migrate.nim:270-289`), and the barrel engine can additionally
  report a spurious trailing `hasMore` (the code says so at
  `components/store/main.nim:160-165`); the follow-up page is empty and the loop
  ends. A caller that treats `hasMore` as "a next page is guaranteed non-empty"
  would do one wasted round trip, never lose data.
- **The store cannot enumerate kinds.** `list` needs a `kind`, so "which kinds
  exist?" is unanswerable over the contract — the reason `migrate` carries a
  hardcoded probe list and the reason that list is a data-loss hazard. If it is
  ever worth a MANUAL sentence, it belongs next to `nextAfter` as the one
  asymmetry of an otherwise complete contract.
- **No `x-harness.timeoutMs` on any store tool.** A caller's own budget rules;
  core's client uses 5 s per page and 1000 items (`core/dispatch.nim:188-199`),
  the migrate tool 60 s (`tools/store_migrate.nim:236`). A pathological root
  (very large documents) can therefore time out a read that would have
  succeeded — recoverable, since the cursor is exclusive.
- **`put` with an unknown extra argument, or a wrong-typed `kind`/`id`, is
  silently tolerated** on every engine (the Nim `argString*` decoders and the Go
  `rawString`/`rawInt` helpers are lenient by design, `store-sqlite/main.go:199-206`).
  Only a *missing* `value` differs — and there it differs violently (§5,
  cross-cutting, measured SIGSEGV on barrel).
- **Platform note (code, not docs):** the barrel engine's lock lives inside
  `when defined(posix)` (`components/store/main.nim:26-30,46-51`), so on a
  non-POSIX build `acquireLock` becomes a silent no-op and the single-writer
  rule is unenforced; the Go engine calls `syscall.Flock` unconditionally
  (`store-sqlite/main.go:164-176`), which would not build there at all. The
  project targets Linux/macOS (`make setup`), so this is a portability hazard
  rather than a live bug — but "silently unenforced" is worse than "does not
  build", so if Windows ever matters the Nim side needs the guard to fail loudly.

## 7. Verification log

**Run (project's own entries, not re-derived):**

| command | result |
|---|---|
| `NIF_STORE_BIN=$PWD/var/bin/store ./var/bin/test_t_store` | `STORE TEST PASSED` (15 checks: register, single-writer rejection, put/get, `expectRev` ok + conflict, list ordered/prefix/limit, del + tombstone + list exclusion, missing doc `not-found`, persistence across restart) |
| `NIF_STORE_BIN=$PWD/var/bin/store-sqlite ./var/bin/test_t_store` | `STORE TEST PASSED` (same 15 checks) — the contract really is one contract |
| `NIF_STORE_BIN=$PWD/var/bin/store ./var/bin/test_t_store_paging` | `t_store_paging PASSED` (2500 docs across 3 pages, exclusive cursor, past the 1000 cap, tombstone hole, second kind isolation) |
| `NIF_STORE_BIN=$PWD/var/bin/store-sqlite ./var/bin/test_t_store_paging` | `t_store_paging PASSED` |
| `nim c -r` of a 6-line scratch program | `$nil` on a `JsonNode` is a SIGSEGV (exit 139) on Nim 2.2.12 — the mechanism behind the barrel `put` crash |
| scratch probe: `put {"kind","id"}` (no `value`) against each engine | barrel → no reply (caller times out), process exit **139**; sqlite → `{"error":"put needs kind, id and value"}`, process alive |
| scratch probe + `var/bin/niffler-store-migrate --root <tmp>` on a barrel root seeded with 5 docs in 5 kinds | `total: 3 documents read` → `wrote 3` → `verified: every kind matches the source count` → `done.` (`spill` and `contextreceipt` dropped silently) |
| `niffler-store-migrate --root <same root>` (second run) | `both store.db and barrel-db exist … — ambiguous source; move one aside first` (and identical with `--force`) |
| `niffler-store-migrate --root <sqlite-only root> --to barrel` | `root already uses sqlite (…/var/store.db) — nothing to migrate` |

All scratch files (`tests/zz_store_probe.nim`, `tests/zz_seed_probe.nim`,
`var/bin/test_zz_*`, `scratch/niltest*`, `scratch/migrate-*`,
`scratch/sqliteonly-*`) were deleted after the run; `git status` shows this
report as the only new file from this audit.

**Not run / could not determine (stated honestly):**

- **The TiDB engine was never executed.** There is no `NIF_STORE_TIDB_DSN` /
  cluster in this environment, so `make test-store-tidb` would print `SKIP`
  (`Makefile:497-503`) and `components/store-tidb/main_test.go:23-25` would skip
  its live cases. Every tidb statement in this report is a source reading; the
  live-verification claim for TiDB v8.5.0 belongs to `docs/research/STORE_V2.md`
  (M4), not to me. "Works against plain MySQL 8 too" is source-supported (goose
  `DialectMySQL`, no procedures/triggers/JSON type) but untested here.
- **External clients of the store were not audited.** The kind table's "this
  table is the complete list" is verified against *this* tree; a UI or plugin
  outside the repo (the `niffler-tui` plugin repo is not in this checkout) could
  write a kind I cannot see. In-tree, the only non-core writer is the UI, and it
  writes kind `conversation` only (`ui/frontend/src/views/Chat.svelte:700`,
  `Sessions.svelte:85`).
- **BitBarrel's file growth / compaction story** (`db.close()` on drain is the
  only lifecycle call, `components/store/main.nim:233`) was not measured: how
  much a tombstone-heavy history leaves on disk, and whether a barrel root ever
  needs an offline rebuild, is a library property I did not test.
- **`--recover`'s exact wipe set** was read at a glance only, and the MANUAL
  claim about it is not a store-engine claim; §5 therefore has no row for it.

## 8. Findings summary

**39 findings** in the delta list, by class (counting rows, including the
cross-cutting ones), with one class per row, counted exactly as the
`normalize.py` classifier would (a row whose FIX contains "code bug" is
`code-bug?`; `FIX: none (verified)` is `verified`):

| class | count | which |
|---|---|---|
| `verified` (MANUAL is right — do not re-audit) | 15 | single-writer/flock (×2: :44 and :3067); the sqlite-default shipped row; the tidb no-flock/row-lock paragraph, its DSN example, and the sqlite bullet's "default"; the whole paging paragraph; the write fence; the backend paragraph; `storeListAll`; `NIF_STORE_BIN` is script-only; the state table's store row; the Recovery lock-file sentence; the un-migrated-barrel Troubleshooting row; the `--scan` scope; "runs offline" |
| `missing` (`FIX: add`, wording absent) | 10 | the unset-is-a-default fallback (:275 and :398); the barrel crash window's invisible-new-document case; the code-resident pragmas; the tidb DSN's migration rights + single connection (:399); that the engines have no per-engine knobs at all; `--quiet`/`--version` + the migrated-root trap (`--to` is now listed); the store's `selftest` tool; the three-engine test matrix |
| `doc-edit` (`FIX: update`) | 9 | :44 "migrated roots use `var/barrel-db`" inverted; :59 "identical tools"; :345-346 migration-overlay claim; :2869 on-demand flags omit `put` (the shipped row's new clause is right, §The store contradicts it); :2880 message-id padding; :2883 plaintext note's scope; :365 `var/` row omits `barrel-db` + the lock files; plus the two the brief calls **`wrong`** — migrating :337 "every document" and :337-338 "any engine pair works, including TiDB", both false in code and in a measured run |
| `code-bug?` | 4 | barrel `put` without `value` SIGSEGVs (measured); `migrate --force` is a dead flag; `migrate`'s kind probe list drops `spill`/`contextreceipt` (measured silent loss); `tests/t_store_paging.nim:11` cites a make target that does not exist |
| `remove` | 1 | migrating :347-348 "moves data in either direction" (delete, not reword) |
| `trim` | 0 | — the store prose is the right size, and §Migrating between engines already points at `STORE_V2.md` in spirit; it needs its claims corrected, not trimmed |

**Five most important findings, in priority order:**

1. **`niffler-store-migrate` silently loses whole kinds** and then reports
   success (MANUAL :337 "every document" is false; `tools/store_migrate.nim:398-407`).
   Measured: 2 of 5 documents dropped, "verified: every kind matches the source
   count", exit 0. This is the only finding in this report that can destroy user
   data, and the MANUAL currently promises the opposite.
2. **The barrel engine's `put` without `value` kills the store process**
   (measured: caller timeout + exit 139; sqlite/tidb answer cleanly). It is one
   line (`components/store/main.nim:110-111`) and the supervisor hides it as a
   restart.
3. **Migration is one-directional and cannot be re-run on a migrated root** —
   MANUAL :337-338 and :347-348 claim otherwise, and the root a successful migration
   produces ("both store.db and barrel-db exist") is exactly the state the tool
   then refuses, so a user who rolls back with `NIF_STORE_BACKEND=barrel` must
   move the stale `var/store.db` aside before migrating again (undocumented).
   `--force` — the flag that sounds like the way out — is parsed and ignored.
4. **The store's plaintext-secret note covers only `provider`** — `mcp` records
   keep `env`/`headers` values verbatim in the same file
   (`components/mcp/types.go:19-21`), so "the store file itself is the secret"
   needs to say so, and to say that any copy of the file is a copy of the
   credentials.
5. **The docs drifted from the code on the small things a reader acts on**:
   `put` is missing from §The store's on-demand sentence (:2869) although
   §Shipped policy (:2066-2067) has it right; `var/` (:365) names only
   `store.db` and neither lock file; and NIF_STORE_BACKEND's unset-means-fallback
   behaviour (core warns and boots barrel when `store-sqlite` was never built)
   is nowhere in the MANUAL.
