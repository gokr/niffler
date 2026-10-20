package main

import (
	"encoding/json"
	"testing"
)

// A pre-scoping history (owner "") claimed by a different instance: dry run
// first, collisions refuse, and a real claim moves ownership without touching
// revisions or leaving the rows visible to the legacy owner.
func TestClaimMovesLegacyRowsOnly(t *testing.T) {
	db := newTestDB(t)
	const target = "cccccccccccccccccccccccccccccccc"
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM docs WHERE instance_id IN ('','` + target + `') AND kind='claimtest'`)
	})
	for _, id := range []string{"a", "b"} {
		mustOK(t, call(t, putHandler(db.DB), `{"kind":"claimtest","id":"`+id+`","value":{"v":1}}`))
	}
	// The target already owns "a": claiming it would overwrite real data.
	mustOK(t, call(t, putHandler(db.DB, target), `{"kind":"claimtest","id":"a","value":{"v":9}}`))

	h := claimHandler(db.DB)
	dry := mustOK(t, call(t, h, `{"to":"`+target+`"}`))
	if dry["dryRun"] != true || dry["examined"].(int) != 2 {
		t.Fatalf("dry run: %v", dry)
	}
	if got := dry["conflicts"].([]string); len(got) != 1 || got[0] != "claimtest/a" {
		t.Fatalf("conflicts: %v", dry["conflicts"])
	}
	mustFail(t, call(t, h, `{"to":"`+target+`","dryRun":false}`), "claim-conflict")

	// Resolve the collision the operator's way, then claim for real.
	mustOK(t, call(t, delHandler(db.DB, target), `{"kind":"claimtest","id":"a"}`))
	done := mustOK(t, call(t, h, `{"to":"`+target+`","dryRun":false}`))
	if done["claimed"].(int) != 2 {
		t.Fatalf("claimed: %v", done)
	}
	// Rows are now the target's, at the same revision, and invisible to "".
	own := mustOK(t, call(t, getHandler(db.DB, target), `{"kind":"claimtest","id":"a"}`))
	if own["rev"].(int64) != 1 {
		t.Fatalf("claim changed the revision: %v", own)
	}
	mustFail(t, call(t, getHandler(db.DB), `{"kind":"claimtest","id":"b"}`), "not-found")

	// Bad targets refuse before touching anything.
	mustFail(t, call(t, h, `{"to":"nope"}`), "bad-request")
}

func TestClaimIsBoundedAndResumable(t *testing.T) {
	db := newTestDB(t)
	const target = "dddddddddddddddddddddddddddddddd"
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM docs WHERE instance_id=? AND kind='claimpage'`, target)
		_, _ = db.Exec(`DELETE FROM docs WHERE instance_id='' AND kind='claimpage'`)
	})
	for _, id := range []string{"p1", "p2", "p3"} {
		mustOK(t, call(t, putHandler(db.DB), `{"kind":"claimpage","id":"`+id+`","value":{}}`))
	}
	h := claimHandler(db.DB)
	first := mustOK(t, call(t, h, `{"to":"`+target+`","dryRun":false,"limit":2}`))
	if first["claimed"].(int) != 2 || first["hasMore"] != true {
		t.Fatalf("first batch: %v", first)
	}
	next, _ := json.Marshal(map[string]any{
		"to": target, "dryRun": false, "limit": 2,
		"afterKind": first["nextAfterKind"], "afterId": first["nextAfterId"]})
	second := mustOK(t, call(t, h, string(next)))
	if second["claimed"].(int) != 1 || second["hasMore"] != false {
		t.Fatalf("second batch: %v", second)
	}
}
