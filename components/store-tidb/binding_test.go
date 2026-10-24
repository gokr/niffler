package main

import "testing"

const bindA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const bindB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

// Live only. TiDB must never adopt the unowned rows: on a shared dataset ""
// may be another instance's pre-scoping history.
func TestBindingNeverAdoptsLegacyRows(t *testing.T) {
	db := newTestDB(t)
	const legacy = "179252000000000000000000000000ff"
	if _, err := db.Exec(`DELETE FROM docs WHERE instance_id='' AND kind='bindingtest'`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM docs WHERE instance_id='' AND kind='bindingtest'`) })
	if _, err := db.Exec(`INSERT INTO docs(instance_id,kind,id,rev,value) VALUES ('','bindingtest','legacy',1,'{"v":1}')`); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NIF_INSTANCE_ID", bindA)
	owner, err := bindStoreOwner(db)
	if err != nil || owner != bindA {
		t.Fatalf("bind: %q %v", owner, err)
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM docs WHERE instance_id='' AND kind='bindingtest'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("legacy rows were adopted: %d (%v)", n, err)
	}
	mustOK(t, call(t, putHandler(db, owner), `{"kind":"bindingtest","id":"mine","value":{"v":2}}`))
	mustFail(t, call(t, getHandler(db, owner), `{"kind":"bindingtest","id":"legacy"}`), "not-found")
	if _, err := db.Exec(`DELETE FROM docs WHERE instance_id=? AND kind='bindingtest'`, bindA); err != nil {
		t.Fatal(err)
	}
	// A second, different instance coexists on the same dataset.
	if _, err := db.Exec(`INSERT INTO store_binding(instance_id) VALUES (?)
		ON DUPLICATE KEY UPDATE instance_id=VALUES(instance_id)`, bindB); err != nil {
		t.Fatal(err)
	}
	mustOK(t, call(t, putHandler(db, bindB), `{"kind":"bindingtest","id":"mine","value":{"v":3}}`))
	// Same kind and id in two instances: each reads its own value, and the
	// second instance's write did not resurrect the first's deleted row —
	// that is the isolation this test exists for. (Reading A's copy back as a
	// success would be the leak, not the assertion.)
	mustFail(t, call(t, getHandler(db, owner), `{"kind":"bindingtest","id":"mine"}`), "not-found")
	mustOK(t, call(t, getHandler(db, bindB), `{"kind":"bindingtest","id":"mine"}`))
	for _, id := range []string{bindA, bindB} {
		if _, err := db.Exec(`DELETE FROM docs WHERE instance_id=? AND kind='bindingtest'`, id); err != nil {
			t.Fatal(err)
		}
	}
}
