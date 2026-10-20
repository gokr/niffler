package main

// store_claim — the explicit, reported migration of pre-scoping documents
// (instance_id = '') into a real instance. Neither engine adopts legacy rows
// as a side effect of someone connecting; on a shared dataset that would hand
// one instance another's history. This tool is the deliberate operation:
//
//   - it only ever moves rows FROM '' TO a valid identity. Reassigning rows
//     between two real instances is a data move with different rules and is
//     refused here rather than silently allowed;
//   - it refuses a batch that would collide with a document the target
//     already has (same kind and id) instead of overwriting it;
//   - dryRun reports exactly what would move and what collides, so an
//     operator can look before committing;
//   - it is bounded and resumable: batches of at most `limit` documents in
//     (kind, id) order, with an exclusive cursor, because a large history
//     must not become one unbounded transaction.
//
// Approval is required (x-harness.approval): this rewrites ownership of
// someone's history.
import (
	"database/sql"
	"encoding/json"
	"fmt"

	sdk "niffler.dev/sdk"
)

const claimCap = 1000

func claimSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"to": map[string]any{"type": "string",
				"description": "Target instance id (32 lowercase hex) that adopts the unowned documents"},
			"dryRun": map[string]any{"type": "boolean",
				"description": "Report what would move and what collides; change nothing (default true)"},
			"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": claimCap,
				"description": "Documents per batch (default 200)"},
			"afterKind": map[string]any{"type": "string",
				"description": "Resume cursor: last kind of the previous batch"},
			"afterId": map[string]any{"type": "string",
				"description": "Resume cursor: last id of the previous batch"},
		},
		"required": []string{"to"},
		"description": "Admin-only migration of pre-scoping documents (owner '') into one instance. " +
			"Never implicit: adopting rows as a side effect of connecting would hand an instance another " +
			"instance's history. Moves only '' -> instance, refuses collisions with the target's own " +
			"documents, is bounded and resumable, and defaults to a dry run.",
		"x-harness": map[string]any{"hidden": true, "effect": "write", "approval": "always"},
	}
}

func claimHandler(db *sql.DB, self ...string) sdk.ToolHandler {
	bound := documentOwner(self)
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad store_claim args: %w", err)
		}
		target := rawString(m, "to")
		if !validInstanceID(target) {
			return sdk.ErrCode("store_claim needs a valid target instance id (32 lowercase hex)", "bad-request"), nil
		}
		if target == bound {
			return sdk.ErrCode("this store already serves "+target+
				"; claiming legacy rows into the identity you are running as is a no-op", "bad-request"), nil
		}
		dryRun := true
		if v, ok := m["dryRun"]; ok {
			dryRun = rawBool(map[string]json.RawMessage{"dryRun": v}, "dryRun")
		}
		limit := int(rawInt(m, "limit"))
		if limit == 0 {
			limit = 200
		}
		if limit < 1 || limit > claimCap {
			return sdk.ErrCode("limit must be 1..1000", "bad-request"), nil
		}
		afterKind, afterID := rawString(m, "afterKind"), rawString(m, "afterId")

		rows, err := legacyBatch(db, afterKind, afterID, limit)
		if err != nil {
			return nil, err
		}
		conflicts, err := legacyConflicts(db, target, afterKind, afterID, limit)
		if err != nil {
			return nil, err
		}
		out := map[string]any{
			"dryRun": dryRun, "to": target, "examined": len(rows),
			"conflicts": conflicts, "hasMore": len(rows) == limit,
		}
		if len(rows) > 0 {
			out["nextAfterKind"] = rows[len(rows)-1].kind
			out["nextAfterId"] = rows[len(rows)-1].id
		}
		if len(conflicts) > 0 {
			if !dryRun {
				return sdk.ErrCode("refusing to overwrite documents the target already has: "+
					fmt.Sprint(conflicts), "claim-conflict"), nil
			}
			return sdk.OK(out), nil
		}
		if dryRun || len(rows) == 0 {
			return sdk.OK(out), nil
		}
		claimed := 0
		if err := inTx(db, func(tx *sql.Tx) error {
			for _, r := range rows {
				res, err := tx.Exec(
					`UPDATE docs SET instance_id = ? WHERE instance_id = '' AND kind = ? AND id = ?`,
					target, r.kind, r.id)
				if err != nil {
					return fmt.Errorf("claim %s/%s: %w", r.kind, r.id, err)
				}
				n, _ := res.RowsAffected()
				claimed += int(n)
			}
			return nil
		}); err != nil {
			return nil, err
		}
		out["claimed"] = claimed
		return sdk.OK(out), nil
	}
}

type legacyRow struct{ kind, id string }

func legacyBatch(db *sql.DB, afterKind, afterID string, limit int) ([]legacyRow, error) {
	rows, err := db.Query(`SELECT kind, id FROM docs WHERE instance_id = ''
		AND (kind > ? OR (kind = ? AND id > ?)) ORDER BY kind, id LIMIT ?`,
		afterKind, afterKind, afterID, limit)
	if err != nil {
		return nil, fmt.Errorf("store_claim scan: %w", err)
	}
	defer rows.Close()
	out := []legacyRow{}
	for rows.Next() {
		var r legacyRow
		if err := rows.Scan(&r.kind, &r.id); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// legacyConflicts lists unowned documents whose (kind, id) the target already
// owns — claiming those would either fail mid-transaction or overwrite data.
func legacyConflicts(db *sql.DB, target, afterKind, afterID string, limit int) ([]string, error) {
	rows, err := db.Query(`SELECT d.kind, d.id FROM docs d
		JOIN docs t ON t.instance_id = ? AND t.kind = d.kind AND t.id = d.id
		WHERE d.instance_id = ''
		  AND (d.kind > ? OR (d.kind = ? AND d.id > ?))
		ORDER BY d.kind, d.id LIMIT ?`, target, afterKind, afterKind, afterID, limit)
	if err != nil {
		return nil, fmt.Errorf("store_claim conflict scan: %w", err)
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var kind, id string
		if err := rows.Scan(&kind, &id); err != nil {
			return nil, err
		}
		out = append(out, kind+"/"+id)
	}
	return out, rows.Err()
}

func inTx(db *sql.DB, fn func(*sql.Tx) error) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}
