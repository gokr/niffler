package main

// TiDB is a shared dataset: several instances legitimately write one table.
// Binding therefore registers THIS process's identity and never adopts the
// unowned ("") rows — those may be another instance's pre-scoping history, so
// claiming them for whoever connected first would hand one tenant another's
// conversations. Adoption is a separate, explicit admin operation.
//
// An empty identity is allowed here only as the single-instance/test path; a
// real shared deployment sets NIF_INSTANCE_ID, and the boot log says which
// owner is being served.
import (
	"database/sql"
	"fmt"
)

func bindStoreOwner(db *sql.DB) (string, error) {
	owner := resolveStoreIdentity()
	if owner == "" {
		return "", nil
	}
	if _, err := db.Exec(`INSERT INTO store_binding(instance_id) VALUES (?)
		ON DUPLICATE KEY UPDATE instance_id = VALUES(instance_id)`, owner); err != nil {
		return "", fmt.Errorf("bind store: %w", err)
	}
	return owner, nil
}
