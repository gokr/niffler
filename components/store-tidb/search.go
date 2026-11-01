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
	searchScanSize = 500  // rows read per scan batch
	// The same per-kind budgets as store-sqlite: this engine has no index and
	// scans, so the text it matches against must be identical or the two
	// engines answer differently (they used to: reasoning was indexed on
	// sqlite only). searchTextCap is the total; the rest are per-part so no
	// single part can starve the others.
	searchTextCap      = 65536
	searchContentCap   = 49152 // message content (text, tool-result bodies)
	searchReasoningCap = 8192  // prior-turn thinking ("what did I consider?")
	searchToolCallCap  = 8192  // function names + arguments (paths, patterns, queries)
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
// per-kind field list (docs/WIRE.md "Store contract" / searchSchema), which
// MUST match store-sqlite's byte for byte in effect:
//
//	conversation: id + value.title
//	message:      id + tool-call names/arguments + value.reasoning + every
//	              string under value.content (each part capped)
//	any other kind: id only
//
// Order matters: the structural parts are indexed FIRST so a huge tool result
// cannot evict them (the old single 16KB budget did exactly that).
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
		if json.Unmarshal(value, &doc) != nil {
			return b.String()
		}
		// Tool-call arguments name the files, symbols and commands a session
		// touched, and a call message carries no text in `content` at all.
		if calls, ok := doc["tool_calls"]; ok {
			appendIndexed(&b, " ")
			appendToolCalls(&b, calls, b.Len()+searchToolCallCap)
		}
		// Reasoning is canonical history: "what did I consider and reject".
		// It used to be indexed on sqlite only, so the same query answered
		// differently per engine.
		if reasoning, ok := doc["reasoning"]; ok {
			var s string
			if json.Unmarshal(reasoning, &s) == nil && s != "" {
				appendIndexed(&b, " ")
				limit := b.Len() + searchReasoningCap
				if limit > searchTextCap {
					limit = searchTextCap
				}
				appendUpTo(&b, s, limit)
			}
		}
		if content, ok := doc["content"]; ok {
			appendIndexed(&b, " ")
			limit := b.Len() + searchContentCap
			if limit > searchTextCap {
				limit = searchTextCap
			}
			appendContentStrings(&b, content, limit)
		}
	}
	return b.String()
}

// appendToolCalls indexes each call's function name and `arguments` (a JSON
// string in the OpenAI wire shape, sometimes an object). Ids are skipped.
func appendToolCalls(b *strings.Builder, raw json.RawMessage, limit int) {
	if b.Len() >= limit {
		return
	}
	var arr []json.RawMessage
	if json.Unmarshal(raw, &arr) != nil {
		var obj map[string]json.RawMessage
		if json.Unmarshal(raw, &obj) == nil {
			arr = []json.RawMessage{raw}
		} else {
			return
		}
	}
	for _, elem := range arr {
		if b.Len() >= limit {
			return
		}
		var call struct {
			Function struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			} `json:"function"`
		}
		if json.Unmarshal(elem, &call) != nil {
			continue
		}
		appendIndexed(b, " "+call.Function.Name)
		if call.Function.Arguments != nil {
			appendIndexed(b, " ")
			appendContentStrings(b, call.Function.Arguments, limit)
		}
	}
}

// appendContentStrings walks a message's `content` value collecting every
// string scalar — content is either a string or an array of typed blocks
// ({type, text, ...}), so a recursive walk covers both shapes.
func appendContentStrings(b *strings.Builder, raw json.RawMessage, limit int) {
	if b.Len() >= limit {
		return
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		b.WriteString(" ")
		appendUpTo(b, s, limit)
		return
	}
	var arr []json.RawMessage
	if json.Unmarshal(raw, &arr) == nil {
		for _, elem := range arr {
			appendContentStrings(b, elem, limit)
			if b.Len() >= limit {
				return
			}
		}
		return
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) == nil {
		for _, v := range obj {
			appendContentStrings(b, v, limit)
			if b.Len() >= limit {
				return
			}
		}
	}
}

// appendUpTo appends s without crossing limit or splitting a rune.
func appendUpTo(b *strings.Builder, s string, limit int) {
	if s == "" {
		return
	}
	room := limit - b.Len()
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

// -----------------------------------------------------------------------
// the tool

func searchSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind":  map[string]any{"type": "string", "description": "Document kind to search (e.g. conversation, message)"},
			"query": map[string]any{"type": "string", "description": "Search text; words must match tokens of the indexed fields (prefix, case-insensitive, AND)"},
			"vector": map[string]any{"type": "array", "items": map[string]any{"type": "number"},
				"description": "Nearest-neighbour mode (sqlite engine only; this engine answers code unsupported)"},
			"model": map[string]any{"type": "string",
				"description": "Vector mode: the embedding model whose space to search"},
			"idPrefix": map[string]any{"type": "string", "description": "Restrict to ids with this prefix — e.g. one conversation's messages: <convId>:"},
			"rank":     map[string]any{"type": "boolean", "description": "Request relevance ordering; this engine has no index and answers unranked in id order (ranked: false, issue #94)"},
			"snippet":  map[string]any{"type": "boolean", "description": "Attach a best-effort span-marked one-line `snippet` per hit (the first matched word in [brackets])"},
			"offset":   map[string]any{"type": "integer", "description": "Ranked paging only; ignored here — use `after`"},
			"limit":    map[string]any{"type": "integer", "description": "Max items (default 100, cap 1000)"},
			"after":    map[string]any{"type": "string", "description": "Exclusive id cursor from a previous page (default = first page)"},
		},
		"required": []string{"kind"},
		"description": "Search stored documents of a kind by text — the server-side filter for session browsers: " +
			"finds conversations whose id or title matches, or messages whose content, tool-call arguments or " +
			"reasoning match, without downloading the whole kind. Indexed fields per kind: conversation = id + " +
			"title; message = id + tool-call names/arguments + reasoning + content text (per-part caps under a " +
			"64KB document cap, structural parts first); other kinds = id only. Matching: the query is split into words of letters/digits, " +
			"each must be a case-insensitive PREFIX of a word in the indexed text, all must match (AND); any other " +
			"character is just a separator, so user input needs no escaping. Ordering is ascending id " +
			"({items, hasMore, nextAfter?}, pass nextAfter back as `after` to page); the reply carries " +
			"`ranked: false` — this engine scans (docs/WIRE.md \"Store contract\", issue #51/#94).",
		// Read: a search takes no write claim (see getSchema in main.go).
		"x-harness": map[string]any{"onDemand": true, "effect": "read"},
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

func searchHandler(db *sql.DB, owner ...string) sdk.ToolHandler {
	instance := documentOwner(owner)
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad search args: %w", err)
		}
		kind := rawString(m, "kind")
		// Vector mode is not implemented here. Say so explicitly: silently
		// falling through to the text path would answer a kNN query with a
		// token-matching scan and look like a successful search.
		if v, hasVector := m["vector"]; hasVector && v != nil {
			return sdk.ErrCode(
				"vector search is not implemented by this store engine (tidb); "+
					"use the sqlite engine for embeddings", "unsupported"), nil
		}
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
			query := `SELECT id, rev, value FROM docs WHERE instance_id = ? AND kind = ? AND id > ?`
			qargs := []any{instance, kind, cursor}
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
