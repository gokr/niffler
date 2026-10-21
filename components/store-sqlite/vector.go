// Vector search — the `search` tool's second mode (docs/WIRE.md "Store
// contract", "Vector search").
//
// A caller stores embeddings as ordinary documents of kind `embedding`:
//
//	{"kind":"embedding", "id":"<ref>@<model>",
//	 "value":{"model":"hf:nomic-ai/nomic-embed-text-v1.5",
//	          "dimensions":768, "vector":[0.01,…],
//	          "source":"message", "sourceId":"conv-1:000042"}}
//
// and asks `search {kind:"embedding", vector:[…], model:"…"}` for the nearest
// ones. The document contract is unchanged (documents stay opaque JSON); the
// index below is DERIVED state, exactly like docs_fts: put/del maintain it in
// the same transaction, and startup rebuilds it when it disagrees with `docs`.
//
// Why a table per dimension: vec0 fixes the vector width at CREATE time, and
// one deployment legitimately holds several models (768-dim local, 1536-dim
// hosted). Padding a short vector to a common width would quietly corrupt
// cosine distance, so the dimension is part of the table name
// (`docs_vec_<dim>`) and a query can only ever reach vectors of its own width.
// There is no goose migration for these tables for the same reason: their
// shape is data, not schema, and they can be dropped without loss.
//
// Filtering: `kind` and `model` are vec0 PARTITION KEYs, so a kNN query with
// either filter returns k neighbours *within* that partition — correct k, not
// a post-filtered shortfall. That matters because mixing models is
// meaningless (different embedding spaces) and mixing kinds is usually wrong.
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	vec "github.com/asg017/sqlite-vec-go-bindings/cgo"
	sdk "niffler.dev/sdk"
)

const (
	embeddingKind      = "embedding"
	vectorDefaultLimit = 20   // a retrieval primitive, not a listing
	vectorLimitCap     = 1000 // one page of neighbours
	// maxVectorDim is a sanity bound: a malformed `dimensions` must not
	// create a table with a 4-billion-wide vector column.
	maxVectorDim = 8192
)

// embeddingDoc is the parsed shape of an `embedding` document's value.
type embeddingDoc struct {
	Model      string    `json:"model"`
	Dimensions int       `json:"dimensions"`
	Vector     []float64 `json:"vector"`
	// Source/sourceId are informational: they name the document this vector
	// describes, so a result can be resolved back to real content without
	// parsing the embedding id.
	Source   string `json:"source,omitempty"`
	SourceID string `json:"sourceId,omitempty"`
}

// parseEmbedding validates a document value against the embedding contract.
// Every refusal names the field: a malformed embedding must fail at write
// time, because a silently-skipped vector is unfindable later with no error
// anywhere to explain it.
func parseEmbedding(value []byte) (embeddingDoc, []byte, error) {
	var doc embeddingDoc
	if err := json.Unmarshal(value, &doc); err != nil {
		return doc, nil, fmt.Errorf("embedding value must be an object: %w", err)
	}
	doc.Model = strings.TrimSpace(doc.Model)
	if doc.Model == "" {
		return doc, nil, fmt.Errorf("embedding needs value.model (the embedding model id)")
	}
	if len(doc.Vector) == 0 {
		return doc, nil, fmt.Errorf("embedding needs a non-empty value.vector")
	}
	// The declared width is the contract; a mismatch means the producer and
	// the model disagree, which is exactly the bug that would otherwise
	// surface as a mysterious "no results".
	if doc.Dimensions == 0 {
		doc.Dimensions = len(doc.Vector)
	}
	if doc.Dimensions != len(doc.Vector) {
		return doc, nil, fmt.Errorf(
			"value.dimensions is %d but value.vector has %d entries",
			doc.Dimensions, len(doc.Vector))
	}
	if doc.Dimensions > maxVectorDim {
		return doc, nil, fmt.Errorf("value.dimensions %d exceeds the %d bound",
			doc.Dimensions, maxVectorDim)
	}
	widths := make([]float32, len(doc.Vector))
	for i, v := range doc.Vector {
		widths[i] = float32(v)
	}
	blob, err := vec.SerializeFloat32(widths)
	if err != nil {
		return doc, nil, fmt.Errorf("serialize vector: %w", err)
	}
	return doc, blob, nil
}

