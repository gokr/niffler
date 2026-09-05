-- +goose Up
-- Store docs: schema-free JSON documents with a per-(kind, id) revision
-- counter for optimistic concurrency (docs/research/STORE_V2.md).
--
-- `value` is opaque JSON TEXT — the store is deliberately schema-free and
-- stays that way: kinds and their shapes belong to consumers, not to the
-- engine. When a JSON field eventually earns an index, promote it to a real
-- column in a new goose migration (or add a JSON1 expression index) — never
-- by editing an applied migration.
--
-- No extra index beyond the primary key: the (kind, id) PK autoindex already
-- serves the only query surface, `WHERE kind = ? AND id LIKE 'prefix%'
-- ORDER BY id` (seek to kind, scan in id order).
CREATE TABLE docs (
  kind       TEXT        NOT NULL,
  id         TEXT        NOT NULL,
  rev        INTEGER     NOT NULL DEFAULT 0,
  value      TEXT        NOT NULL,  -- JSON document, stored verbatim
  updated_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, id)
);

-- +goose Down
DROP TABLE docs;
