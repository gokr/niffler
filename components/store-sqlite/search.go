// Server-side search — the `search` tool of the store contract
// (docs/WIRE.md "Store contract", issue #77). Clients that filter sessions
// (niffler-tui, niffler-ui) call this instead of downloading the whole
// `conversation` kind and filtering locally.
//
// Matching semantics are CONTRACT, identical in every engine:
//
//   - the query and the indexed text are tokenized the same way: runs of
//     unicode letters/digits are tokens, every other rune is a separator;
//     tokens compare case-insensitively.
//   - every query token must match (AND), each as a PREFIX of some token in
//     the document's indexed text.
//   - therefore there is nothing to escape: a character that is not a
//     letter or digit can never act as an operator, it only separates.
//     A query that tokenizes to nothing is `bad-request`; a query that
//     matches nothing is `ok: true` with an empty `items`.
//
// Ordering and paging are `list`'s: ascending id, `after` exclusive,
// `nextAfter` = last returned id when `hasMore`, limit default 100 / cap
// 1000. The result shape is byte-identical to `list`.
//
// This engine implements the match with FTS5 (index table `docs_fts`,
// maintained with the document in the same transaction, rebuilt from
// `docs` at startup whenever the two disagree). The barrel and tidb
// engines apply the same matcher by scanning the kind in id order —
// equivalent behavior, no index (docs/WIRE.md "Store contract").
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	sdk "niffler.dev/sdk"
)

const (
	searchListCap = 1000 // limit cap, as `list` (listCap)
	searchTextCap = 16384
)

// searchTokens tokenizes text the way every engine does for `search`:
// runs of unicode letters/digits, everything else a separator, lowercased.
func searchTokens(s string) []string {
	var out []string
	var b strings.Builder
	flush := func() {
		if b.Len() > 0 {
			out = append(out, strings.ToLower(b.String()))
			b.Reset()
		}
	}
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		} else {
			flush()
		}
	}
	flush()
	return out
}

// appendIndexed appends s to the builder, never past searchTextCap and
// never splitting a rune (a truncated prefix still matches; a split rune
// would put invalid UTF-8 into the index).
func appendIndexed(b *strings.Builder, s string) {
	if s == "" {
		return
	}
	room := searchTextCap - b.Len()
	if room <= 0 {
		return
	}
	if len(s) > room {
		cut := room
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut]
	}
	b.WriteString(s)
}

// indexedText builds the indexed text of one document — the documented,
// per-kind field list (docs/WIRE.md "Store contract" / searchSchema):
//
//	conversation: id + value.title
//	message:      id + every string under value.content (capped)
//	any other kind: id only
//
// Errors in the stored JSON degrade to indexing the id alone: the document
// is still findable by id and the authority (`docs`) is untouched.
func indexedText(kind, id string, value []byte) string {
	var b strings.Builder
	appendIndexed(&b, id)
	switch kind {
	case "conversation":
		var doc struct {
			Title string `json:"title"`
		}
		if json.Unmarshal(value, &doc) == nil {
			appendIndexed(&b, " "+doc.Title)
		}
	case "message":
		var doc map[string]json.RawMessage
		if json.Unmarshal(value, &doc) == nil {
			if content, ok := doc["content"]; ok {
				appendIndexed(&b, " ")
				appendContentStrings(&b, content)
			}
		}
	}
	return b.String()
}

// appendContentStrings walks a message's `content` value collecting every
// string scalar — content is either a string or an array of typed blocks
// ({type, text, ...}), so a recursive walk covers both shapes.
func appendContentStrings(b *strings.Builder, raw json.RawMessage) {
	if b.Len() >= searchTextCap {
		return
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		appendIndexed(b, " "+s)
		return
	}
	var arr []json.RawMessage
	if json.Unmarshal(raw, &arr) == nil {
		for _, elem := range arr {
			appendContentStrings(b, elem)
			if b.Len() >= searchTextCap {
				return
			}
		}
		return
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) == nil {
		for _, v := range obj {
			appendContentStrings(b, v)
			if b.Len() >= searchTextCap {
				return
			}
		}
	}
}

