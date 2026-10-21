// The reason store-sqlite builds with cgo: sqlite-vec. This proves the
// extension is reachable on the engine's own connection, that a vec0 table
// can be created and queried with real kNN, and that the existing FTS5 search
// index still works in the same build — both toggles (CGO_ENABLED=1 and
// -tags sqlite_fts5) are load-bearing, and neither may silently regress.

package main

import (
	"encoding/json"
	"fmt"
	"testing"

	vec "github.com/asg017/sqlite-vec-go-bindings/cgo"
)

func TestSQLiteVecIsAvailable(t *testing.T) {
	db := newTestDB(t)

	var version string
	if err := db.QueryRow(`SELECT vec_version()`).Scan(&version); err != nil {
		t.Fatalf("vec_version(): %v", err)
	}
	if version == "" {
		t.Fatal("vec_version() returned an empty string")
	}

	if _, err := db.Exec(`CREATE VIRTUAL TABLE vec_items USING vec0(
		item_id TEXT PRIMARY KEY, embedding float[3])`); err != nil {
		t.Fatalf("create vec0 table: %v", err)
	}
	insert := func(id string, v []float32) {
		t.Helper()
		blob, err := vec.SerializeFloat32(v)
		if err != nil {
			t.Fatalf("serialize %s: %v", id, err)
		}
		if _, err := db.Exec(`INSERT INTO vec_items(item_id, embedding) VALUES (?, ?)`, id, blob); err != nil {
			t.Fatalf("insert %s: %v", id, err)
		}
	}
	insert("cat", []float32{1, 0, 0})
	insert("dog", []float32{0.9, 0.1, 0})
	insert("volcano", []float32{0, 1, 0})

	query, err := vec.SerializeFloat32([]float32{1, 0, 0})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := db.Query(`SELECT item_id, distance FROM vec_items
		WHERE embedding MATCH ? AND k = 2 ORDER BY distance`, query)
	if err != nil {
		t.Fatalf("kNN query: %v", err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var id string
		var distance float64
		if err := rows.Scan(&id, &distance); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, id)
	}
	if len(got) != 2 || got[0] != "cat" || got[1] != "dog" {
		t.Fatalf("kNN order = %v, want [cat dog]", got)
	}
}

// The search index (migration 00002) needs FTS5, which mattn ships OFF by
// default — it exists only because the build passes -tags sqlite_fts5. A unit
// test cannot see the tag, but it CAN see the effect: the virtual table
// exists, and a MATCH query answers.
func TestFTS5IsAvailable(t *testing.T) {
	db := newTestDB(t)
	var name string
	if err := db.QueryRow(
		`SELECT name FROM sqlite_master WHERE name = 'docs_fts'`).Scan(&name); err != nil {
		t.Fatalf("docs_fts missing: %v", err)
	}
	if _, err := db.Exec(`CREATE VIRTUAL TABLE fts_probe USING fts5(text)`); err != nil {
		t.Fatalf("fts5 module unavailable (build with -tags sqlite_fts5): %v", err)
	}
}

// A document holding a vector survives the ordinary put/get path unchanged:
// the store is schema-free, so a consumer can persist its own embedding shape
// today without the engine learning a vector kind.
func TestVectorDocumentRoundTrips(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	get := getHandler(db.DB)

	vector := make([]float64, 768)
	for i := range vector {
		vector[i] = float64(i) / 768
	}
	value, err := json.Marshal(map[string]any{
		"model": "hf:nomic-ai/nomic-embed-text-v1.5", "dimensions": 768,
		"vector": vector, "textRef": "conv-1:000010",
	})
	if err != nil {
		t.Fatal(err)
	}
	mustOK(t, call(t, put, fmt.Sprintf(
		`{"kind":"embedding","id":"conv-1:000010@nomic-768","value":%s}`, value)))

	out := mustOK(t, call(t, get, `{"kind":"embedding","id":"conv-1:000010@nomic-768"}`))
	got, ok := out["value"].(json.RawMessage)
	if !ok {
		t.Fatalf("value = %#v", out["value"])
	}
	var decoded struct {
		Dimensions int       `json:"dimensions"`
		Vector     []float64 `json:"vector"`
	}
	if err := json.Unmarshal(got, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Dimensions != 768 || len(decoded.Vector) != 768 || decoded.Vector[767] != vector[767] {
		t.Fatalf("vector did not round-trip: dims=%d len=%d", decoded.Dimensions, len(decoded.Vector))
	}
}
