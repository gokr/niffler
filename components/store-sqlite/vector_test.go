// Vector search contract (docs/WIRE.md "Store contract", "Vector search").
//
// The interesting failures here are all silent ones, so each is pinned:
// a vector stored but not indexed (gone forever), a kNN that quietly returns
// fewer than k because the model filter was applied after the search, and a
// wrong-width query that returns an empty page instead of an error.

package main

import (
	"encoding/json"
	"fmt"
	"testing"
)

// putEmbedding is the producer shape: an ordinary document of kind embedding.
func putEmbedding(t *testing.T, db *storeDB, id string, vector []float64, model string) map[string]any {
	t.Helper()
	value, err := json.Marshal(map[string]any{
		"model": model, "vector": vector, "dimensions": len(vector),
		"source": "message", "sourceId": id,
	})
	if err != nil {
		t.Fatal(err)
	}
	out, err := putHandler(db.DB)(nil, json.RawMessage(fmt.Sprintf(
		`{"kind":"embedding","id":%q,"value":%s}`, id, value)))
	if err != nil {
		t.Fatalf("put %s: %v", id, err)
	}
	m, _ := out.(map[string]any)
	return m
}

func searchVector(t *testing.T, db *storeDB, body string) map[string]any {
	t.Helper()
	out, err := searchHandler(db.DB)(nil, json.RawMessage(body))
	if err != nil {
		t.Fatalf("search %s: %v", body, err)
	}
	m, ok := out.(map[string]any)
	if !ok {
		t.Fatalf("search returned %T", out)
	}
	return m
}

func TestVectorSearchNearestFirst(t *testing.T) {
	db := newTestDB(t)
	const model = "hf:nomic-ai/nomic-embed-text-v1.5"

	mustOK(t, putEmbedding(t, db, "cat", []float64{1, 0, 0}, model))
	mustOK(t, putEmbedding(t, db, "dog", []float64{0.9, 0.1, 0}, model))
	mustOK(t, putEmbedding(t, db, "volcano", []float64{0, 1, 0}, model))

	result := searchVector(t, db,
		fmt.Sprintf(`{"kind":"embedding","model":%q,"vector":[1,0,0]}`, model))
	if result["ok"] != true || result["vector"] != true || result["ranked"] != true {
		t.Fatalf("envelope = %#v", result)
	}
	items := result["items"].([]map[string]any)
	if len(items) != 3 {
		t.Fatalf("items = %d, want 3", len(items))
	}
	// Cosine distance: identical = 0, and the order must be by distance.
	if items[0]["id"] != "cat" || items[0]["distance"].(float64) > 0.0001 {
		t.Fatalf("nearest = %#v", items[0])
	}
	if items[1]["id"] != "dog" {
		t.Fatalf("second = %#v", items[1])
	}
	if items[2]["id"] != "volcano" {
		t.Fatalf("farthest = %#v", items[2])
	}

	// limit pages the neighbours, and hasMore tells the caller it truncated.
	page := searchVector(t, db,
		fmt.Sprintf(`{"kind":"embedding","model":%q,"vector":[1,0,0],"limit":1}`, model))
	if len(page["items"].([]map[string]any)) != 1 || page["hasMore"] != true {
		t.Fatalf("limit page = %#v", page)
	}
}

// A model filter must be applied INSIDE the search (a vec0 partition key), not
// after it. Post-filtering would return a short page — the classic kNN bug —
// and mixing models compares different embedding spaces, which is meaningless.
func TestVectorSearchIsolatesModels(t *testing.T) {
	db := newTestDB(t)
	mustOK(t, putEmbedding(t, db, "a", []float64{1, 0, 0}, "model-a"))
	mustOK(t, putEmbedding(t, db, "b", []float64{1, 0, 0}, "model-b"))
	mustOK(t, putEmbedding(t, db, "c", []float64{0.99, 0.01, 0}, "model-b"))

	result := searchVector(t, db,
		`{"kind":"embedding","model":"model-b","vector":[1,0,0],"limit":5}`)
	items := result["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("model filter returned %d items, want 2: %#v", len(items), items)
	}
	for _, item := range items {
		if item["id"] == "a" {
			t.Fatalf("a vector from another model's space leaked in: %#v", items)
		}
	}

	// The same query restricted to a different kind finds nothing, because
	// the kind is part of the partition — not a filter applied afterwards.
	none := searchVector(t, db,
		`{"kind":"message","model":"model-b","vector":[1,0,0]}`)
	if n := len(none["items"].([]map[string]any)); n != 0 {
		t.Fatalf("kind partition leaked %d items", n)
	}
}