// -----------------------------------------------------------------------
// index maintenance — every mutation of `docs` carries its `docs_fts`
// row in the SAME transaction (callers pass their *sql.Tx).

// indexDocIn upserts one document's index row under docs' rowid.
func indexDocIn(tx *sql.Tx, rowid int64, kind, id string, value []byte) error {
	if _, err := tx.Exec(`DELETE FROM docs_fts WHERE rowid = ?`, rowid); err != nil {
		return fmt.Errorf("unindex: %w", err)
	}
	if _, err := tx.Exec(`INSERT INTO docs_fts(rowid, kind, text) VALUES (?, ?, ?)`,
		rowid, kind, indexedText(kind, id, value)); err != nil {
		return fmt.Errorf("index: %w", err)
	}
	return nil
}

// indexDoc indexes the document written at (kind, id) in the caller's
// transaction — looks the rowid up (same tx sees its own write) and hands
// off to indexDocIn.
func indexDoc(tx *sql.Tx, kind, id string, value []byte) error {
	var rowid int64
	if err := tx.QueryRow(`SELECT rowid FROM docs WHERE kind = ? AND id = ?`,
		kind, id).Scan(&rowid); err != nil {
		return fmt.Errorf("index lookup: %w", err)
	}
	return indexDocIn(tx, rowid, kind, id, value)
}

// unindexDocIn drops one document's index row.
func unindexDocIn(tx *sql.Tx, rowid int64) error {
	if _, err := tx.Exec(`DELETE FROM docs_fts WHERE rowid = ?`, rowid); err != nil {
		return fmt.Errorf("unindex: %w", err)
	}
	return nil
}

// syncSearchIndex rebuilds `docs_fts` from `docs` when the two disagree —
// count or rowid high-water mark. Rebuilding only on disagreement keeps a
// normal restart O(1) while still self-healing after a crash, a manual DB
// edit, or rows written by code that bypassed put (the selftest probe).
// Runs at startup before any traffic; returns whether a rebuild happened.
func syncSearchIndex(db *sql.DB) (bool, error) {
	var docsN, ftsN int64
	if err := db.QueryRow(`SELECT count(*) FROM docs`).Scan(&docsN); err != nil {
		return false, fmt.Errorf("count docs: %w", err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM docs_fts`).Scan(&ftsN); err != nil {
		return false, fmt.Errorf("count docs_fts: %w", err)
	}
	var docsMax, ftsMax sql.NullInt64
	if err := db.QueryRow(`SELECT max(rowid) FROM docs`).Scan(&docsMax); err != nil {
		return false, fmt.Errorf("max docs: %w", err)
	}
	if err := db.QueryRow(`SELECT max(rowid) FROM docs_fts`).Scan(&ftsMax); err != nil {
		return false, fmt.Errorf("max docs_fts: %w", err)
	}
	if docsN == ftsN && docsMax == ftsMax {
		return false, nil
	}

	tx, err := db.Begin()
	if err != nil {
		return false, fmt.Errorf("rebuild begin: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM docs_fts`); err != nil {
		_ = tx.Rollback()
		return false, fmt.Errorf("rebuild clear: %w", err)
	}
	rows, err := tx.Query(`SELECT rowid, kind, id, value FROM docs`)
	if err != nil {
		_ = tx.Rollback()
		return false, fmt.Errorf("rebuild scan: %w", err)
	}
	n := int64(0)
	for rows.Next() {
		var rowid int64
		var kind, id string
		var value []byte
		if err := rows.Scan(&rowid, &kind, &id, &value); err != nil {
			rows.Close()
			_ = tx.Rollback()
			return false, fmt.Errorf("rebuild scan: %w", err)
		}
		if err := indexDocIn(tx, rowid, kind, id, value); err != nil {
			rows.Close()
			_ = tx.Rollback()
			return false, err
		}
		n++
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		_ = tx.Rollback()
		return false, fmt.Errorf("rebuild scan: %w", err)
	}
	rows.Close()
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("rebuild commit: %w", err)
	}
	if n != docsN {
		return true, fmt.Errorf("rebuilt search index: docs changed during rebuild (%d vs %d)", docsN, n)
	}
	return true, nil
}

