// store-tidb component — persistence as a bus service (TiDB engine).
//
// The third engine implementing the store bus contract (put/get/list/del,
// expectRev optimistic concurrency, id-ordered lists) — M4 from
// docs/research/STORE_V2.md. Speaks the MySQL protocol via
// go-sql-driver/mysql, so it serves TiDB (the target: a shared network
// store many harnesses can serve from) and plain MySQL 8 alike. The
// contract is the artifact: result shapes are identical to the barrel and
// sqlite engines; all engines register as component "store" and selection
// is the boot-time NIF_STORE_BACKEND switch.
//
// Unlike the file-backed engines there is no flock: the database is
// network state shared by design — two harnesses pointing at one TiDB is
// a feature, and correctness rests on row locking (pessimistic SELECT ...
// FOR UPDATE in the upsert path) and single-statement compare-and-set,
// never on process exclusivity. Exactly ONE store process should still
// serve a given bus (queue-group flapping is a bus-level rule), but the
// data itself is safe under multiple writers.
//
// ---------------------------------------------------------------------------
// Why MEDIUMTEXT and not the native JSON column
//
// TiDB/MySQL offer a binary JSON type with server-side json_extract,
// generated columns and expression indexes — seemingly "more powerful"
// than opaque TEXT. For this contract the TEXT approach is deliberately
// kept, for three concrete reasons:
//
//  1. Fidelity. The contract stores arbitrary consumer-owned JSON.
//     MySQL's binary JSON normalizes documents: object keys are sorted
//     (insertion order is not preserved), duplicate keys collapse, and
//     numbers become INT64/UINT64/DOUBLE — a value like 1.500 comes back
//     as 1.5 and any integer beyond 64-bit loses precision. The barrel
//     and sqlite engines return what the caller put in; a network store
//     silently rewriting documents would be the odd one out.
//  2. Engine symmetry. The same verbatim-TEXT schema runs on sqlite
//     (JSON1 available), TiDB and MySQL — one migration shape, one
//     mental model, datasets move between engines unchanged.
//  3. The power is still reachable. When a query earns an index, add a
//     goose migration with a generated column over the TEXT — e.g.
//     `role VARCHAR(64) AS (json_extract(value, '$.role'))` (VIRTUAL)
//     plus a secondary index — which TiDB and MySQL 8 both support.
//     Query acceleration without giving up verbatim storage: the raw
//     document stays the single source of truth.
//
// If a future consumer needs byte-normalized, server-validated JSON as
// the *storage* format, that is a new kind with its own column — not a
// retrofit of this table.
package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/pressly/goose/v3"

	sdk "niffler.dev/sdk"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const (
	dsnEnv  = "NIF_STORE_TIDB_DSN" // e.g. root@tcp(127.0.0.1:4000)/niffler
	listCap = 1000                 // hard cap on list limit, as in the other engines
)

func main() {
	db, err := openStore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "store-tidb:", err)
		os.Exit(1)
	}
	defer func() { _ = db.Close() }()

	comp := sdk.New("store", "0.1.0")
	comp.
		Tool("put", putSchema(), putHandler(db)).
		Tool("get", getSchema(), getHandler(db)).
		Tool("list", listSchema(), listHandler(db)).
		Tool("del", delSchema(), delHandler(db)).
		Tool("selftest", selfTestSchema(), selfTestHandler(db, "tidb")).
		OnDrain(func(c *sdk.Component) { _ = db.Close() })
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "store-tidb:", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// self test (docs/WIRE.md "Self tests"): the hidden tool /doctor fans out to.
// A real put/get/rev/list/del roundtrip on a throwaway document, deleted
// afterwards — the same shape the barrel engine's selftest uses, so every
// store engine advertises identical tools (docs/MANUAL.md "Store engines").

func selfTestSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"deep": map[string]any{"type": "boolean",
				"description": "Thorough mode: live end-to-end probes (may spawn processes)"},
		},
		"description": "Component self test (hidden — used by /doctor): check the component's own wiring and report per-check results",
		"x-harness":   map[string]any{"hidden": true},
	}
}

