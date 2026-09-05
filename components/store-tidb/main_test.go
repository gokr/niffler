// Unit tests for the store-tidb engine. They run against a live TiDB/MySQL
// server pointed at by NIF_STORE_TIDB_DSN (e.g.
// root@tcp(127.0.0.1:4000)/test — TiDB single-node via docker:
// `docker run -p 4000:4000 pingcap/tidb:v8.5.0`). Without a DSN every
// database test skips, so `go test ./...` stays green everywhere.
//
// The full bus contract (identical envelope shapes) is t_store, which runs
// against all engines: make test-store / test-store-sqlite / test-store-tidb.
package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"os"
	"testing"

	sdk "niffler.dev/sdk"
)

func newTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("NIF_STORE_TIDB_DSN")
	if dsn == "" {
		t.Skip("NIF_STORE_TIDB_DSN not set — skipping live TiDB/MySQL tests")
	}
	t.Setenv(dsnEnv, dsn)
	db, err := openStore()
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestMissingDSNRefused(t *testing.T) {
	t.Setenv(dsnEnv, "")
	if _, err := openStore(); err == nil {
		t.Fatal("openStore without a DSN must refuse to boot")
	}
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

func TestPutGetRoundTrip(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	p1 := mustOK(t, call(t, put, `{"kind":"tidbtest","id":"doc1","value":{"hello":"world"}}`))
	if p1["rev"].(int64) != 1 {
		t.Fatalf("first put rev = %v, want 1", p1["rev"])
	}
	g1 := mustOK(t, call(t, getHandler(db), `{"kind":"tidbtest","id":"doc1"}`))
	val, _ := json.Marshal(g1["value"])
	if string(val) != `{"hello":"world"}` {
		t.Fatalf("value = %s", val)
	}
	// Rev bumps on plain update (upsert path).
	p2 := mustOK(t, call(t, put, `{"kind":"tidbtest","id":"doc1","value":{"hello":"v2"}}`))
	if p2["rev"].(int64) != 2 {
		t.Fatalf("second put rev = %v, want 2", p2["rev"])
	}
}

func TestOptimisticConcurrency(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	mustOK(t, call(t, put, `{"kind":"tidbtest","id":"cas","value":{"n":1}}`))
	mustOK(t, call(t, put, `{"kind":"tidbtest","id":"cas","value":{"n":2},"expectRev":1}`))
	// Stale expectRev → conflict with the current revision surfaced.
	c := mustFail(t, call(t, put, `{"kind":"tidbtest","id":"cas","value":{"n":3},"expectRev":1}`), "rev-conflict")
	if c["currentRev"].(int64) != 2 {
		t.Fatalf("currentRev = %v, want 2", c["currentRev"])
	}
	// expectRev on a missing doc → "not found" variant of rev-conflict.
	mustFail(t, call(t, put, `{"kind":"tidbtest","id":"ghost","value":{},"expectRev":3}`), "rev-conflict")
	// A same-value CAS update must still count as a conflict (the matched,
	// not changed, rows distinction): rev 2 write with expectRev 1 fails.
	mustFail(t, call(t, put, `{"kind":"tidbtest","id":"cas","value":{"n":2},"expectRev":1}`), "rev-conflict")
}

func TestListOrderPrefixLimit(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	for _, id := range []string{"doc2", "doc1", "doc10"} {
		mustOK(t, call(t, put, `{"kind":"tidblist","id":"`+id+`","value":{}}`))
	}
	t.Cleanup(func() {
		for _, id := range []string{"doc1", "doc2", "doc10", "zzz"} {
			mustOK(t, call(t, delHandler(db), `{"kind":"tidblist","id":"`+id+`"}`))
		}
	})
	mustOK(t, call(t, put, `{"kind":"tidblist","id":"zzz","value":{}}`))

	all := mustOK(t, call(t, listHandler(db), `{"kind":"tidblist"}`))
	items := all["items"].([]map[string]any)
	if len(items) != 4 {
		t.Fatalf("items = %d, want 4", len(items))
	}
	wantOrder := []string{"doc1", "doc10", "doc2", "zzz"} // id-ordered (binary collation)
	for i, w := range wantOrder {
		if items[i]["id"] != w {
			t.Fatalf("items[%d].id = %v, want %s (byte-order collation broken?)", i, items[i]["id"], w)
		}
	}
	pref := mustOK(t, call(t, listHandler(db), `{"kind":"tidblist","idPrefix":"doc1"}`))
	if len(pref["items"].([]map[string]any)) != 2 {
		t.Fatalf("prefix filter broken: %v", pref["items"])
	}
	lim := mustOK(t, call(t, listHandler(db), `{"kind":"tidblist","limit":1}`))
	if len(lim["items"].([]map[string]any)) != 1 {
		t.Fatalf("limit broken: %v", lim["items"])
	}
}

func TestDelTombstone(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	mustOK(t, call(t, put, `{"kind":"tidbdel","id":"doc1","value":{"n":1}}`))
	mustOK(t, call(t, delHandler(db), `{"kind":"tidbdel","id":"doc1"}`))
	// del is idempotent; a missing row still succeeds.
	mustOK(t, call(t, delHandler(db), `{"kind":"tidbdel","id":"doc1"}`))
	mustFail(t, call(t, getHandler(db), `{"kind":"tidbdel","id":"doc1"}`), "not-found")
	// A re-put after del restarts at rev 1 (rev deleted with the doc).
	p := mustOK(t, call(t, put, `{"kind":"tidbdel","id":"doc1","value":{"n":2}}`))
	if p["rev"].(int64) != 1 {
		t.Fatalf("rev after re-put = %v, want 1", p["rev"])
	}
	mustOK(t, call(t, delHandler(db), `{"kind":"tidbdel","id":"doc1"}`))
}

func TestGetMissing(t *testing.T) {
	db := newTestDB(t)
	mustFail(t, call(t, getHandler(db), `{"kind":"tidbnope","id":"x"}`), "not-found")
}

func TestSessionScopedPut(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	// Sessions may only curate fabricprog; harness kinds are rejected.
	mustFail(t, call(t, put,
		`{"kind":"message","id":"tidb:1","value":{},"__session":{"session":"s1"}}`), "forbidden-kind")
	// The curated kind passes from a session...
	mustOK(t, call(t, put,
		`{"kind":"fabricprog","id":"tidb-greet","value":{"code":"echo hi"},"__session":{"session":"s1"}}`))
	mustOK(t, call(t, delHandler(db), `{"kind":"fabricprog","id":"tidb-greet"}`))
	// ...and direct bus callers (no __session) keep full access.
	mustOK(t, call(t, put, `{"kind":"tidbdirect","id":"d1","value":{}}`))
	mustOK(t, call(t, delHandler(db), `{"kind":"tidbdirect","id":"d1"}`))
}

func TestLikeEscaping(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db)
	mustOK(t, call(t, put, `{"kind":"tidbodd","id":"a%b","value":{}}`))
	mustOK(t, call(t, put, `{"kind":"tidbodd","id":"a_b","value":{}}`))
	mustOK(t, call(t, put, `{"kind":"tidbodd","id":"aXb","value":{}}`))
	t.Cleanup(func() {
		for _, id := range []string{"a%b", "a_b", "aXb"} {
			mustOK(t, call(t, delHandler(db), `{"kind":"tidbodd","id":"`+id+`"}`))
		}
	})
	// A literal % prefix must not become a wildcard: only a%b matches.
	got := mustOK(t, call(t, listHandler(db), `{"kind":"tidbodd","idPrefix":"a%"}`))
	items := got["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"] != "a%b" {
		t.Fatalf("LIKE escaping broken: %v", items)
	}
	// Same for underscore (matches exactly one char in LIKE).
	got = mustOK(t, call(t, listHandler(db), `{"kind":"tidbodd","idPrefix":"a_"}`))
	items = got["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"] != "a_b" {
		t.Fatalf("underscore escaping broken: %v", items)
	}
	// Binary collation: case-sensitive prefix matching (contract parity
	// with the other engines' byte-exact semantics).
	mustOK(t, call(t, put, `{"kind":"tidbodd","id":"UPPER","value":{}}`))
	t.Cleanup(func() {
		mustOK(t, call(t, delHandler(db), `{"kind":"tidbodd","id":"UPPER"}`))
	})
	got = mustOK(t, call(t, listHandler(db), `{"kind":"tidbodd","idPrefix":"upper"}`))
	if len(got["items"].([]map[string]any)) != 0 {
		t.Fatalf("prefix must be case-sensitive (utf8mb4_bin): %v", got["items"])
	}
}

func TestRawJSONFidelity(t *testing.T) {
	// Values are stored and returned verbatim: number formatting, key order
	// and unicode escapes survive the round trip (this is WHY the value
	// column is MEDIUMTEXT and not the native JSON type — see the header).
	db := newTestDB(t)
	raw := `{"b":1.500,"a":2,"note":"é","big":12345678901234567890}`
	mustOK(t, call(t, putHandler(db), `{"kind":"tidbraw","id":"r1","value":`+raw+`}`))
	got := mustOK(t, call(t, getHandler(db), `{"kind":"tidbraw","id":"r1"}`))
	value, _ := got["value"].(json.RawMessage)
	if !bytes.Equal(value, json.RawMessage(raw)) {
		t.Fatalf("value not verbatim (JSON type normalization leaked in?):\n got %s\nwant %s", value, raw)
	}
	mustOK(t, call(t, delHandler(db), `{"kind":"tidbraw","id":"r1"}`))
}
