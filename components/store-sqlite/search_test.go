// Unit tests for the sqlite engine's `search` tool: index maintenance on
// put/update/del, the documented per-kind indexed fields, matching
// semantics (token-prefix AND, separator characters inert), paging and the
// startup self-heal (rebuild when the index disagrees with `docs`).
// The cross-engine bus contract — same shapes from every engine — is
// t_store, which runs against sqlite, barrel and tidb.
package main

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

func searchIDs(t *testing.T, m map[string]any) []string {
	t.Helper()
	if m["ok"] != true {
		t.Fatalf("search failed: %v", m)
	}
	items, _ := m["items"].([]map[string]any)
	ids := make([]string, 0, len(items))
	for _, it := range items {
		ids = append(ids, it["id"].(string))
	}
	return ids
}

func TestSearchTokens(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"Can you check the PRs", []string{"can", "you", "check", "the", "prs"}},
		{"conv-5d90ead1a5bd", []string{"conv", "5d90ead1a5bd"}},
		{`%"'; OR NOT _`, []string{"or", "not"}},
		{"   ", nil},
		{"Ünïcodé Wörter", []string{"ünïcodé", "wörter"}},
	}
	for _, c := range cases {
		got := searchTokens(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("searchTokens(%q) = %v, want %v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("searchTokens(%q) = %v, want %v", c.in, got, c.want)
			}
		}
	}
}

func TestIndexedTextFields(t *testing.T) {
	// conversation: id + title only (not the system prompt — indexing it
	// would make every conversation match on boilerplate).
	got := indexedText("conversation", "conv-1",
		[]byte(`{"title":"Spike solution","systemPrompt":"frozen prefix"}`))
	if !strings.Contains(got, "conv-1") || !strings.Contains(got, "Spike solution") {
		t.Fatalf("conversation text missing id/title: %q", got)
	}
	if strings.Contains(got, "frozen") {
		t.Fatalf("conversation text indexed the system prompt: %q", got)
	}
	// message: id + every string under content, array-of-blocks shape.
	got = indexedText("message", "conv-1:000001", []byte(
		`{"role":"assistant","content":[{"type":"text","text":"hello retry policy"},{"type":"tool_use","name":"bash"}]}`))
	if !strings.Contains(got, "retry policy") || !strings.Contains(got, "hello") {
		t.Fatalf("message text missed content strings: %q", got)
	}
	// message: plain string content.
	got = indexedText("message", "c:2", []byte(`{"content":"plain body"}`))
	if !strings.Contains(got, "plain body") {
		t.Fatalf("message text missed string content: %q", got)
	}
	// any other kind: id only.
	got = indexedText("component", "bash", []byte(`{"binary":"/bin/sh","note":"spawn"}`))
	if got != "bash" {
		t.Fatalf("non-indexed kind text = %q, want just the id", got)
	}
	// budget: a huge message is capped, never split mid-rune.
	big := strings.Repeat("あいうえお", 4000) // 5 runes * 3 bytes * 4000
	got = indexedText("message", "c:3", []byte(fmt.Sprintf(`{"content":%q}`, big)))
	if len(got) > searchTextCap+3 {
		t.Fatalf("indexed text not capped: %d bytes", len(got))
	}
	if !utf8.ValidString(got) {
		t.Fatalf("capped text ends mid-rune: %q", got[len(got)-10:])
	}
}

