package main

import (
	"encoding/json"
	"testing"
)

func TestDocumentInstanceIsolation(t *testing.T) {
	db := newTestDB(t)
	a, b := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	for _, owner := range []string{"", a, b} {
		owner := owner
		t.Cleanup(func() {
			for _, id := range []string{"scoped-1", "scoped-2"} {
				_, err := db.Exec(`DELETE FROM docs WHERE instance_id=? AND kind='conversation' AND id=?`, owner, id)
				if err != nil {
					t.Error(err)
				}
			}
		})
	}
	for _, owner := range []string{a, b} {
		for _, id := range []string{"scoped-1", "scoped-2"} {
			mustOK(t, call(t, putHandler(db, owner), `{"kind":"conversation","id":"`+id+`","value":{"title":"scoped searchable `+owner+`"},"expectRev":-1}`))
		}
	}
	mustFail(t, call(t, getHandler(db), `{"kind":"conversation","id":"scoped-1"}`), "not-found")
	mustOK(t, call(t, putHandler(db, a), `{"kind":"conversation","id":"scoped-1","value":{"title":"updated searchable"},"expectRev":1}`))
	mustFail(t, call(t, putHandler(db, a), `{"kind":"conversation","id":"scoped-1","value":{},"expectRev":1}`), "rev-conflict")
	got := mustOK(t, call(t, getHandler(db, b), `{"kind":"conversation","id":"scoped-1"}`))
	if got["rev"].(int64) != 1 {
		t.Fatalf("foreign revision changed: %v", got)
	}
	raw, _ := json.Marshal(got["value"])
	if string(raw) == `{}` {
		t.Fatal("foreign value overwritten")
	}
	page := mustOK(t, call(t, listHandler(db, a), `{"kind":"conversation","idPrefix":"scoped-","limit":1}`))
	if len(page["items"].([]map[string]any)) != 1 || page["nextAfter"] != "scoped-1" {
		t.Fatalf("page: %v", page)
	}
	page = mustOK(t, call(t, listHandler(db, a), `{"kind":"conversation","idPrefix":"scoped-","after":"scoped-1"}`))
	if len(page["items"].([]map[string]any)) != 1 {
		t.Fatalf("cursor: %v", page)
	}
	for _, rank := range []string{"false", "true"} {
		found := mustOK(t, call(t, searchHandler(db, a), `{"kind":"conversation","query":"searchable","idPrefix":"scoped-","rank":`+rank+`,"snippet":true}`))
		if len(found["items"].([]map[string]any)) != 2 {
			t.Fatalf("search crossed scope: %v", found)
		}
	}
	mustOK(t, call(t, delHandler(db, a), `{"kind":"conversation","id":"scoped-1"}`))
	mustFail(t, call(t, getHandler(db, a), `{"kind":"conversation","id":"scoped-1"}`), "not-found")
	mustOK(t, call(t, getHandler(db, b), `{"kind":"conversation","id":"scoped-1"}`))
	found := mustOK(t, call(t, searchHandler(db, b), `{"kind":"conversation","query":"searchable","idPrefix":"scoped-"}`))
	if len(found["items"].([]map[string]any)) != 2 {
		t.Fatalf("delete crossed search scope: %v", found)
	}
	mustOK(t, call(t, selfTestHandler(db, "test", a), `{}`))
}
