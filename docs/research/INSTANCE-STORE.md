# Instance-aware store: delivery contract

Status: first schema slice on `feat/settings`; not yet multi-instance safe.
The instances table alone does not isolate documents. Do not point independent
production harnesses at one dataset until the document-scoping gate passes.

## First slice: stable registry schema

Both engines add an `instances` table through new embedded goose migrations:
SQLite `00003_instances.sql`, TiDB `00002_instances.sql`. Existing applied
migrations are unchanged. Document keys and wire behavior are unchanged in
this slice; no legacy history is assigned, rewritten or deleted.

Columns:

- `instance_id`: stable 32-character lowercase hexadecimal identity, reusing
  `var/instance-id`; primary key. Display names and roots are not unique keys.
- `name`, `root`, `git_hash`: informational metadata, not connection routes,
  authority, permission grants or trusted proof of a remote identity.
- `first_seen`, `last_seen`: database timestamps. Registration preserves
  first_seen on refresh and validates identity at the tool boundary for both
  engines (do not rely on TiDB CHECK support).

Separate hidden `instance_register` and `instance_list` APIs exist in both
engines, with strict validation, atomic refresh and bounded identity pagination.
Core registers its existing persistent identity after store convergence at boot,
before restoring components. Failure warns without blocking normal startup.
This contributes no prompt content and no remote authority. lastSeen records
registration time, not an ongoing liveness heartbeat. No periodic writes, new
env variables, retirement/deletion, document foreign keys or shared fallback
are introduced. See WIRE.md "Store contract".

## Document ownership foundation (staged)

New migrations add `docs.instance_id` and change the primary key to
`(instance_id, kind, id)`. Legacy rows remain under `''`; neither migration
claims them for a connecting instance. SQLite preserves rowids, timestamps,
verbatim values and revisions, so the existing FTS rows remain valid.

Handlers capture an owner at construction for put/get/list/del/search and
selftest. Tests construct two owners against one database to exercise duplicate
keys, independent CAS, list cursors, ranked/unranked search and deletion.
SQLite FTS queries constrain the joined authoritative document's instance_id;
FTS stays derived by document rowid. Global bm25 statistics are not per-instance
ranking statistics; isolation guarantees returned documents, not independent
relevance scores.

**Ownership binding is implemented.** Each engine resolves the owner once at
open (`NIF_INSTANCE_ID`, else `$NIF_ROOT/var/instance-id`, else legacy) and
passes it to every handler; no tool argument can choose a scope.

- SQLite binds the file to the first real identity: it adopts the pre-scoping
  rows in one scoped UPDATE (rowids, revisions, timestamps and FTS rows
  untouched), records that in `store_binding`, and refuses a *different*
  identity on an already-bound file. A store that boots with no identity
  writes no binding at all, so a later real identity can still bind (a
  provisional legacy binding would lock out the harness).
- TiDB registers the identity and **never** adopts `''` rows: on a shared
  dataset those may be another instance's pre-scoping history. Adoption there
  stays an explicit admin operation.
- The boot log states which owner is being served, and whether it is the
  legacy/test owner. There is no caller-supplied scope argument or implicit fallback.
TiDB DDL still needs live DSN validation. Ownership rollback refuses scoped data
rather than merge conflicting keys; TiDB down migration deliberately refuses.

## Binding and legacy adoption (design for the next slice)

Binding an owner is the step that makes scoping active, and it is where local
history could appear to vanish. The two engines need different rules because
their sharing models differ:

- **SQLite (single-writer local file).** The file *is* that instance's data, so
  before serving traffic the store resolves its identity (`NIF_INSTANCE_ID`,
  else `$NIF_ROOT/var/instance-id`) and, exactly once, adopts legacy `''` rows
  for its own identity — a scoped `UPDATE ... WHERE instance_id = ''`, so
  history, revisions, rowids and FTS rows stay valid. The adoption is recorded
  in the database itself, so a restart cannot re-adopt rows another process
  created under `''`, and an already-bound database refuses a different
  identity instead of silently swapping the view.
- **TiDB (network-shared dataset).** No implicit adoption, ever: there the
  empty owner may legitimately mean "another instance's pre-scoping rows". The
  engine refuses to boot without an explicit identity, and adopting legacy rows
  is an explicit, reported admin operation (`store_claim {from, to, dryRun}`),
  never a side effect of the first client to connect.
- **Tests and direct bus callers** keep working: a store started with no
  identity source stays on the legacy owner, so the existing contract suite is
  unchanged. That is a test/development path, not a shared deployment mode.
- `NIF_INSTANCE_ID` becomes a real (still small) bootstrap variable, so a root
  that is recreated — container rebuild, ephemeral CI checkout — keeps its
  identity instead of orphaning its rows.

Binding must be visible: `selftest` and the registry should report the bound
owner, so "which dataset am I actually looking at" is answerable without
guessing.

## Next slices

1. Core registration is implemented; its contract test compares metadata with
   the catalog and var/instance-id. Restart refresh and store-restart recovery
   can extend this baseline without implying a continuous heartbeat.
2. Document instance dimension: same semantics for SQLite and TiDB; own-instance
   default for every operation, including search, selftest and CAS. Bind each
   store process to a stable identity before it accepts calls. No implicit
   cross-instance reads or shared fallback.
3. Legacy ownership: existing local SQLite history must remain accessible;
   shared TiDB legacy rows need an explicit claim plan, not first-writer wins.
   Migration must detect conflicting identities rather than silently adopt.
4. Isolation contracts: duplicate kind/id across two instances, independent
   revisions, pagination, scoped search, boot restore/recover and scheduling.
5. Fleet records: controller-scoped route/receipt documents referencing stable
   target instance IDs. The instances table does not itself grant remote access.
   Keep live identity verification and immutable submitted-job receipt snapshots.
   Local JSON becomes import/export only; first-connection bootstrap remains
   explicit. Matching TUI changes live in its own repository.

Shared configuration inheritance, arbitrary cross-instance admin queries,
roaming conversation ownership and registry retirement are not prerequisites
for own-instance isolation and must not be smuggled into that implementation.

## Validation

- SQLite migration test constructs the pre-registry schema, inserts a verbatim
  document at revision 7, upgrades and reapplies migrations, and checks document
  preservation plus two distinct IDs with the same label/root.
- TiDB registry migration test runs only with an explicit test DSN; without one
  it skips. A passing SQLite gate is not live TiDB DDL certification.
- Run `make gotest`, narrow `make test-store`, then full `make test` before merge.
  No production DSN, database migration or fleet provisioning is authorized by
  these tests.