func TestSearchFindUpdateDelete(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	search := searchHandler(db.DB)

	mustOK(t, call(t, put, `{"kind":"conversation","id":"conv-aaa","value":{"title":"Spike solution for JEV"}}`))
	mustOK(t, call(t, put, `{"kind":"conversation","id":"conv-bbb","value":{"title":"Check the PRs"}}`))

	// match by title token prefix, case-insensitively
	ids := searchIDs(t, call(t, search, `{"kind":"conversation","query":"spike"}`))
	if len(ids) != 1 || ids[0] != "conv-aaa" {
		t.Fatalf("title search = %v, want [conv-aaa]", ids)
	}
	// match by id token
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"conv-b"}`))
	if len(ids) != 1 || ids[0] != "conv-bbb" {
		t.Fatalf("id search = %v, want [conv-bbb]", ids)
	}
	// AND across tokens from one query
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"check prs"}`))
	if len(ids) != 1 || ids[0] != "conv-bbb" {
		t.Fatalf("AND search = %v, want [conv-bbb]", ids)
	}
	// prefix beats whole word: "jev" matches "JEV", "sol" matches "solution"
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"jev"}`))
	if len(ids) != 1 || ids[0] != "conv-aaa" {
		t.Fatalf("prefix search = %v, want [conv-aaa]", ids)
	}

	// update: the old title leaves the index in the same write
	mustOK(t, call(t, put,
		`{"kind":"conversation","id":"conv-aaa","value":{"title":"Tokyo trip notes"}}`))
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"spike"}`))
	if len(ids) != 0 {
		t.Fatalf("stale title still indexed: %v", ids)
	}
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"tokyo"}`))
	if len(ids) != 1 || ids[0] != "conv-aaa" {
		t.Fatalf("updated title not indexed: %v", ids)
	}

	// del: unfindable immediately (indexed fields follow the kind — a
	// conversation's title is what a title search matches)
	mustOK(t, call(t, put, `{"kind":"conversation","id":"conv-del","value":{"title":"ephemeral zebra"}}`))
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"zebra"}`))
	if len(ids) != 1 || ids[0] != "conv-del" {
		t.Fatalf("setup for delete failed: %v", ids)
	}
	mustOK(t, call(t, delHandler(db.DB), `{"kind":"conversation","id":"conv-del"}`))
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"zebra"}`))
	if len(ids) != 0 {
		t.Fatalf("deleted doc still indexed: %v", ids)
	}
}

func TestSearchNoMatchAndBadQuery(t *testing.T) {
	db := newTestDB(t)
	mustOK(t, call(t, putHandler(db.DB), `{"kind":"conversation","id":"conv-1","value":{"title":"alpha"}}`))
	search := searchHandler(db.DB)

	// no match: ok with an empty list, never an error
	out := mustOK(t, call(t, search, `{"kind":"conversation","query":"nothingmatchesthis"}`))
	items, _ := out["items"].([]map[string]any)
	if len(items) != 0 || out["hasMore"] != false {
		t.Fatalf("no-match result = %v, want empty items + hasMore false", out)
	}
	// query with no letters or digits: explicit bad-request
	mustFail(t, call(t, search, `{"kind":"conversation","query":"%;_\"'"}`), "bad-request")
	// empty query: same
	mustFail(t, call(t, search, `{"kind":"conversation","query":"   "}`), "bad-request")
}

func TestSearchSpecialCharactersAreInert(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	search := searchHandler(db.DB)
	mustOK(t, call(t, put, `{"kind":"conversation","id":"conv-1","value":{"title":"fts5 AND/OR syntax"}}`))
	mustOK(t, call(t, put, `{"kind":"conversation","id":"conv-2","value":{"title":"ordinary title"}}`))

	// Operator-looking input is just separators: `OR` still ANDs.
	ids := searchIDs(t, call(t, search, `{"kind":"conversation","query":"fts5 OR nothingmatchesthis"}`))
	if len(ids) != 0 {
		t.Fatalf("OR in query acted as an operator: %v", ids)
	}
	// FTS5 column-filter syntax (kind:...) can't be smuggled in: ':' is a
	// separator, so this is the two tokens "kind" and "alpha".
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"kind:alpha"}`))
	if len(ids) != 0 {
		t.Fatalf("column syntax leaked into the match: %v", ids)
	}
	// Punctuation-only input tokenizes to nothing: explicit bad-request,
	// never an accidental "match everything".
	mustFail(t, call(t, search, fmt.Sprintf(`{"kind":"conversation","query":%q}`, `"'%`)), "bad-request")
	// …and the words inside a punctuated query still AND together.
	ids = searchIDs(t, call(t, search, fmt.Sprintf(`{"kind":"conversation","query":%q}`, `"fts5"`)))
	if len(ids) != 1 || ids[0] != "conv-1" {
		t.Fatalf("quoted word search = %v, want [conv-1]", ids)
	}
}

