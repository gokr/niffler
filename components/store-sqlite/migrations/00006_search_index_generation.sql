-- +goose Up
-- Search-index generation marker. `docs_fts` is derived state, so changing
-- what gets indexed does NOT need a schema change — but it does need the
-- existing rows to be re-derived: put/del only maintain the document being
-- written, and syncSearchIndex's cheap check (count + max(rowid)) cannot see
-- that the indexed TEXT of unchanged documents is now stale.
--
-- Without this, widening `indexedText` (tool-call arguments, reasoning on both
-- engines, per-part budgets) would only take effect for documents written
-- after the upgrade — which is the opposite of the store's authority rule: the
-- documents are the authority, the index is derived and must be rebuildable
-- from them at any time.
--
-- The app compares `index_generation` with its compiled-in constant and drops
-- `docs_fts` when they differ, then re-derives it from `docs`.
CREATE TABLE search_index_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  generation INTEGER NOT NULL
);

-- +goose Down
DROP TABLE search_index_meta;