// Different models legitimately have different widths; both must coexist, and
// a query in one width must never see the other.
func TestVectorSearchPerDimension(t *testing.T) {
	db := newTestDB(t)
	mustOK(t, putEmbedding(t, db, "small", []float64{1, 0, 0}, "m-3d"))
	mustOK(t, putEmbedding(t, db, "large", []float64{1, 0, 0, 0, 0}, "m-5d"))

	three := searchVector(t, db, `{"kind":"embedding","model":"m-3d","vector":[1,0,0]}`)
	if items := three["items"].([]map[string]any); len(items) != 1 || items[0]["id"] != "small" {
		t.Fatalf("3-dim query = %#v", items)
	}
	five := searchVector(t, db, `{"kind":"embedding","model":"m-5d","vector":[1,0,0,0,0]}`)
	if items := five["items"].([]map[string]any); len(items) != 1 || items[0]["id"] != "large" {
		t.Fatalf("5-dim query = %#v", items)
	}

	// A width no document uses has no index: an empty page, not an error.
	four := searchVector(t, db, `{"kind":"embedding","model":"m-4d","vector":[1,0,0,0]}`)
	if items := four["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("unused width returned %#v", items)
	}
}

// A malformed embedding is refused at WRITE time. Storing it would leave a
// document that no kNN can ever return, with no error to explain the silence.
func TestVectorPutRejectsUnindexableEmbedding(t *testing.T) {
	db := newTestDB(t)
	cases := map[string]string{
		"missing model":    `{"vector":[1,0],"dimensions":2}`,
		"empty vector":     `{"model":"m","vector":[],"dimensions":0}`,
		"width mismatch":   `{"model":"m","vector":[1,0,0],"dimensions":2}`,
		"not an object":    `[1,2,3]`,
		"oversized vector": fmt.Sprintf(`{"model":"m","vector":%s}`, oversized(9000)),
	}
	for name, value := range cases {
		out, err := putHandler(db.DB)(nil, json.RawMessage(fmt.Sprintf(
			`{"kind":"embedding","id":"bad","value":%s}`, value)))
		if err != nil {
			t.Fatalf("%s: handler error %v", name, err)
		}
		m, _ := out.(map[string]any)
		if m["ok"] != false || m["code"] != "bad-embedding" {
			t.Fatalf("%s was accepted: %#v", name, m)
		}
	}
	// Nothing was written, so nothing can be half-indexed.
	out, err := getHandler(db.DB)(nil, json.RawMessage(`{"kind":"embedding","id":"bad"}`))
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := out.(map[string]any); m["ok"] != false {
		t.Fatalf("a refused embedding was stored anyway: %#v", m)
	}
}

func oversized(n int) string {
	out := make([]byte, 0, n*2)
	out = append(out, '[')
	for i := 0; i < n; i++ {
		if i > 0 {
			out = append(out, ',')
		}
		out = append(out, '0')
	}
	return string(append(out, ']'))
}

// Rewriting a document must not leave its old vector behind, and deleting it
// must remove the vector in the same transaction — otherwise a deleted
// document keeps answering kNN queries with a rowid that joins to nothing.
func TestVectorIndexFollowsWrites(t *testing.T) {
	db := newTestDB(t)
	mustOK(t, putEmbedding(t, db, "doc", []float64{1, 0, 0}, "m"))

	// Rewrite with a different width: the old row must not survive in the
	// 3-dim table.
	mustOK(t, putEmbedding(t, db, "doc", []float64{1, 0, 0, 0, 0}, "m"))
	if items := searchVector(t, db,
		`{"kind":"embedding","model":"m","vector":[1,0,0]}`)["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("stale 3-dim vector survived a rewrite: %#v", items)
	}
	if items := searchVector(t, db,
		`{"kind":"embedding","model":"m","vector":[1,0,0,0,0]}`)["items"].([]map[string]any); len(items) != 1 {
		t.Fatalf("rewritten 5-dim vector is not searchable: %#v", items)
	}

	// del removes the vector with the document.
	if _, err := delHandler(db.DB)(nil, json.RawMessage(`{"kind":"embedding","id":"doc"}`)); err != nil {
		t.Fatal(err)
	}
	if items := searchVector(t, db,
		`{"kind":"embedding","model":"m","vector":[1,0,0,0,0]}`)["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("deleted document still answers kNN: %#v", items)
	}
}