// -----------------------------------------------------------------------
// the tool

func searchSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind":  map[string]any{"type": "string", "description": "Document kind to search (e.g. conversation, message)"},
			"query": map[string]any{"type": "string", "description": "Search text; words must match tokens of the indexed fields (prefix, case-insensitive, AND)"},
			"limit": map[string]any{"type": "integer", "description": "Max items (default 100, cap 1000)"},
			"after": map[string]any{"type": "string", "description": "Exclusive id cursor from a previous page (default = first page)"},
		},
		"required": []string{"kind", "query"},
		"description": "Search stored documents of a kind by text — the server-side filter for session browsers: " +
			"finds conversations whose id or title matches, or messages whose content matches, without downloading " +
			"the whole kind. Indexed fields per kind: conversation = id + title; message = id + content text " +
			"(capped at 16KB); other kinds = id only. Matching: the query is split into words of letters/digits, " +
			"each must be a case-insensitive PREFIX of a word in the indexed text, all must match (AND); any other " +
			"character is just a separator, so user input needs no escaping. Returns the same shape and ordering " +
			"as list ({items, hasMore, nextAfter?}, ascending id) — pass nextAfter back as `after` to page.",
		"x-harness": map[string]any{"onDemand": true},
	}
}

func searchHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad search args: %w", err)
		}
		kind := rawString(m, "kind")
		after := rawString(m, "after")
		limit := rawInt(m, "limit")
		if limit == 0 {
			limit = 100
		}
		if limit > searchListCap {
			limit = searchListCap
		}
		if limit < 1 {
			limit = 1
		}
		terms := searchTokens(rawString(m, "query"))
		if len(terms) == 0 {
			return sdk.ErrCode("search needs at least one letter or digit in the query", "bad-request"), nil
		}
		// Tokens are letters/digits only, so the FTS5 match string can never
		// carry syntax: every token becomes a literal prefix term (lowercased,
		// since FTS5's AND/OR/NOT operators are uppercase-only).
		match := strings.Join(terms, "* AND ") + "*"
		query := `SELECT d.id, d.rev, d.value FROM docs_fts, docs d
			 WHERE docs_fts MATCH ? AND docs_fts.kind = ? AND d.rowid = docs_fts.rowid`
		qargs := []any{match, kind}
		if after != "" {
			query += ` AND d.id > ?`
			qargs = append(qargs, after)
		}
		query += ` ORDER BY d.id LIMIT ?`
		qargs = append(qargs, limit)
		rows, err := db.Query(query, qargs...)
		if err != nil {
			return nil, fmt.Errorf("search: %w", err)
		}
		defer rows.Close()
		items := []map[string]any{} // non-nil: marshals as [] when no match
		for rows.Next() {
			var id string
			var rev int64
			var value []byte
			if err := rows.Scan(&id, &rev, &value); err != nil {
				return nil, fmt.Errorf("search: %w", err)
			}
			items = append(items, map[string]any{
				"id": id, "rev": rev, "value": json.RawMessage(value),
			})
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("search: %w", err)
		}
		// Same hasMore/nextAfter rule as `list`: a full page may have
		// successors, so the caller asks for one more page and stops when it
		// comes back empty. Never silently truncate a result set.
		hasMore := len(items) >= int(limit)
		out := map[string]any{"items": items, "hasMore": hasMore}
		if hasMore && len(items) > 0 {
			out["nextAfter"] = items[len(items)-1]["id"]
		}
		return sdk.OK(out), nil
	}
}
