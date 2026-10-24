-- +goose Up
-- Empty owner preserves legacy rows without assigning them to the first
-- connecting instance. Adoption/binding is a separate explicit operation.
--
-- TiDB CANNOT do this with `ALTER TABLE docs DROP PRIMARY KEY, ADD PRIMARY
-- KEY(...)`: since v5.0 every TiDB table has a clustered index, and v8.5
-- refuses (Error 8200, "Unsupported drop primary key when the table is using
-- clustered index"). This file used to say exactly that, so migration 3 never
-- applied on TiDB and the engine could not boot at all.
--
-- A table rebuild is therefore the DDL, and it is written to survive partial
-- application, because TiDB DDL is not transactional: the old two-statement
-- version could leave instance_id added with the primary key unchanged (and it
-- did — the half-applied state is unretryable by the old file). Each step is
-- idempotent so a re-run converges instead of failing.
--
-- The rename is one atomic statement, so there is no window in which `docs`
-- does not exist.
--
-- Adding the column first (idempotently) is what makes the copy safe: the
-- rebuild can then always name instance_id, so a database where the OLD
-- migration had already added the column keeps whatever it holds instead of
-- silently resetting those owners to ''.
ALTER TABLE docs ADD COLUMN IF NOT EXISTS instance_id VARCHAR(32) NOT NULL DEFAULT '';

DROP TABLE IF EXISTS docs_rebuild;
CREATE TABLE docs_rebuild (
  kind        VARCHAR(255) NOT NULL,
  id          VARCHAR(255) NOT NULL,
  rev         BIGINT       NOT NULL DEFAULT 0,
  value       MEDIUMTEXT   NOT NULL,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  instance_id VARCHAR(32)  NOT NULL DEFAULT '',
  PRIMARY KEY (instance_id, kind, id)
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- Column order in an INSERT ... SELECT is explicit, so every column keeps its
-- meaning; legacy rows carry '' and stay unclaimed.
INSERT INTO docs_rebuild(kind, id, rev, value, updated_at, instance_id)
  SELECT kind, id, rev, value, updated_at, instance_id FROM docs;
RENAME TABLE docs TO docs_pre_scope, docs_rebuild TO docs;
DROP TABLE docs_pre_scope;

-- +goose Down
-- Destructive ownership rollback is deliberately unsupported on TiDB: DDL
-- is not transactional and merging distinct instance IDs could lose data.
-- +goose StatementBegin
SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'instance ownership rollback requires explicit export and migration';
-- +goose StatementEnd
