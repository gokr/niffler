// Instance registry infrastructure. Metadata is informational, not routing
// authority or proof of identity. Keep the two store engines wire-identical.
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	sdk "niffler.dev/sdk"
)

func instanceSchema(write bool) map[string]any {
	properties := map[string]any{
		"after": map[string]any{"type": "string", "description": "Exclusive instance ID cursor"},
		"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 1000},
	}
	ext := map[string]any{"hidden": true, "effect": "read"}
	desc := "List informational Niffler instance metadata, ordered by stable identity; not connection authority."
	required := []string{}
	if write {
		properties = map[string]any{}
		for _, key := range []string{"instanceId", "name", "root", "gitHash"} {
			properties[key] = map[string]any{"type": "string"}
		}
		required = []string{"instanceId", "name", "root", "gitHash"}
		ext = map[string]any{"hidden": true, "effect": "write"}
		desc = "Register or refresh informational instance metadata. Internal core infrastructure, not a fleet trust grant. Preserves firstSeen; refreshes lastSeen."
	}
	return map[string]any{"type": "object", "properties": properties, "required": required,
		"additionalProperties": false, "description": desc, "x-harness": ext}
}

func validInstanceID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func decodeInstanceArgs(raw json.RawMessage, dest any) error {
	if !strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		return fmt.Errorf("expected JSON object")
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dest); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return fmt.Errorf("expected one JSON object")
	}
	return nil
}

func instanceRegisterHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			InstanceID *string `json:"instanceId"`
			Name       *string `json:"name"`
			Root       *string `json:"root"`
			GitHash    *string `json:"gitHash"`
		}
		bad := func() (any, error) { return sdk.ErrCode("invalid instance metadata", "bad-request"), nil }
		if err := decodeInstanceArgs(raw, &args); err != nil {
			return bad()
		}
		if args.InstanceID == nil || args.Name == nil || args.Root == nil || args.GitHash == nil || !validInstanceID(*args.InstanceID) {
			return bad()
		}
		for _, field := range []struct {
			value string
			cap   int
		}{{*args.Name, 255}, {*args.Root, 4096}, {*args.GitHash, 64}} {
			if !utf8.ValidString(field.value) || len(field.value) > field.cap || strings.ContainsAny(field.value, "\x00\r\n") {
				return bad()
			}
		}
		// No path resolution: root is metadata about a potentially different host.
		_, err := db.Exec(`INSERT INTO instances(instance_id,name,root,git_hash) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE name=VALUES(name),root=VALUES(root),git_hash=VALUES(git_hash),last_seen=CURRENT_TIMESTAMP`, *args.InstanceID, *args.Name, *args.Root, *args.GitHash)
		if err != nil {
			return nil, fmt.Errorf("instance registration: %w", err)
		}
		return sdk.OK(map[string]any{"instanceId": *args.InstanceID}), nil
	}
}

func instanceListHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, raw json.RawMessage) (any, error) {
		var args struct {
			After string `json:"after"`
			Limit *int   `json:"limit"`
		}
		if err := decodeInstanceArgs(raw, &args); err != nil || (args.After != "" && !validInstanceID(args.After)) {
			return sdk.ErrCode("invalid instance list arguments", "bad-request"), nil
		}
		limit := 100
		if args.Limit != nil {
			limit = *args.Limit
		}
		if limit < 1 || limit > 1000 {
			return sdk.ErrCode("limit must be 1..1000", "bad-request"), nil
		}
		// One lookahead row: hasMore is exact, with the last returned identity as cursor.
		rows, err := db.Query(`SELECT instance_id,name,root,git_hash,CAST(first_seen AS CHAR),CAST(last_seen AS CHAR) FROM instances WHERE instance_id > ? ORDER BY instance_id LIMIT ?`, args.After, limit+1)
		if err != nil {
			return nil, fmt.Errorf("instance list: %w", err)
		}
		defer rows.Close()
		items := []map[string]any{}
		for rows.Next() {
			var id, name, root, hash, first, last string
			if err := rows.Scan(&id, &name, &root, &hash, &first, &last); err != nil {
				return nil, err
			}
			items = append(items, map[string]any{"instanceId": id, "name": name, "root": root, "gitHash": hash, "firstSeen": first, "lastSeen": last})
		}
		if err := rows.Err(); err != nil {
			return nil, err
		}
		more := len(items) > limit
		if more {
			items = items[:limit]
		}
		out := map[string]any{"items": items, "hasMore": more}
		if more {
			out["nextAfter"] = items[len(items)-1]["instanceId"]
		}
		return sdk.OK(out), nil
	}
}
