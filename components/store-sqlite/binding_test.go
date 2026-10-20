package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const bindA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const bindB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

// A fresh root with an identity file: what core writes before spawning us.
func newBoundRoot(t *testing.T, identity string) string {
	t.Helper()
	root := t.TempDir()
	if identity != "" {
		if err := os.MkdirAll(filepath.Join(root, "var"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "var", "instance-id"), []byte(identity+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("NIF_ROOT", root)
	t.Setenv("NIF_INSTANCE_ID", "")
	return root
}

func TestBindingAdoptsLegacyOnceAndRefusesAnotherIdentity(t *testing.T) {
	root := newBoundRoot(t, "")
	legacy, err := openStore() // unbound first boot: the legacy owner
	if err != nil {
		t.Fatal(err)
	}
	if legacy.owner != "" {
		t.Fatalf("unidentified store bound to %q", legacy.owner)
	}
	if _, err := legacy.Exec(`INSERT INTO docs(kind,id,rev,value) VALUES ('conversation','old',3,'{"title":"before scoping"}')`); err != nil {
		t.Fatal(err)
	}
	if _, err := syncSearchIndex(legacy.DB); err != nil {
		t.Fatal(err)
	}
	_ = legacy.Close()

	// The identity file appears (core writes it before spawning components).
	if err := os.WriteFile(filepath.Join(root, "var", "instance-id"), []byte(bindA+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	db, err := openStore()
	if err != nil {
		t.Fatal(err)
	}
	if db.owner != bindA {
		t.Fatalf("owner = %q, want %q", db.owner, bindA)
	}
	var adopted int
	if err := db.QueryRow(`SELECT adopted FROM store_binding WHERE singleton=1`).Scan(&adopted); err != nil || adopted != 1 {
		t.Fatalf("adopted = %d (%v)", adopted, err)
	}
	got := mustOK(t, call(t, getHandler(db.DB, db.owner), `{"kind":"conversation","id":"old"}`))
	if got["rev"].(int64) != 3 {
		t.Fatalf("adoption changed the revision: %v", got)
	}
	found := mustOK(t, call(t, searchHandler(db.DB, db.owner), `{"kind":"conversation","query":"scoping"}`))
	if len(found["items"].([]map[string]any)) != 1 {
		t.Fatalf("adopted history is not searchable: %v", found)
	}
	_ = db.Close()

	// Restart as the same instance: idempotent, nothing re-adopted.
	db, err = openStore()
	if err != nil {
		t.Fatalf("same-identity restart: %v", err)
	}
	if err := db.QueryRow(`SELECT adopted FROM store_binding WHERE singleton=1`).Scan(&adopted); err != nil || adopted != 1 {
		t.Fatalf("restart re-adopted: %d (%v)", adopted, err)
	}
	_ = db.Close()

	// A different identity on the same file refuses instead of swapping views.
	t.Setenv("NIF_INSTANCE_ID", bindB)
	if _, err := openStore(); err == nil || !strings.Contains(err.Error(), bindA) {
		t.Fatalf("foreign identity was not refused: %v", err)
	}
}

func TestUnidentifiedStoreOnBoundFileKeepsBinding(t *testing.T) {
	newBoundRoot(t, bindA)
	db, err := openStore()
	if err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	// No identity available (a test/direct caller): keep serving the bound
	// owner rather than falling back to "" and seeing nothing.
	t.Setenv("NIF_ROOT", t.TempDir())
	t.Setenv("NIF_INSTANCE_ID", bindA)
	db, err = openStore()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if db.owner != bindA {
		t.Fatalf("owner = %q", db.owner)
	}
}
