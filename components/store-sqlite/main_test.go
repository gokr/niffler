// Unit tests for the store-sqlite engine: schema migration, put/get/list/del
// semantics, optimistic concurrency, LIKE-escaping and raw-JSON fidelity —
// handlers exercised directly against a temp database, no bus involved.
// The full bus contract (identical envelope shapes) is t_store, which runs
// against both engines: make test-store (barrel) + make test-store-sqlite.
package main

import (
	"bytes"
	"encoding/json"
	"testing"

	sdk "niffler.dev/sdk"
)

func newTestDB(t *testing.T) *storeDB {
	t.Helper()
	t.Setenv("NIF_ROOT", t.TempDir())
	db, err := openStore()
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func call(t *testing.T, h sdk.ToolHandler, args string) map[string]any {
	t.Helper()
	out, err := h(nil, json.RawMessage(args))
	if err != nil {
		t.Fatalf("handler error: %v", err)
	}
	m, ok := out.(map[string]any)
	if !ok {
		t.Fatalf("handler returned %T, want map[string]any", out)
	}
	return m
}

func mustOK(t *testing.T, m map[string]any) map[string]any {
	t.Helper()
	if m["ok"] != true {
		t.Fatalf("expected ok, got: %v", m)
	}
	return m
}

func mustFail(t *testing.T, m map[string]any, code string) map[string]any {
	t.Helper()
	if m["ok"] != false {
		t.Fatalf("expected failure, got: %v", m)
	}
	if m["code"] != code {
		t.Fatalf("expected code %q, got: %v", code, m)
	}
	return m
}

func TestMigrateIdempotent(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NIF_ROOT", root)
	db, err := openStore()
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	mustOK(t, call(t, putHandler(db.DB), `{"kind":"k","id":"i","value":{"x":1}}`))
	mustOK(t, call(t, getHandler(db.DB), `{"kind":"k","id":"i"}`))
	_ = db.Close() // releases the flock with the handle
	// Reopen the same file: goose Up is a no-op, data survives.
	db, err = openStore()
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db.Close()
	got := mustOK(t, call(t, getHandler(db.DB), `{"kind":"k","id":"i"}`))
	if got["rev"].(int64) != 1 {
		t.Fatalf("rev after reopen = %v, want 1", got["rev"])
	}
}

func TestSecondWriterRefused(t *testing.T) {
	t.Setenv("NIF_ROOT", t.TempDir())
	db, err := openStore()
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	defer db.Close()
	if _, err := openStore(); err == nil {
		t.Fatal("second openStore on the same file must refuse (flock)")
	}
	// The lock is bound to the handle: after Close a new writer may take over.
	_ = db.Close()
	second, err := openStore()
	if err != nil {
		t.Fatalf("open after first closed: %v", err)
	}
	_ = second.Close()
}

func TestPutGetRoundTrip(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	p1 := mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"hello":"world"}}`))
	if p1["rev"].(int64) != 1 {
		t.Fatalf("first put rev = %v, want 1", p1["rev"])
	}
	g1 := mustOK(t, call(t, getHandler(db.DB), `{"kind":"test","id":"doc1"}`))
	val, _ := json.Marshal(g1["value"])
	if string(val) != `{"hello":"world"}` {
		t.Fatalf("value = %s", val)
	}
	// Rev bumps on plain update (upsert path).
	p2 := mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"hello":"v2"}}`))
	if p2["rev"].(int64) != 2 {
		t.Fatalf("second put rev = %v, want 2", p2["rev"])
	}
}

func TestOptimisticConcurrency(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"n":1}}`))
	mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"n":2},"expectRev":1}`))
	// Stale expectRev → conflict with the current revision surfaced.
	c := mustFail(t, call(t, put, `{"kind":"test","id":"doc1","value":{"n":3},"expectRev":1}`), "rev-conflict")
	if c["currentRev"].(int64) != 2 {
		t.Fatalf("currentRev = %v, want 2", c["currentRev"])
	}
	// expectRev on a missing doc → "not found" variant of rev-conflict.
	mustFail(t, call(t, put, `{"kind":"test","id":"ghost","value":{},"expectRev":3}`), "rev-conflict")
}

func TestListOrderPrefixLimit(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	for _, id := range []string{"doc2", "doc1", "doc10"} {
		mustOK(t, call(t, put, `{"kind":"test","id":"`+id+`","value":{}}`))
	}
	mustOK(t, call(t, put, `{"kind":"other","id":"zzz","value":{}}`))

	all := mustOK(t, call(t, listHandler(db.DB), `{"kind":"test"}`))
	items := all["items"].([]map[string]any)
	if len(items) != 3 {
		t.Fatalf("items = %d, want 3", len(items))
	}
	wantOrder := []string{"doc1", "doc10", "doc2"} // id-ordered (lexicographic)
	for i, w := range wantOrder {
		if items[i]["id"] != w {
			t.Fatalf("items[%d].id = %v, want %s", i, items[i]["id"], w)
		}
	}
	pref := mustOK(t, call(t, listHandler(db.DB), `{"kind":"test","idPrefix":"doc1"}`))
	if len(pref["items"].([]map[string]any)) != 2 {
		t.Fatalf("prefix filter broken: %v", pref["items"])
	}
	lim := mustOK(t, call(t, listHandler(db.DB), `{"kind":"test","limit":1}`))
	if len(lim["items"].([]map[string]any)) != 1 {
		t.Fatalf("limit broken: %v", lim["items"])
	}
	empty := mustOK(t, call(t, listHandler(db.DB), `{"kind":"nope"}`))
	if empty["items"].([]map[string]any) == nil {
		t.Fatal("empty list must marshal as [], not null")
	}
}

