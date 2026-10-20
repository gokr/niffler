-- +goose Up
-- Exactly one bound owner per SQLite file. The file IS one instance's data,
-- so the first identity that opens it adopts the pre-scoping rows once; a
-- later process with a different identity is refused instead of silently
-- viewing (or adopting) another instance's history.
CREATE TABLE store_binding (
  singleton   INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
  -- '' is the explicit legacy owner (a store that booted with no identity);
  -- anything else must be a real 128-bit instance identity.
  instance_id TEXT    NOT NULL DEFAULT ''
    CHECK (instance_id = '' OR
           (length(instance_id) = 32 AND instance_id NOT GLOB '*[^0-9a-f]*')),
  adopted     INTEGER NOT NULL DEFAULT 0,  -- legacy rows claimed by this bind
  bound_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- +goose Down
DROP TABLE store_binding;