// vectorTableName is the per-dimension index table. The name is derived from
// an integer, never from caller text, so it cannot be injected.
func vectorTableName(dim int) string {
	return fmt.Sprintf("docs_vec_%d", dim)
}

// execer is the subset of *sql.Tx / *sql.DB the index helpers need, so they
// can run inside a write transaction or on the bare handle at startup.
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

// ensureVectorTable creates the index for one dimension if it is missing.
// Called on the write path (inside put's transaction) and at startup.
func ensureVectorTable(tx execer, dim int) error {
	// `IF NOT EXISTS` on a vec0 virtual table is a no-op when the table is
	// already there, so this stays cheap on the hot path.
	_, err := tx.Exec(fmt.Sprintf(`CREATE VIRTUAL TABLE IF NOT EXISTS %s USING vec0(
		docs_rowid INTEGER PRIMARY KEY,
		kind TEXT PARTITION KEY,
		model TEXT PARTITION KEY,
		embedding float[%d] distance_metric=cosine)`, vectorTableName(dim), dim))
	if err != nil {
		return fmt.Errorf("create vector index for %d dimensions: %w", dim, err)
	}
	return nil
}

// indexVector upserts one document's vector row. A document that is not an
// embedding leaves no row behind — put() refuses a malformed embedding first,
// so the only way to reach the drop path is a kind that became non-embedding,
// which must not keep a stale vector.
func indexVector(tx *sql.Tx, rowid int64, kind, id string, value []byte) error {
	// Drop any previous row first: the rowid is the key, and the dimension
	// (hence the table) can change when a document is rewritten.
	if err := clearVectorRows(tx, rowid); err != nil {
		return err
	}
	if kind != embeddingKind {
		return nil
	}
	doc, blob, err := parseEmbedding(value)
	if err != nil {
		// put() validated the same value above; reaching here means the
		// caller wrote around it. Refuse rather than store an unindexable doc.
		return err
	}
	if err := ensureVectorTable(tx, doc.Dimensions); err != nil {
		return err
	}
	_, err = tx.Exec(fmt.Sprintf(
		`INSERT INTO %s(docs_rowid, kind, model, embedding) VALUES (?, ?, ?, ?)`,
		vectorTableName(doc.Dimensions)), rowid, kind, doc.Model, blob)
	if err != nil {
		return fmt.Errorf("index vector: %w", err)
	}
	return nil
}

// clearVectorRows removes a rowid from every dimension table. The set is read
// from sqlite_master (not from the document) so a rewrite that changes
// dimension cannot leave the old row behind.
func clearVectorRows(tx execer, rowid int64) error {
	names, err := vectorTableNames(tx)
	if err != nil {
		return err
	}
	for _, name := range names {
		if _, err := tx.Exec(`DELETE FROM `+name+` WHERE docs_rowid = ?`, rowid); err != nil {
			return fmt.Errorf("unindex vector (%s): %w", name, err)
		}
	}
	return nil
}

// vectorTableNames lists the dimension tables that exist right now.
//
// vec0 also creates SHADOW tables beside each virtual table (…_info, …_chunks,
// …_rowids, …). They share the prefix but are not index rows, so the pattern
// is anchored twice: `docs_vec_` + digits, nothing after them.
func vectorTableNames(q execer) ([]string, error) {
	rows, err := q.Query(
		`SELECT name FROM sqlite_master WHERE type = 'table'
		 AND name GLOB 'docs_vec_[0-9]*'
		 AND name NOT GLOB 'docs_vec_[0-9]*[^0-9]*'`)
	if err != nil {
		return nil, fmt.Errorf("list vector indexes: %w", err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("list vector indexes: %w", err)
		}
		names = append(names, name)
	}
	return names, rows.Err()
}

