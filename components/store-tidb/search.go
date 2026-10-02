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
			"idPrefix": map[string]any{"type": "string", "description": "Restrict to ids with this prefix — e.g. one conversation's messages: <convId>:"},
			"rank": map[string]any{"type": "boolean", "description": "Request relevance ordering; this engine has no index and answers unranked in id order (ranked: false, issue #94)"},
			"snippet": map[string]any{"type": "boolean", "description": "Attach a best-effort span-marked one-line `snippet` per hit (the first matched word in [brackets])"},
			"offset": map[string]any{"type": "integer", "description": "Ranked paging only; ignored here — use `after`"},
			"limit": map[string]any{"type": "integer", "description": "Max items (default 100, cap 1000)"},
			"after": map[string]any{"type": "string", "description": "Exclusive id cursor from a previous page (default = first page)"},
		},
		"required": []string{"kind", "query"},
		"description": "Search stored documents of a kind by text — the server-side filter for session browsers: " +
			"finds conversations whose id or title matches, or messages whose content matches, without downloading " +
			"the whole kind. Indexed fields per kind: conversation = id + title; message = id + content text " +
			"(capped at 16KB); other kinds = id only. Matching: the query is split into words of letters/digits, " +
			"each must be a case-insensitive PREFIX of a word in the indexed text, all must match (AND); any other " +
			"character is just a separator, so user input needs no escaping. Ordering is ascending id " +
			"({items, hasMore, nextAfter?}, pass nextAfter back as `after` to page); the reply carries " +
			"`ranked: false` — this engine scans (docs/WIRE.md \"Store contract\", issue #51/#94).",
		"x-harness": map[string]any{"onDemand": true},
	}
}

// likePrefix escapes a user prefix for `id LIKE ?` — MySQL's default
// escape character is backslash, so %, _ and \ would widen the match.
func likePrefix(prefix string) string {
	return strings.NewReplacer("\\", "\\\\", "%", "\\%", "_", "\\_").Replace(prefix) + "%"
}

// naiveSnippet is this engine's best-effort span marking (the sqlite
// engine marks via FTS5's snippet()): a window of the indexed text around
// the first occurrence of any query token, the token itself in [brackets].
func naiveSnippet(text string, terms []string, maxBytes int) string {
	low := strings.ToLower(text)
	at, hit := -1, ""
	for _, t := range terms {
		i := strings.Index(low, t)
		if i >= 0 && (at < 0 || i < at) {
			at, hit = i, t
		}
	}
	if at < 0 {
		return ""
	}
	startAt := max(at-60, 0)
	endAt := min(at+len(hit)+maxBytes, len(text))
	var b strings.Builder
	if startAt > 0 {
		b.WriteString("…")
	}
	b.WriteString(text[startAt:at])
	b.WriteByte('[')
	b.WriteString(text[at : at+len(hit)])
	b.WriteByte(']')
	b.WriteString(text[at+len(hit) : endAt])
	if endAt < len(text) {
		b.WriteString("…")
	}
	return b.String()
}

func searchHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad search args: %w", err)
		}
		kind := rawString(m, "kind")
		after := rawString(m, "after")
		idPrefix := rawString(m, "idPrefix")
		wantSnippet := rawBool(m, "snippet")
		offset := int(rawInt(m, "offset"))
		if offset < 0 {
			offset = 0
		}
		// `rank` is accepted and ignored: no index to rank with (issue #94).
		// The reply always says `ranked: false`; `offset` still pages the
		// match set so the contract's ranked-paging shape works everywhere.
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
		skipped := 0
		for {
			query := `SELECT id, rev, value FROM docs WHERE kind = ? AND id > ?`
			qargs := []any{kind, cursor}
			if idPrefix != "" {
				query += ` AND id LIKE ?`
				qargs = append(qargs, likePrefix(idPrefix))
			}
			query += ` ORDER BY id LIMIT ?`
			qargs = append(qargs, searchScanSize)
			rows, err := db.Query(query, qargs...)
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
				idx := indexedText(kind, id, value)
				if matchesTerms(idx, terms) {
					if skipped < offset {
						skipped++
						continue
					}
					item := map[string]any{
						"id": id, "rev": rev, "value": json.RawMessage(value),
					}
					if wantSnippet {
						item["snippet"] = naiveSnippet(idx, terms, 140)
					}
					items = append(items, item)
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
		out := map[string]any{"items": items, "hasMore": hasMore, "ranked": false}
		if hasMore && len(items) > 0 {
			if offset > 0 {
				out["nextOffset"] = offset + int(limit)
			} else {
				out["nextAfter"] = items[len(items)-1]["id"]
			}
		}
		return sdk.OK(out), nil
	}
}

