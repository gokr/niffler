-- +goose Up
-- Stable identity registry for instances sharing a dataset. Document values
-- remain opaque JSON; document ownership is a subsequent migration.
-- Identity is the existing 128-bit lowercase hex var/instance-id, not a name
-- or filesystem root. Metadata is informational, never routing authority.
CREATE TABLE instances (
  instance_id TEXT NOT NULL PRIMARY KEY
    CHECK (length(instance_id) = 32 AND instance_id NOT GLOB '*[^0-9a-f]*'),
  name TEXT NOT NULL DEFAULT '',
  root TEXT NOT NULL DEFAULT '',
  git_hash TEXT NOT NULL DEFAULT '',
  first_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- +goose Down
DROP TABLE instances;
