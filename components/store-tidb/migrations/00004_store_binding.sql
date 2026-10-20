-- +goose Up
-- One binding row per declared instance of a shared dataset. TiDB never
-- adopts legacy rows implicitly: rows under '' stay unclaimed until an
-- explicit admin claim, so the first client to connect cannot absorb them.
CREATE TABLE store_binding (
  instance_id VARCHAR(32) NOT NULL PRIMARY KEY,
  adopted     BIGINT NOT NULL DEFAULT 0,
  bound_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- +goose Down
DROP TABLE store_binding;