// unindexVector drops one document's vector rows, in del's transaction.
func unindexVector(tx *sql.Tx, rowid int64) error {
	return clearVectorRows(tx, rowid)
}

// vectorHit is one kNN result, joined back to its document.
type vectorHit struct {
	ID       string
	Rev      int64
	Value    []byte
	Distance float64
}

// vectorSearch answers the kNN query. `model` is required: two models are
// different embedding spaces, so a query that did not name one could only
// return nonsense. A dimension whose table does not exist yet has no vectors,
// which is an empty answer rather than an error (a fresh store has no
// embeddings, and that is not a failure).
func vectorSearch(db *sql.DB, kind, model string, query []float64, limit int) ([]vectorHit, error) {
	dim := len(query)
	widths := make([]float32, dim)
	for i, v := range query {
		widths[i] = float32(v)
	}
	blob, err := vec.SerializeFloat32(widths)
	if err != nil {
		return nil, fmt.Errorf("serialize query vector: %w", err)
	}
	exists, err := vectorTableExists(db, dim)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, nil
	}
	// vec0 requires its own `k = ?` constraint on a kNN query — a generic
	// LIMIT is refused (`A LIMIT or 'k = ?' constraint is required`). Ask for
	// one extra row so the caller can tell a truncated result set from a
	// complete one, the same rule as every other page in this store.
	sqlText := fmt.Sprintf(`SELECT d.id, d.rev, d.value, v.distance
		FROM %s v JOIN docs d ON d.rowid = v.docs_rowid
		WHERE v.embedding MATCH ? AND k = ? AND v.kind = ? AND v.model = ?
		ORDER BY v.distance`, vectorTableName(dim))
	rows, err := db.Query(sqlText, blob, limit+1, kind, model)
	if err != nil {
		// The table is chosen from the query's own width, so a width
		// mismatch cannot reach here; an error is a real failure.
		return nil, fmt.Errorf("vector search: %w", err)
	}
	defer rows.Close()
	var hits []vectorHit
	for rows.Next() {
		var hit vectorHit
		if err := rows.Scan(&hit.ID, &hit.Rev, &hit.Value, &hit.Distance); err != nil {
			return nil, fmt.Errorf("vector search: %w", err)
		}
		hits = append(hits, hit)
	}
	return hits, rows.Err()
}

