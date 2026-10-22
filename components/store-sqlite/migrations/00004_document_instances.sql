-- +goose Up
-- Preserve rowids: docs_fts uses them as the derived index identity.
CREATE TABLE docs_scoped (
  instance_id TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  rev INTEGER NOT NULL DEFAULT 0,
  value TEXT NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (instance_id, kind, id)
);
INSERT INTO docs_scoped(rowid, kind, id, rev, value, updated_at)
  SELECT rowid, kind, id, rev, value, updated_at FROM docs;
DROP TABLE docs;
ALTER TABLE docs_scoped RENAME TO docs;

-- +goose Down
-- Refuse a lossy rollback once scoped documents exist.
CREATE TABLE scope_rollback_guard (n INTEGER CHECK(n=0));
INSERT INTO scope_rollback_guard SELECT count(*) FROM docs WHERE instance_id <> '';
DROP TABLE scope_rollback_guard;
CREATE TABLE docs_legacy (
  kind TEXT NOT NULL, id TEXT NOT NULL, rev INTEGER NOT NULL DEFAULT 0,
  value TEXT NOT NULL, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(kind,id)
);
INSERT INTO docs_legacy(rowid,kind,id,rev,value,updated_at)
  SELECT rowid,kind,id,rev,value,updated_at FROM docs;
DROP TABLE docs;
ALTER TABLE docs_legacy RENAME TO docs;
