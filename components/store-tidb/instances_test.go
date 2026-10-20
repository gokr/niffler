package main

import "testing"

// Live only: compile/unit success without NIF_STORE_TIDB_DSN is not evidence
// that a deployed TiDB accepts this DDL. newTestDB reports an explicit skip.
func TestInstancesRegistryMigration(t *testing.T) {
	db := newTestDB(t)
	ids := []string{"17925200000000000000000000000001", "17925200000000000000000000000002"}
	for _, id := range ids {
		// Fixed fixtures are removed before and after, matching existing live tests.
		if _, err := db.Exec(`DELETE FROM instances WHERE instance_id=?`, id); err != nil {
			t.Fatal(err)
		}
		id := id
		t.Cleanup(func() {
			if _, err := db.Exec(`DELETE FROM instances WHERE instance_id=?`, id); err != nil {
				t.Error(err)
			}
		})
		if _, err := db.Exec(`INSERT INTO instances(instance_id,name,root) VALUES (?, 'same label', '/same/root')`, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := migrate(db); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM instances WHERE instance_id IN (?,?)`, ids[0], ids[1]).Scan(&count); err != nil || count != 2 {
		t.Fatalf("registry after reapply: %d %v", count, err)
	}
}
