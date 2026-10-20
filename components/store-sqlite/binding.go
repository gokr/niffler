package main

// bindStoreOwner establishes the one owner this file serves. Because a SQLite
// file is single-writer and belongs to exactly one instance, the first
// identity that opens it takes over the pre-scoping rows ("") exactly once —
// a scoped UPDATE, so rowids (and therefore the derived FTS rows), revisions,
// timestamps and verbatim values are untouched. Anything else would make a
// harness look like it lost its history on upgrade.
//
// Once bound, a different identity refuses: two roots pointing one file at
// each other is a configuration mistake, and silently serving the other
// instance's documents is worse than failing to boot.
import (
	"database/sql"
	"fmt"
)

func bindStoreOwner(db *sql.DB) (string, error) {
	identity := resolveStoreIdentity()
	var bound string
	err := db.QueryRow(`SELECT instance_id FROM store_binding WHERE singleton = 1`).
		Scan(&bound)
	switch err {
	case nil:
		if identity == "" || identity == bound {
			// Same instance (or a deliberately unbound/test process on an
			// already-bound file): keep the binding that exists.
			return bound, nil
		}
		return "", fmt.Errorf("this database is bound to instance %s (var/instance-id %q); "+
			"refusing to serve it as %s — point this root at its own store, or "+
			"set NIF_INSTANCE_ID to the bound identity", bound, identity, identity)
	case sql.ErrNoRows:
		// fall through: first bind
	default:
		return "", fmt.Errorf("read store binding: %w", err)
	}

	if identity == "" {
		// A store that boots without an identity serves the legacy owner for
		// now and writes NO binding: pre-scoping databases have none either,
		// and a provisional ""-binding would lock the file against the real
		// identity that appears on the next boot (core writes var/instance-id
		// before it spawns components).
		return "", nil
	}
	owner := identity
	tx, err := db.Begin()
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()
	adopted, err := adoptLegacyRows(tx, owner)
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(
		`INSERT INTO store_binding(singleton, instance_id, adopted) VALUES (1, ?, ?)`,
		owner, adopted); err != nil {
		return "", fmt.Errorf("bind store: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return "", fmt.Errorf("bind store: %w", err)
	}
	if adopted > 0 {
		fmt.Printf("store-sqlite: adopted %d pre-scoping document(s) into instance %q\n",
			adopted, owner)
	}
	return owner, nil
}

// adoptLegacyRows claims the unowned documents for owner. An unbound store
// ("" owner) has nothing to claim: it IS the legacy owner.
func adoptLegacyRows(tx *sql.Tx, owner string) (int64, error) {
	if owner == "" {
		return 0, nil
	}
	res, err := tx.Exec(`UPDATE docs SET instance_id = ? WHERE instance_id = ''`, owner)
	if err != nil {
		return 0, fmt.Errorf("adopt legacy documents: %w", err)
	}
	return res.RowsAffected()
}