func TestSearchPaginationAndOrder(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	for i := 0; i < 25; i++ {
		id := fmt.Sprintf("conv-%03d", i)
		title := "match " + id
		if i%5 == 0 {
			title = "other title" // every 5th does not match
		}
		mustOK(t, call(t, put, fmt.Sprintf(
			`{"kind":"conversation","id":%q,"value":{"title":%q}}`, id, title)))
	}
	search := searchHandler(db.DB)
	var got []string
	after := ""
	for page := 0; page < 10; page++ {
		args := fmt.Sprintf(`{"kind":"conversation","query":"match","limit":7,"after":%q}`, after)
		out := mustOK(t, call(t, search, args))
		items, _ := out["items"].([]map[string]any)
		for _, it := range items {
			got = append(got, it["id"].(string))
		}
		if out["hasMore"] != true {
			break
		}
		next, _ := out["nextAfter"].(string)
		if next == "" {
			t.Fatalf("hasMore without nextAfter: %v", out)
		}
		if next != items[len(items)-1]["id"].(string) {
			t.Fatalf("nextAfter %q != last item id", next)
		}
		after = next
	}
	if len(got) != 20 { // 25 minus the 5 non-matching
		t.Fatalf("paged total = %d (%v), want 20", len(got), got)
	}
	for i := 1; i < len(got); i++ {
		if !(got[i-1] < got[i]) {
			t.Fatalf("results not in ascending id order: %v", got)
		}
	}
	// limit is capped at 1000, like list
	out := mustOK(t, call(t, search, `{"kind":"conversation","query":"match","limit":99999}`))
	items, _ := out["items"].([]map[string]any)
	if len(items) > 1000 {
		t.Fatalf("limit cap ignored: %d items", len(items))
	}
}

func TestSearchMessageContent(t *testing.T) {
	db := newTestDB(t)
	put := putHandler(db.DB)
	search := searchHandler(db.DB)
	mustOK(t, call(t, put,
		`{"kind":"message","id":"conv-x:000001","value":{"role":"user","content":"where did we discuss the retry policy?"}}`))
	mustOK(t, call(t, put,
		`{"kind":"message","id":"conv-x:000002","value":{"role":"assistant","content":[{"type":"text","text":"we settled on three attempts"}]}}`))
	ids := searchIDs(t, call(t, search, `{"kind":"message","query":"retry policy"}`))
	if len(ids) != 1 || ids[0] != "conv-x:000001" {
		t.Fatalf("message search = %v, want [conv-x:000001]", ids)
	}
	ids = searchIDs(t, call(t, search, `{"kind":"message","query":"attempts"}`))
	if len(ids) != 1 || ids[0] != "conv-x:000002" {
		t.Fatalf("block-content search = %v, want [conv-x:000002]", ids)
	}
	// a conversation search never sees message rows (kind is the filter)
	ids = searchIDs(t, call(t, search, `{"kind":"conversation","query":"attempts"}`))
	if len(ids) != 0 {
		t.Fatalf("kind filter leaked: %v", ids)
	}
}

func TestSearchIndexRebuildOnDisagreement(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NIF_ROOT", root)
	db, err := openStore()
	if err != nil {
		t.Fatalf("openStore: %v", err)
	}
	mustOK(t, call(t, putHandler(db.DB),
		`{"kind":"conversation","id":"conv-r","value":{"title":"rebuild me"}}`))

	// Corrupt the derived index: drop its rows behind the store's back —
	// exactly the state a crash or manual edit can leave.
	if _, err := db.Exec(`DELETE FROM docs_fts`); err != nil {
		t.Fatalf("corrupt index: %v", err)
	}
	// A search against the damaged index finds nothing (index is
	// authoritative for reads within a run only after startup sync).
	out := mustOK(t, call(t, searchHandler(db.DB), `{"kind":"conversation","query":"rebuild"}`))
	if items, _ := out["items"].([]map[string]any); len(items) != 0 {
		t.Fatalf("expected empty result before rebuild: %v", out)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: syncSearchIndex must notice (count mismatch) and rebuild.
	db, err = openStore()
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer db.Close()
	out = mustOK(t, call(t, searchHandler(db.DB), `{"kind":"conversation","query":"rebuild"}`))
	items, _ := out["items"].([]map[string]any)
	if len(items) != 1 || items[0]["id"].(string) != "conv-r" {
		t.Fatalf("index not rebuilt on reopen: %v", out)
	}

	// In-sync restart does NOT rebuild: counts equal → sync returns false.
	rebuilt, err := syncSearchIndex(db.DB)
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if rebuilt {
		t.Fatalf("in-sync index was rebuilt anyway")
	}
}