func vectorTableExists(q execer, dim int) (bool, error) {
	var name string
	err := q.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`,
		vectorTableName(dim)).Scan(&name)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("check vector index: %w", err)
	}
	return true, nil
}

// syncVectorIndex rebuilds the vector indexes when they disagree with `docs`,
// on the same principle as syncSearchIndex: a count comparison keeps a normal
// restart cheap, and any disagreement re-derives the whole index from the
// documents (which are the authority). Returns whether a rebuild happened.
func syncVectorIndex(db *sql.DB) (bool, error) {
	var embeddingDocs int64
	if err := db.QueryRow(
		`SELECT count(*) FROM docs WHERE kind = ?`, embeddingKind).Scan(&embeddingDocs); err != nil {
		return false, fmt.Errorf("count embedding docs: %w", err)
	}
	names, err := vectorTableNames(db)
	if err != nil {
		return false, err
	}
	var indexed int64
	for _, name := range names {
		var n int64
		if err := db.QueryRow(`SELECT count(*) FROM ` + name).Scan(&n); err != nil {
			return false, fmt.Errorf("count %s: %w", name, err)
		}
		indexed += n
	}
	// A store with no embedding documents and no index is the common case:
	// nothing to do, and no table to create.
	if embeddingDocs == indexed {
		return false, nil
	}

	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("vector rebuild begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, name := range names {
		if _, err := tx.Exec(`DROP TABLE IF EXISTS ` + name); err != nil {
			return false, fmt.Errorf("vector rebuild drop: %w", err)
		}
	}
	rows, err := tx.Query(`SELECT rowid, kind, id, value FROM docs WHERE kind = ?`,
		embeddingKind)
	if err != nil {
		return false, fmt.Errorf("vector rebuild scan: %w", err)
	}
	n := int64(0)
	for rows.Next() {
		var rowid int64
		var kind, id string
		var value []byte
		if err := rows.Scan(&rowid, &kind, &id, &value); err != nil {
			rows.Close()
			return false, fmt.Errorf("vector rebuild scan: %w", err)
		}
		if err := indexVector(tx, rowid, kind, id, value); err != nil {
			rows.Close()
			return false, fmt.Errorf("vector rebuild (%s): %w", id, err)
		}
		n++
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return false, fmt.Errorf("vector rebuild scan: %w", err)
	}
	rows.Close()
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("vector rebuild commit: %w", err)
	}
	if n != embeddingDocs {
		return true, fmt.Errorf("rebuilt vector index: embeddings changed during rebuild (%d vs %d)",
			embeddingDocs, n)
	}
	return true, nil
}

// indexVectorRow indexes the document written at (kind, id) inside the
// caller's transaction — the rowid lookup mirrors indexDoc, because a vector
// row is keyed by the document's own rowid (one table entry per document,
// whatever its kind).
func indexVectorRow(tx *sql.Tx, kind, id string, value []byte) error {
	var rowid int64
	if err := tx.QueryRow(`SELECT rowid FROM docs WHERE kind = ? AND id = ?`,
		kind, id).Scan(&rowid); err != nil {
		return fmt.Errorf("vector index lookup: %w", err)
	}
	return indexVector(tx, rowid, kind, id, value)
}

// vectorSearchResult is search's vector mode: parse the request, run the kNN,
// and answer in the same envelope shape as the text mode (items/hasMore/
// ranked) so a caller never has to learn two paging rules.
func vectorSearchResult(db *sql.DB, kind string, m map[string]json.RawMessage) (any, error) {
	model := strings.TrimSpace(rawString(m, "model"))
	if model == "" {
		return sdk.ErrCode(
			"vector search needs `model` — vectors of different models are different spaces",
			"bad-request"), nil
	}
	if kind == "" {
		return sdk.ErrCode("vector search needs `kind`", "bad-request"), nil
	}
	var query []float64
	if err := json.Unmarshal(m["vector"], &query); err != nil {
		return sdk.ErrCode("`vector` must be an array of numbers", "bad-request"), nil
	}
	if len(query) == 0 {
		return sdk.ErrCode("`vector` must not be empty", "bad-request"), nil
	}
	if len(query) > maxVectorDim {
		return sdk.ErrCode(fmt.Sprintf("`vector` has %d dimensions; the bound is %d",
			len(query), maxVectorDim), "bad-request"), nil
	}
	limit := int(rawInt(m, "limit"))
	if limit <= 0 {
		limit = vectorDefaultLimit
	}
	if limit > vectorLimitCap {
		limit = vectorLimitCap
	}
	hits, err := vectorSearch(db, kind, model, query, limit)
	if err != nil {
		return nil, err
	}
	items := []map[string]any{} // non-nil: marshals as [] when there is no match
	for i, hit := range hits {
		if i >= limit {
			break // the probe row
		}
		items = append(items, map[string]any{
			"id": hit.ID, "rev": hit.Rev,
			"value": json.RawMessage(hit.Value), "distance": hit.Distance,
		})
	}
	out := map[string]any{
		"items": items, "hasMore": len(hits) > limit,
		"ranked": true, "vector": true,
	}
	return sdk.OK(out), nil
}
