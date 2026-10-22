package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestInstanceArgumentValidation(t *testing.T) {
	register := instanceRegisterHandler(nil)
	for _, raw := range []string{
		`{}`, `null`, `[]`, `{"instanceId":12}`,
		`{"instanceId":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","name":"x","root":"/x","gitHash":""}`,
		`{"instanceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"x","root":"/x","gitHash":"","unknown":true}`,
		`{"instanceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":null,"root":"/x","gitHash":""}`,
		`{"instanceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"bad\nname","root":"/x","gitHash":""}`,
		`{"instanceId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"` + strings.Repeat("x", 256) + `","root":"/x","gitHash":""}`,
	} {
		mustFail(t, call(t, register, raw), "bad-request")
	}
	list := instanceListHandler(nil)
	for _, raw := range []string{`{"limit":0}`, `{"limit":1001}`, `{"limit":"2"}`, `{"after":"bad"}`, `{"unknown":true}`, `{} {}`} {
		mustFail(t, call(t, list, raw), "bad-request")
	}
	if !validInstanceID("0123456789abcdef0123456789abcdef") || validInstanceID("bad") {
		t.Fatal("identity validation drift")
	}
	for _, write := range []bool{false, true} {
		schema := instanceSchema(write)
		if schema["x-harness"].(map[string]any)["hidden"] != true {
			t.Fatal("registry tools must be hidden")
		}
	}
}

func TestInstanceRegistryAPI(t *testing.T) {
	db := newTestDB(t).DB
	const a = "17925200000000000000000000000011"
	const b = "17925200000000000000000000000012"
	for _, id := range []string{a, b} {
		if _, err := db.Exec(`DELETE FROM instances WHERE instance_id=?`, id); err != nil {
			t.Fatal(err)
		}
		id := id
		t.Cleanup(func() {
			_, err := db.Exec(`DELETE FROM instances WHERE instance_id=?`, id)
			if err != nil {
				t.Error(err)
			}
		})
	}
	register := instanceRegisterHandler(db)
	list := instanceListHandler(db)
	for _, id := range []string{b, a} {
		args, _ := json.Marshal(map[string]any{"instanceId": id, "name": "same label", "root": "/same/root", "gitHash": ""})
		mustOK(t, call(t, register, string(args)))
	}
	// Pin an old timestamp without sleeping: refresh must preserve it exactly.
	if _, err := db.Exec(`UPDATE instances SET first_seen='2001-01-01 00:00:00',last_seen='2001-01-01 00:00:00' WHERE instance_id=?`, a); err != nil {
		t.Fatal(err)
	}
	mustOK(t, call(t, register, `{"instanceId":"`+a+`","name":"renamed","root":"/moved","gitHash":"abc"}`))
	page := mustOK(t, call(t, list, `{"after":"17925200000000000000000000000010","limit":1}`))
	rows := page["items"].([]map[string]any)
	if len(rows) != 1 || rows[0]["instanceId"] != a || page["hasMore"] != true || page["nextAfter"] != a {
		t.Fatalf("first page: %v", page)
	}
	if rows[0]["name"] != "renamed" || !strings.HasPrefix(rows[0]["firstSeen"].(string), "2001-01-01") || strings.HasPrefix(rows[0]["lastSeen"].(string), "2001-01-01") {
		t.Fatalf("refresh: %v", rows[0])
	}
	next := mustOK(t, call(t, list, `{"after":"`+a+`","limit":1}`))
	rows = next["items"].([]map[string]any)
	// In TiDB a test database may contain other unrelated instances. Restrict
	// the boundary assertion to our known adjacent fixtures.
	if len(rows) != 1 || rows[0]["instanceId"] != b {
		t.Fatalf("second page: %v", next)
	}
	empty := mustOK(t, call(t, list, `{"after":"ffffffffffffffffffffffffffffffff"}`))
	if len(empty["items"].([]map[string]any)) != 0 || empty["hasMore"] != false {
		t.Fatalf("empty page: %v", empty)
	}
}