// The index is derived: startup re-derives it from the documents whenever the
// two disagree (a crash mid-write, an out-of-band edit).
func TestVectorIndexRebuildsFromDocuments(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NIF_ROOT", root)
	db, err := openStore()
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	mustOK(t, putEmbedding(t, db, "kept", []float64{1, 0, 0}, "m"))
	if _, err := db.Exec(`DELETE FROM docs_vec_3`); err != nil {
		t.Fatalf("simulate index loss: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := openStore()
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	items := searchVector(t, reopened,
		`{"kind":"embedding","model":"m","vector":[1,0,0]}`)["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"] != "kept" {
		t.Fatalf("rebuild did not re-derive the vector index: %#v", items)
	}
}

// The text mode must be untouched by the vector mode's presence.
func TestTextSearchStillWorks(t *testing.T) {
	db := newTestDB(t)
	mustOK(t, call(t, putHandler(db.DB),
		`{"kind":"conversation","id":"conv-1","value":{"title":"vector search notes"}}`))
	mustOK(t, putEmbedding(t, db, "emb", []float64{1, 0, 0}, "m"))
	result := searchVector(t, db, `{"kind":"conversation","query":"vector"}`)
	if result["ranked"] != false {
		t.Fatalf("text mode answered %#v", result)
	}
	if n := len(result["items"].([]map[string]any)); n != 1 {
		t.Fatalf("text search found %d items", n)
	}
}

// idPrefixPartition is the whole scoping rule for the vector index, and it is
// derived rather than stored, so the two shapes it must serve are pinned
// directly. The LAST colon is the load-bearing detail: a memory scope key is a
// filesystem path and contains colons of its own.
func TestIdPrefixPartition(t *testing.T) {
	cases := []struct{ id, want string }{
		// memory: <scope>:<subject>
		{"repo:/home/x/proj:build.jobs", "repo:/home/x/proj:"},
		{"repo:/home/x/proj:deps.package_manager", "repo:/home/x/proj:"},
		// message: <convId>:<seq>
		{"conv-1:000042", "conv-1:"},
		{"conv-1:000043", "conv-1:"},
		// global scope has no path, still one colon
		{"global:conventions", "global:"},
		// no colon: no partition, reachable only by an unscoped query
		{"plain", ""},
	}
	for _, c := range cases {
		if got := idPrefixPartition(c.id); got != c.want {
			t.Errorf("idPrefixPartition(%q) = %q, want %q", c.id, got, c.want)
		}
	}
}

// The scoping promise memory recall depends on (docs/research/MEMORY.md §7):
// a query constrained to one prefix must return k neighbours FROM THAT PREFIX,
// never another scope's documents and never a shortfall.
func TestVectorSearchScopesToPrefix(t *testing.T) {
	db := newTestDB(t)
	const model = "fixture/embed"
	const a = "repo:/work/a:"
	const b = "repo:/work/b:"

	// Scope a: three facts. Scope b: one fact that is CLOSER to the query than
	// everything in a. A post-filter would return b's hit and drop it, leaving
	// fewer than k; a partition-constrained kNN must not see it at all.
	mustOK(t, putEmbedding(t, db, a+"build.jobs", []float64{0.80, 0.60, 0}, model))
	mustOK(t, putEmbedding(t, db, a+"deps.manager", []float64{0.70, 0.71, 0}, model))
	mustOK(t, putEmbedding(t, db, a+"test.suite", []float64{0.60, 0.80, 0}, model))
	mustOK(t, putEmbedding(t, db, b+"build.jobs", []float64{1, 0, 0}, model))

	scoped := searchVector(t, db, fmt.Sprintf(
		`{"kind":"embedding","model":%q,"vector":[1,0,0],"idPrefix":%q,"limit":10}`,
		model, a))
	items, _ := scoped["items"].([]map[string]any)
	if len(items) != 3 {
		t.Fatalf("scoped kNN returned %d neighbours, want 3 (a post-filtered "+
			"global search would return fewer): %#v", len(items), scoped)
	}
	for _, item := range items {
		id, _ := item["id"].(string)
		if len(id) < len(a) || id[:len(a)] != a {
			t.Fatalf("scoped kNN leaked %q from another scope", id)
		}
	}

	// Unscoped stays exactly as it was: every scope, still nearest-first.
	all := searchVector(t, db, fmt.Sprintf(
		`{"kind":"embedding","model":%q,"vector":[1,0,0],"limit":10}`, model))
	allItems, _ := all["items"].([]map[string]any)
	if len(allItems) != 4 {
		t.Fatalf("unscoped kNN returned %d neighbours, want 4", len(allItems))
	}
	first, _ := allItems[0]["id"].(string)
	if first != b+"build.jobs" {
		t.Fatalf("unscoped nearest = %q, want the b-scope fact", first)
	}
}

// A store created before id_prefix became a partition key must be repaired at
// startup, not served with a schema that rejects every insert. The old table
// is simulated here exactly as the previous release built it.
func TestVectorIndexMigratesFromPrefixlessSchema(t *testing.T) {
	db := newTestDB(t)
	const model = "fixture/embed"

	// Build the PREVIOUS index shape by hand (no id_prefix column), as the
	// last release did, then let the startup sync see it.
	if _, err := db.DB.Exec(`CREATE VIRTUAL TABLE docs_vec_3 USING vec0(
		docs_rowid INTEGER PRIMARY KEY,
		kind TEXT PARTITION KEY,
		model TEXT PARTITION KEY,
		embedding float[3] distance_metric=cosine)`); err != nil {
		t.Fatalf("create old-shape index: %v", err)
	}
	// Seed canonical documents as an older release would already have stored
	// them. Rebuild must preserve populated stores too, not just empty schemas.
	if _, err := db.DB.Exec(`INSERT INTO docs(kind,id,value,rev) VALUES
		('embedding','repo:/p:old',?,1)`,
		`{"model":"fixture/embed","vector":[0,1,0],"dimensions":3}`); err != nil {
		t.Fatal(err)
	}
	// The shape check must report the stale table as unusable BEFORE anything
	// writes through it: that is what routes a store booted from an older
	// release to the repair instead of failing every put.
	if ok, err := vectorTableExists(db.DB, 3); err != nil || ok {
		t.Fatalf("vectorTableExists on a prefixless index = (%v, %v), want (false, nil)", ok, err)
	}
	// In production the repair runs at startup, before any traffic
	// (main.go: syncVectorIndex right after syncSearchIndex). The document is
	// therefore written AFTER the rebuild here, which matches the sequence a
	// store upgraded on boot actually performs.
	if _, err := syncVectorIndex(db.DB); err != nil {
		t.Fatalf("syncVectorIndex: %v", err)
	}
	mustOK(t, putEmbedding(t, db, "repo:/p:a", []float64{1, 0, 0}, model))
	if ok, err := vectorTableExists(db.DB, 3); err != nil || !ok {
		t.Fatalf("after rebuild vectorTableExists = (%v, %v), want (true, nil)", ok, err)
	}
	// The rebuilt index serves the scoped query the old one could not.
	scoped := searchVector(t, db, fmt.Sprintf(
		`{"kind":"embedding","model":%q,"vector":[1,0,0],"idPrefix":"repo:/p:","limit":5}`, model))
	items, _ := scoped["items"].([]map[string]any)
	if len(items) != 2 {
		t.Fatalf("rebuilt index did not preserve old and new documents: %#v", scoped)
	}
}

func TestVectorSearchArbitraryLiteralPrefix(t *testing.T) {
	db := newTestDB(t)
	const model = "prefix-test"
	for _, id := range []string{"repo:/a_%:x", "repo:/a_OTHER:x", "repo:/a_%:xyz"} {
		mustOK(t, putEmbedding(t, db, id, []float64{1, 0, 0}, model))
	}
	r := searchVector(t, db, `{"kind":"embedding","model":"prefix-test","vector":[1,0,0],"idPrefix":"repo:/a_%:x","limit":1}`)
	items, _ := r["items"].([]map[string]any)
	if len(items) != 1 || r["hasMore"] != true {
		t.Fatalf("literal prefix/top-k: %#v", r)
	}
	if items[0]["id"] != "repo:/a_%:x" {
		t.Fatalf("prefix wildcard escaped incorrectly: %#v", items)
	}
}