func selfTestHandler(db *sql.DB, engine string) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		checks := make([]map[string]any, 0, 4)
		allOK := true
		check := func(name string, ok bool, detail string, t0 time.Time) {
			if !ok {
				allOK = false
			}
			checks = append(checks, map[string]any{
				"name": name, "ok": ok, "detail": detail,
				"ms": int(time.Since(t0).Milliseconds()),
			})
		}
		kind := "selftest"
		id := fmt.Sprintf("probe-%d-%d", os.Getpid(), time.Now().UnixNano())
		value := `{"hello":"selftest","n":42}`

		t := time.Now()
		if err := db.Ping(); err != nil {
			check("connect", false, err.Error(), t)
		} else {
			check("connect", true, "database reachable ("+engine+")", t)
		}

		t = time.Now()
		inserted := false
		if _, err := db.Exec(
			`INSERT INTO docs (kind, id, rev, value, updated_at)
			 VALUES (?, ?, 1, ?, NOW())`, kind, id, value); err == nil {
			inserted = true
			check("put", true, "throwaway document written at rev 1", t)
		} else {
			check("put", false, err.Error(), t)
		}

		t = time.Now()
		var got string
		var rev int64
		if err := db.QueryRow(`SELECT rev, value FROM docs WHERE kind = ? AND id = ?`,
			kind, id).Scan(&rev, &got); err == nil {
			check("get+rev", got == value && rev == 1,
				fmt.Sprintf("read back verbatim at rev %d", rev), t)
		} else {
			check("get+rev", false, err.Error(), t)
		}

		t = time.Now()
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM docs WHERE kind = ?`, kind).
			Scan(&n); err == nil {
			check("list prefix", n >= 1 && inserted,
				fmt.Sprintf("%d document(s) visible under the kind prefix", n), t)
		} else {
			check("list prefix", false, err.Error(), t)
		}

		t = time.Now()
		if _, err := db.Exec(`DELETE FROM docs WHERE kind = ? AND id = ?`,
			kind, id); err != nil {
			check("del", false, err.Error(), t)
		} else {
			var left int
			_ = db.QueryRow(`SELECT COUNT(*) FROM docs WHERE kind = ? AND id = ?`,
				kind, id).Scan(&left)
			check("del", left == 0, "document and revision gone", t)
		}

		summary := "engine roundtrip ok (" + engine + ")"
		if !allOK {
			summary = "engine roundtrip FAILED (" + engine + ")"
		}
		return map[string]any{"ok": allOK, "summary": summary, "checks": checks}, nil
	}
}

// ---------------------------------------------------------------------------
// open + migrate

func openStore() (*sql.DB, error) {
	dsn := os.Getenv(dsnEnv)
	if dsn == "" {
		return nil, fmt.Errorf("%s not set (e.g. %q) — the TiDB engine has no local default: "+
			"the database is network state, point the DSN at your cluster", dsnEnv,
			"root@tcp(127.0.0.1:4000)/niffler")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		return nil, fmt.Errorf("bad %s: %w", dsnEnv, err)
	}
	// Matched-rows semantics: the CAS UPDATE must report 0 when no row
	// MATCHED (absent or rev mismatch) — MySQL's default counts only rows
	// actually CHANGED, which would hide a same-value conflict.
	cfg.ClientFoundRows = true
	cfg.Timeout = 5 * time.Second
	cfg.ReadTimeout = 60 * time.Second
	cfg.WriteTimeout = 30 * time.Second
	// Deterministic NOW() across hosts: force a UTC session unless the DSN
	// explicitly picks a zone (chetter's rule — explicit choice is never
	// overridden). updated_at is informational, but consistency is free.
	if _, ok := cfg.Params["time_zone"]; !ok {
		if cfg.Params == nil {
			cfg.Params = map[string]string{}
		}
		cfg.Params["time_zone"] = "'+00:00'"
	}

	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		return nil, fmt.Errorf("open tidb: %w", err)
	}
	// Serialized tool handlers make one connection plenty; one connection
	// also keeps the FOR UPDATE transaction's statements on one session.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(10 * time.Minute)
	if err := migrate(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func migrate(db *sql.DB) error {
	dir, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("migration fs: %w", err)
	}
	provider, err := goose.NewProvider(goose.DialectMySQL, db, dir)
	if err != nil {
		return fmt.Errorf("goose provider: %w", err)
	}
	applied, err := provider.Up(context.Background())
	if err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	for _, m := range applied {
		fmt.Println("store-tidb: applied migration", m.Source.Path)
	}
	return nil
}

// ---------------------------------------------------------------------------
// arg decoding — lenient like the other engines' argString/argInt (a
// wrong-typed or missing value falls back to the default, it never errors)

func parseArgs(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func rawString(m map[string]json.RawMessage, key string) string {
	if v, ok := m[key]; ok {
		var s string
		if json.Unmarshal(v, &s) == nil {
			return s
		}
	}
	return ""
}

func rawInt(m map[string]json.RawMessage, key string) int64 {
	if v, ok := m[key]; ok {
		var n int64
		if json.Unmarshal(v, &n) == nil {
			return n
		}
	}
	return 0
}

// sessionID extracts the runner-injected __session.session marker
// (x-harness.sessionId): non-empty means the caller is a conversation
// session, not a direct bus caller (core, cli, tests).
func sessionID(m map[string]json.RawMessage) string {
	if v, ok := m["__session"]; ok {
		var s struct {
			Session string `json:"session"`
		}
		if json.Unmarshal(v, &s) == nil {
			return s.Session
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// put

func putSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind": map[string]any{"type": "string",
				"description": "Document kind. From a session only curated kinds are writable: 'fabricprog' (programs fabric runs by name)."},
			"id": map[string]any{"type": "string",
				"description": "Document id within the kind (fabricprog: the program name)"},
			"value": map[string]any{"type": "object",
				"description": "The document body (any JSON). fabricprog entries: {code: <program source>}"},
			"expectRev": map[string]any{"type": "integer",
				"description": "Require this current revision, or fail with rev-conflict (default 0 = upsert)"},
		},
		"required": []string{"kind", "id", "value"},
		"description": "Save a document into the store. From a session this writes the model-curated program library " +
			"(kind fabricprog — code of fabric programs, run them with the fabric tool's name parameter; list what " +
			"exists with store list). Other kinds are harness-managed and rejected from sessions.",
		"x-harness": map[string]any{"onDemand": true, "sessionId": true},
	}
}

func putHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad put args: %w", err)
		}
		kind := rawString(m, "kind")
		id := rawString(m, "id")
		value, hasValue := m["value"]
		expectRev := rawInt(m, "expectRev")

		// Session scoping, mirrored from the other engines: the harness
		// manages its own kinds (conversation, message, component, ...);
		// a session may only curate the model-owned program library so no
		// live session can corrupt transcripts or component records.
		// Direct bus callers (cli, tests, core) carry no session and keep
		// full access.
		if sessionID(m) != "" && kind != "fabricprog" {
			return sdk.ErrCode("sessions may only put curated kinds (fabricprog); '"+
				kind+"' is harness-managed", "forbidden-kind"), nil
		}
		// The barrel engine dies on a missing value ($nil JSON) — this
		// engine returns the failure instead of crashing the handler.
		if !hasValue {
			return nil, fmt.Errorf("put needs kind, id and value")
		}
		if !json.Valid(value) {
			return nil, fmt.Errorf("put value must be valid JSON")
		}

		if expectRev > 0 {
			// Compare-and-set: one atomic statement; 0 matched rows means
			// absent or rev mismatch (ClientFoundRows makes RowsAffected
			// count matched, not changed, rows). A follow-up read tells
			// the two cases apart, as in the other engines.
			res, err := db.Exec(
				`UPDATE docs SET rev = rev + 1, value = ?, updated_at = NOW()
				 WHERE kind = ? AND id = ? AND rev = ?`,
				string(value), kind, id, expectRev)
			if err != nil {
				return nil, fmt.Errorf("put: %w", err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				var cur int64
				switch err := db.QueryRow(
					`SELECT rev FROM docs WHERE kind = ? AND id = ?`, kind, id).Scan(&cur); err {
				case sql.ErrNoRows:
					return sdk.ErrCode("not found", "rev-conflict"), nil
				case nil:
					return map[string]any{"ok": false, "error": "rev conflict",
						"code": "rev-conflict", "currentRev": cur}, nil
				default:
					return nil, fmt.Errorf("put: %w", err)
				}
			}
			return sdk.OK(map[string]any{"rev": expectRev + 1}), nil
		}

		// Upsert under a row lock (pessimistic transactions, the TiDB
		// default): read the current rev FOR UPDATE, then insert at 1 or
		// bump. Doc and revision still move atomically; two harnesses
		// sharing this store serialize on the row lock.
		tx, err := db.BeginTx(context.Background(), nil)
		if err != nil {
			return nil, fmt.Errorf("put: %w", err)
		}
		var cur int64
		switch err := tx.QueryRow(
			`SELECT rev FROM docs WHERE kind = ? AND id = ? FOR UPDATE`,
			kind, id).Scan(&cur); err {
		case sql.ErrNoRows:
			if _, err := tx.Exec(
				`INSERT INTO docs (kind, id, rev, value, updated_at)
				 VALUES (?, ?, 1, ?, NOW())`,
				kind, id, string(value)); err != nil {
				_ = tx.Rollback()
				return nil, fmt.Errorf("put: %w", err)
			}
			cur = 0 // fresh insert → new rev 1
		case nil:
			if _, err := tx.Exec(
				`UPDATE docs SET rev = rev + 1, value = ?, updated_at = NOW()
				 WHERE kind = ? AND id = ?`,
				string(value), kind, id); err != nil {
				_ = tx.Rollback()
				return nil, fmt.Errorf("put: %w", err)
			}
		default:
			_ = tx.Rollback()
			return nil, fmt.Errorf("put: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("put: %w", err)
		}
		return sdk.OK(map[string]any{"rev": cur + 1}), nil
	}
}

// ---------------------------------------------------------------------------
// get

func getSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind": map[string]any{"type": "string",
				"description": "Document kind"},
			"id": map[string]any{"type": "string",
				"description": "Document id within the kind"},
		},
		"required": []string{"kind", "id"},
		"description": "Fetch a stored document by kind and id. Read-only. Kinds in use: conversation " +
			"(id conv-*), message (id <convId>:<n>), component (id <name>). " +
			"Returns {ok, rev, value} or ok:false not-found.",
		"x-harness": map[string]any{"onDemand": true},
	}
}

func getHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad get args: %w", err)
		}
		var rev int64
		var value []byte
		switch err := db.QueryRow(
			`SELECT rev, value FROM docs WHERE kind = ? AND id = ?`,
			rawString(m, "kind"), rawString(m, "id")).Scan(&rev, &value); err {
		case sql.ErrNoRows:
			return sdk.ErrCode("not found", "not-found"), nil
		case nil:
			return sdk.OK(map[string]any{"rev": rev, "value": json.RawMessage(value)}), nil
		default:
			return nil, fmt.Errorf("get: %w", err)
		}
	}
}

// ---------------------------------------------------------------------------
// list

func listSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind": map[string]any{"type": "string",
				"description": "Document kind"},
			"idPrefix": map[string]any{"type": "string",
				"description": "Only items whose id starts with this"},
			"limit": map[string]any{"type": "integer",
				"description": "Max items (default 100, cap 1000)"},
			"after": map[string]any{"type": "string",
				"description": "Exclusive id cursor from a previous page (default = first page)"},
		},
		"required": []string{"kind"},
		"description": "List stored documents of a kind, ordered by id, optionally id-prefix filtered. " +
			"Read-only. Enumerate conversations (kind conversation) or one conversation's messages " +
			"(kind message, idPrefix <convId>:). Returns {ok, items: [{id, rev, value}], hasMore, nextAfter?}" +
			" — pass nextAfter back as `after` to page past the 1000-item cap.",
		"x-harness": map[string]any{"onDemand": true},
	}
}

// likeEscape neutralizes LIKE metacharacters in a caller-owned id prefix
// (%, _ and the escape char), same as the other engines. The columns are
// utf8mb4_bin, so matching and ordering are byte-exact.
func likeEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `%`, `\%`)
	s = strings.ReplaceAll(s, `_`, `\_`)
	return s
}

func listHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad list args: %w", err)
		}
		kind := rawString(m, "kind")
		prefix := rawString(m, "idPrefix")
		after := rawString(m, "after")
		limit := rawInt(m, "limit")
		if limit == 0 {
			limit = 100 // default when absent, as in the other engines
		}
		// Cap, and mirror the barrel engine's critbit bound (any limit < 1
		// yields one item there — see the sqlite engine's header note).
		if limit > listCap {
			limit = listCap
		}
		if limit < 1 {
			limit = 1
		}
		// Exclusive id cursor (barrel's keysByPrefix has the same semantics:
		// `id <= after` is skipped). ORDER BY id matches the barrel engine's
		// key order, so paging is stable across every engine.
		query := `SELECT id, rev, value FROM docs
			 WHERE kind = ? AND id LIKE ? ESCAPE '\\' ORDER BY id LIMIT ?`
		qargs := []any{kind, likeEscape(prefix) + "%", limit}
		if after != "" {
			query = `SELECT id, rev, value FROM docs
			 WHERE kind = ? AND id LIKE ? ESCAPE '\\' AND id > ? ORDER BY id LIMIT ?`
			qargs = []any{kind, likeEscape(prefix) + "%", after, limit}
		}
		rows, err := db.Query(query, qargs...)
		if err != nil {
			return nil, fmt.Errorf("list: %w", err)
		}
		defer rows.Close()
		items := []map[string]any{} // non-nil: marshals as [] when empty
		for rows.Next() {
			var id string
			var rev int64
			var value []byte
			if err := rows.Scan(&id, &rev, &value); err != nil {
				return nil, fmt.Errorf("list: %w", err)
			}
			items = append(items, map[string]any{
				"id": id, "rev": rev, "value": json.RawMessage(value),
			})
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("list: %w", err)
		}
		// hasMore mirrors barrel's "the page came back full" bound: a full
		// page may have successors, so the caller fetches one more page and
		// stops when it is empty. nextAfter is present only when another
		// page may exist.
		hasMore := int64(len(items)) >= limit
		out := map[string]any{"items": items, "hasMore": hasMore}
		if hasMore && len(items) > 0 {
			out["nextAfter"] = items[len(items)-1]["id"]
		}
		return sdk.OK(out), nil
	}
}

// ---------------------------------------------------------------------------
// del

func delSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"kind": map[string]any{"type": "string",
				"description": "Document kind"},
			"id": map[string]any{"type": "string",
				"description": "Document id within the kind"},
		},
		"required": []string{"kind", "id"},
		"description": "Delete a document. Hidden from the LLM: deletes are made by core " +
			"(e.g. core.remove dropping a component record).",
		"x-harness": map[string]any{"hidden": true},
	}
}

func delHandler(db *sql.DB) sdk.ToolHandler {
	return func(c *sdk.Component, args json.RawMessage) (any, error) {
		m, err := parseArgs(args)
		if err != nil {
			return nil, fmt.Errorf("bad del args: %w", err)
		}
		// Idempotent, as in the other engines. The row (doc + rev) goes as
		// one — a re-put starts fresh at rev 1.
		if _, err := db.Exec(`DELETE FROM docs WHERE kind = ? AND id = ?`,
			rawString(m, "kind"), rawString(m, "id")); err != nil {
			return nil, fmt.Errorf("del: %w", err)
		}
		return sdk.OK(nil), nil
	}
}
