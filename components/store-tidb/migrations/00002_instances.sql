-- +goose Up
-- Same logical registry as SQLite. Identity validation is also required at
-- the owner tool boundary; TiDB/MySQL CHECK support varies by deployment.
CREATE TABLE instances (
  instance_id VARCHAR(32) NOT NULL PRIMARY KEY,
  name VARCHAR(255) NOT NULL DEFAULT '',
  root TEXT NOT NULL,
  git_hash VARCHAR(64) NOT NULL DEFAULT '',
  first_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- +goose Down
DROP TABLE instances;
