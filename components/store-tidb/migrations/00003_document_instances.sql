-- +goose Up
-- Empty owner preserves legacy rows without assigning them to the first
-- connecting instance. Adoption/binding is a separate explicit operation.
ALTER TABLE docs ADD COLUMN instance_id VARCHAR(32) NOT NULL DEFAULT '';
ALTER TABLE docs DROP PRIMARY KEY, ADD PRIMARY KEY(instance_id,kind,id);

-- +goose Down
-- Destructive ownership rollback is deliberately unsupported on TiDB: DDL
-- is not transactional and merging distinct instance IDs could lose data.
-- +goose StatementBegin
SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'instance ownership rollback requires explicit export and migration';
-- +goose StatementEnd
