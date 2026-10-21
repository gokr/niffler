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
