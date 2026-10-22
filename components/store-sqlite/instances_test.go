package main

import (
	"context"
	"database/sql"
	"io/fs"
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
)

// Exercise the migration against an actual pre-registry database, not merely
// an empty database. No user history, revisions or search results may change.
func TestInstancesMigrationPreservesDocuments(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NIF_ROOT", root)
	// Create a legacy database explicitly so UpTo exercises the old schema.
	legacy, err := sql.Open("sqlite3", filepath.Join(root, "legacy.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer legacy.Close()
	dir, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		t.Fatal(err)
	}
	provider, err := goose.NewProvider(goose.DialectSQLite3, legacy, dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = provider.UpTo(context.Background(), 2); err != nil {
		t.Fatal(err)
	}
	raw := `{"title":"history preserved", "n":1.500}`
	if _, err = legacy.Exec(`INSERT INTO docs(kind,id,rev,value) VALUES ('conversation','same',7,?)`, raw); err != nil {
		t.Fatal(err)
	}
	if _, err = legacy.Exec(`UPDATE docs SET rowid=73 WHERE id='same'`); err != nil {
		t.Fatal(err)
	}
	if _, err = syncSearchIndex(legacy); err != nil {
		t.Fatal(err)
	}
	if _, err = provider.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	var owner string
	var rowid int
	if err = legacy.QueryRow(`SELECT instance_id,rowid FROM docs WHERE id='same'`).Scan(&owner, &rowid); err != nil || owner != "" || rowid != 73 {
		t.Fatalf("ownership/rowid migration: %q %d %v", owner, rowid, err)
	}
	found := mustOK(t, call(t, searchHandler(legacy), `{"kind":"conversation","query":"history"}`))
	if len(found["items"].([]map[string]any)) != 1 {
		t.Fatalf("migration lost indexed history: %v", found)
	}
	var value string
	var rev int
	if err = legacy.QueryRow(`SELECT value,rev FROM docs WHERE kind='conversation' AND id='same'`).Scan(&value, &rev); err != nil {
		t.Fatal(err)
	}
	if value != raw || rev != 7 {
		t.Fatalf("history changed: %q rev %d", value, rev)
	}
	for _, id := range []string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"} {
		if _, err = legacy.Exec(`INSERT INTO instances(instance_id,name,root) VALUES (?, 'same label', '/same/root')`, id); err != nil {
			t.Fatal(err)
		}
	}
	var count int
	if err = legacy.QueryRow(`SELECT COUNT(*) FROM instances`).Scan(&count); err != nil || count != 2 {
		t.Fatalf("instances=%d error=%v", count, err)
	}
	if _, err = legacy.Exec(`INSERT INTO instances(instance_id) VALUES ('invalid')`); err == nil {
		t.Fatal("invalid instance identity accepted")
	}
	if _, err = provider.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err = legacy.QueryRow(`SELECT COUNT(*) FROM instances`).Scan(&count); err != nil || count != 2 {
		t.Fatalf("reapply changed registry: %d %v", count, err)
	}
}
