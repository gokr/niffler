-- +goose Up
-- Store docs: schema-free JSON documents with a per-(kind, id) revision
-- counter for optimistic concurrency (docs/research/STORE_V2.md, M4).
-- Same shape as the sqlite engine's docs table; see the component header
-- for why `value` is MEDIUMTEXT and not a native JSON column.
--
-- utf8mb4_bin on kind/id is REQUIRED by the contract, not a style choice:
-- binary collation gives byte-exact equality, byte-order list sorting
-- (ORDER BY id must match the barrel/sqlite engines) and case-sensitive
-- LIKE prefixes. The default CI collations would break all three.
--
-- No procedures/triggers/functions: TiDB keeps to tables + indexes
-- (MySQL-compatible DDL; this file also loads on plain MySQL 8).
CREATE TABLE docs (
  kind       VARCHAR(255)  NOT NULL,
  id         VARCHAR(255)  NOT NULL,
  rev        BIGINT        NOT NULL DEFAULT 0,
  value      MEDIUMTEXT    NOT NULL,  -- JSON document, stored verbatim
  updated_at DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (kind, id)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- +goose Down
DROP TABLE docs;
