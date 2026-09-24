// Server-side search — the `search` tool of the store contract
// (docs/WIRE.md "Store contract", issue #77), TiDB engine.
//
// TiDB/MySQL have no FTS index, so this engine implements the CONTRACT by
// scanning the kind in id order and applying the same matcher the sqlite
// engine gets from FTS5 (token-prefix AND over the per-kind indexed
// fields — see the identical searchTokens/indexedText in
// components/store-sqlite/search.go; the semantics live in docs/WIRE.md,
// the implementation is engine-private). Equivalent behavior, no index:
// O(documents of the kind) per call, which is the documented cost of this
// engine and still beats downloading the whole kind to every client.
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
	searchListCap  = 1000 // limit cap, as `list` (listCap)
	searchTextCap  = 16384
	searchScanSize = 500 // rows read per scan batch
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

// matchesTerms applies the contract matcher: every term must be a
// case-insensitive prefix of some token in text (terms arrive lowercased
// from searchTokens).
func matchesTerms(text string, terms []string) bool {
	if len(terms) == 0 {
		return false
	}
	toks := searchTokens(text)
	for _, term := range terms {
		found := false
		for _, tok := range toks {
			if strings.HasPrefix(tok, term) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// appendIndexed appends s to the builder, never past searchTextCap and
// never splitting a rune (a truncated prefix still matches; a split rune
// would put invalid UTF-8 into the text we match against).
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

// indexedText builds the searchable text of one document — the documented,
// per-kind field list (docs/WIRE.md "Store contract" / searchSchema):
//
//	conversation: id + value.title
//	message:      id + every string under value.content (capped)
//	any other kind: id only
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
		limit := int(rawInt(m, "limit"))
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

		// Scan the kind in id order from the cursor — the same seek `list`
		// does, batched, stopping as soon as the page is full. No total
		// cap: a result set is only ever cut by `limit` + the cursor, never
		// silently truncated (docs/WIRE.md "Store contract").
		items := []map[string]any{} // non-nil: marshals as [] when no match
		cursor := after
		for {
			rows, err := db.Query(
				`SELECT id, rev, value FROM docs WHERE kind = ? AND id > ? ORDER BY id LIMIT ?`,
				kind, cursor, searchScanSize)
			if err != nil {
				return nil, fmt.Errorf("search: %w", err)
			}
			n := 0
			for rows.Next() {
				var id string
				var rev int64
				var value []byte
				if err := rows.Scan(&id, &rev, &value); err != nil {
					rows.Close()
					return nil, fmt.Errorf("search: %w", err)
				}
				n++
				cursor = id
				if len(items) >= limit {
					continue // drain this batch so the cursor advances fully
				}
				if matchesTerms(indexedText(kind, id, value), terms) {
					items = append(items, map[string]any{
						"id": id, "rev": rev, "value": json.RawMessage(value),
					})
				}
			}
			if err := rows.Err(); err != nil {
				rows.Close()
				return nil, fmt.Errorf("search: %w", err)
			}
			rows.Close()
			if len(items) >= limit {
				break // page full — same hasMore rule as `list`
			}
			if n < searchScanSize {
				break // kind exhausted
			}
		}
		hasMore := len(items) >= limit
		out := map[string]any{"items": items, "hasMore": hasMore}
		if hasMore && len(items) > 0 {
			out["nextAfter"] = items[len(items)-1]["id"]
		}
		return sdk.OK(out), nil
	}
}
