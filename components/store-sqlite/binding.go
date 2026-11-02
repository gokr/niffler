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
	"os"
	"strings"
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
		//
		// REFUSE, though, when this file already holds documents owned by a
		// real instance. Serving "" then answers every lookup `not-found` for
		// rows that are sitting right there: the UI shows no providers, no
		// conversations, no history — silently, hours after the fact, and only
		// a restart that re-establishes an identity appears to "fix" it. A
		// loud refusal at boot turns that into a one-line diagnosis. A truly
		// unbound database (a fresh dev root, a test file) has no owned rows,
		// so this cannot fire for it.
		owned, err := instanceIDsWithRows(db)
		if err != nil {
			return "", fmt.Errorf("check for existing owners: %w", err)
		}
		if len(owned) > 0 {
			return "", fmt.Errorf("this database holds documents owned by instance %s, "+
				"but no instance identity was found (NIF_INSTANCE_ID or %s/var/instance-id) — "+
				"refusing to serve it as the unbound legacy owner, which would report every "+
				"one of those documents as not found. Restore var/instance-id, set "+
				"NIF_INSTANCE_ID to that identity, or point this root at its own store",
				strings.Join(owned, ", "), storeRoot())
		}
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

// storeRoot mirrors the root resolveStoreIdentity reads the identity from, so a
// refusal tells the operator where to look.
func storeRoot() string {
	if root := strings.TrimSpace(os.Getenv("NIF_ROOT")); root != "" {
		return root
	}
	return "."
}

// instanceIDsWithRows lists the distinct non-empty owners present in `docs`.
// Used only on the unbound path: it is the difference between "this file has no
// owner yet" (fine, serve legacy) and "this file belongs to somebody, and I
// just failed to learn who" (refuse — see bindStoreOwner).
func instanceIDsWithRows(db *sql.DB) ([]string, error) {
	rows, err := db.Query(
		`SELECT DISTINCT instance_id FROM docs WHERE instance_id <> '' LIMIT 8`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
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
