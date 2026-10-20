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
- `first_seen`, `last_seen`: database timestamps. Registry operations in a later
  slice must preserve first_seen on refresh and validate identity at the tool
  boundary for both engines (do not rely on TiDB CHECK support).

No periodic writes, new env variables, registry tools, retirement/deletion,
core boot registration, document foreign keys or shared fallback are introduced
by this schema slice. These need the next contract and tests.

## Next slices

1. Registry owner API and core registration: separate read and mutation tool
   schemas, explicit validation, bounded pagination and per-operation approvals.
   A mixed op tool cannot declare different static effects for each operation.
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
