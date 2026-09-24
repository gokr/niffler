-- +goose Up
-- Server-side search (the store contract's `search` tool — docs/WIRE.md
-- "Store contract", issue #77): a standalone FTS5 table over the indexed
-- text of every document.
--
-- Rowids are the SAME rowids as `docs`, so:
--   - a document write and its index write move in one transaction (put/del
--     maintain both), and
--   - the table is pure derived state: dropping it loses nothing, and a
--     rebuild re-derives it from `docs` (the authority) — openStore does
--     exactly that whenever the two disagree.
--
-- `kind` is UNINDEXED: it narrows the post-MATCH scan so a search of one
-- kind never sees another kind's rows. `text` holds the per-kind indexed
-- fields (conversation: id + title; message: id + content strings; other
-- kinds: id only — see searchSchema in search.go).
CREATE VIRTUAL TABLE docs_fts USING fts5(
  kind UNINDEXED,
  text,
  tokenize = 'unicode61'
);

-- +goose Down
DROP TABLE docs_fts;