func TestDelTombstone(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"n":1}}`))
	mustOK(t, call(t, delHandler(db.DB), `{"kind":"test","id":"doc1"}`))
	// del is idempotent; a missing row still succeeds.
	mustOK(t, call(t, delHandler(db.DB), `{"kind":"test","id":"doc1"}`))
	mustFail(t, call(t, getHandler(db.DB), `{"kind":"test","id":"doc1"}`), "not-found")
	items := mustOK(t, call(t, listHandler(db.DB), `{"kind":"test"}`))["items"].([]map[string]any)
	if len(items) != 0 {
		t.Fatalf("list shows deleted doc: %v", items)
	}
	// A re-put after del restarts at rev 1 (rev counter deleted with the doc).
	p := mustOK(t, call(t, put, `{"kind":"test","id":"doc1","value":{"n":2}}`))
	if p["rev"].(int64) != 1 {
		t.Fatalf("rev after re-put = %v, want 1", p["rev"])
	}
}

func TestGetMissing(t *testing.T) {
	db := newTestDB(t)
	mustFail(t, call(t, getHandler(db.DB), `{"kind":"nope","id":"x"}`), "not-found")
}

func TestSessionScopedPut(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	// Sessions may only curate fabricprog; harness kinds are rejected.
	mustFail(t, call(t, put,
		`{"kind":"message","id":"c1:1","value":{},"__session":{"session":"s1"}}`), "forbidden-kind")
	// The curated kind passes from a session...
	mustOK(t, call(t, put,
		`{"kind":"fabricprog","id":"greet","value":{"code":"echo hi"},"__session":{"session":"s1"}}`))
	// ...and direct bus callers (no __session) keep full access.
	mustOK(t, call(t, put, `{"kind":"message","id":"c1:1","value":{}}`))
}

func TestLikeEscaping(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	mustOK(t, call(t, put, `{"kind":"odd","id":"a%b","value":{}}`))
	mustOK(t, call(t, put, `{"kind":"odd","id":"a_b","value":{}}`))
	mustOK(t, call(t, put, `{"kind":"odd","id":"aXb","value":{}}`))
	// A literal % prefix must not become a wildcard: only a%b matches.
	got := mustOK(t, call(t, listHandler(db.DB), `{"kind":"odd","idPrefix":"a%"}`))
	items := got["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"] != "a%b" {
		t.Fatalf("LIKE escaping broken: %v", items)
	}
	// Same for underscore (matches exactly one char in LIKE).
	got = mustOK(t, call(t, listHandler(db.DB), `{"kind":"odd","idPrefix":"a_"}`))
	items = got["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"] != "a_b" {
		t.Fatalf("underscore escaping broken: %v", items)
	}
}

func TestRawJSONFidelity(t *testing.T) {
	// Values are stored and returned verbatim: number formatting, key order
	// and unicode escapes survive the round trip (the barrel engine
	// re-serializes through its JSON lib; this engine keeps raw bytes).
	db := newTestDB(t)
	raw := `{"b":1.500,"a":2,"note":"é","big":12345678901234567890}`
	mustOK(t, call(t, putHandler(db.DB), `{"kind":"raw","id":"r1","value":`+raw+`}`))
	got := mustOK(t, call(t, getHandler(db.DB), `{"kind":"raw","id":"r1"}`))
	value, _ := got["value"].(json.RawMessage)
	if !bytes.Equal(value, json.RawMessage(raw)) {
		t.Fatalf("value not verbatim:\n got %s\nwant %s", value, raw)
	}
}

func TestJSON1ExpressionQuery(t *testing.T) {
	// The doc-db observation, proven: the JSON stays opaque to the contract,
	// but SQL can still reach inside when a question earns it (JSON1).
	db := newTestDB(t)
	mustOK(t, call(t, putHandler(db.DB),
		`{"kind":"msg","id":"c1:1","value":{"role":"user","content":"hi"}}`))
	mustOK(t, call(t, putHandler(db.DB),
		`{"kind":"msg","id":"c1:2","value":{"role":"assistant","content":"hello"}}`))
	var n int
	if err := db.QueryRow(
		`SELECT count(*) FROM docs WHERE kind = 'msg' AND json_extract(value, '$.role') = 'user'`,
	).Scan(&n); err != nil {
		t.Fatalf("json_extract: %v", err)
	}
	if n != 1 {
		t.Fatalf("json_extract matched %d rows, want 1", n)
	}
}
