// store-sqlite component — persistence as a bus service (SQLite engine).
//
// A second engine implementing the store bus contract (put/get/list/del,
// expectRev optimistic concurrency, id-ordered lists) on SQLite — the M3
// engine from docs/research/STORE_V2.md. The contract is the artifact:
// result shapes mirror components/store/main.nim (the barrel engine)
// exactly, and t_store runs green against both. Storage engine and
// implementation language are private to the component; consumers keep
// speaking envelopes on svc.store.call. All engines register as component
// "store"; selection is a boot-time choice via NIF_STORE_BACKEND in core.
//
// Single-writer discipline is unchanged from the barrel store: exactly ONE
// process owns var/store.db. Every other process talks over the bus, never
// a driver. The flock on var/store.db.lock is the last line of defense —
// a second live store process refuses to boot instead of silently sharing
// the bus (two stores in the "store" queue group would alternate
// inconsistent views). SQLite's own locking (WAL + BEGIN IMMEDIATE +
// busy_timeout) makes the file itself consistent regardless.
//
// ---------------------------------------------------------------------------
// Doc store vs SQLite — why a schema-free document contract fits SQL fine
//
// The store contract is deliberately schema-free: `value` is any JSON
// document, kinds are uninterpreted, and consumers (core, agent, fabric,
// plugins, UIs) own their doc shapes. Conversation headers gain fields,
// the slash table grows keys, new kinds appear — none of that has ever
// needed a store change, and it still doesn't: the document lives as
// opaque JSON TEXT, so a new kind or a new field is just a write. SQLite
// is a *different engine for the same document model*, not a schema
// imposition:
//
//   - JSON stays the contract; SQL wraps it, never replaces it. What SQL
//     adds around the opaque middle is real transactions (doc + rev move
//     in one atomic statement — barrel's two-key write had a crash window
//     between them) and SQL introspection (`sqlite3 var/store.db 'select
//     kind, count(*) from docs group by kind'` instead of strings-carving
//     a barrel file).
//   - Values are stored verbatim (raw bytes in, raw bytes out) — the same
//     semantic JSON the caller sent, with number formats and key order
//     preserved. The barrel engine re-serializes through Nim's JSON;
//     either way consumers parse JSON, so both are contract-identical.
//   - Cross-document questions (which kinds exist? how big is this
//     transcript?) stay on the same path as today — list + client-side
//     filtering. When one is hot enough to push down, SQLite JSON1
//     (json_extract expression indexes) or a promoted real column via a
//     new goose migration is an engine-local change; the wire never moves.
//   - Schema evolution is now a guarded convention: goose migrations
//     (embedded, applied at startup — components must stay
//     zero-manual-steps), not quiet drift.
//
// Deliberate divergences from the barrel engine (both accidental barrel
// behaviors, not contract): tombstones don't exist (a deleted row is gone,
// so list can never see rev-0 ghosts), and list's `limit` — barrel's
// critbit returns one item for limit <= 1 by construction of its
// post-increment bound check; this engine clamps limit into [1, 1000],
// which is byte-identical for every limit >= 1 and saner below.
package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/pressly/goose/v3"
	_ "modernc.org/sqlite" // pure Go, no cgo — keeps the zero-prereq build story

	sdk "niffler.dev/sdk"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

const (
	dbFileName = "store.db" // under <root>/var/
	listCap    = 1000       // hard cap on list limit, as in the barrel engine
)

// storeDB is the open engine: the SQL handle plus its single-writer flock,
// released together on Close. The kernel drops the flock when the process
// dies, so a crash never wedges the store.
type storeDB struct {
	*sql.DB
	lockFd int
}

func (s *storeDB) Close() error {
	err := s.DB.Close()
	if s.lockFd >= 0 {
		_ = syscall.Close(s.lockFd)
		s.lockFd = -1
	}
	return err
}

func main() {
	db, err := openStore()
	if err != nil {
		fmt.Fprintln(os.Stderr, "store-sqlite:", err)
		os.Exit(1)
	}
	defer func() { _ = db.Close() }()

	comp := sdk.New("store", "0.1.0")
	comp.
		Tool("put", putSchema(), putHandler(db.DB)).
		Tool("get", getSchema(), getHandler(db.DB)).
		Tool("list", listSchema(), listHandler(db.DB)).
		Tool("search", searchSchema(), searchHandler(db.DB)).
		Tool("del", delSchema(), delHandler(db.DB)).
		Tool("selftest", selfTestSchema(), selfTestHandler(db.DB, "sqlite")).
		OnDrain(func(c *sdk.Component) { _ = db.Close() })
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "store-sqlite:", err)
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
			 VALUES (?, ?, 1, ?, CURRENT_TIMESTAMP)
			 ON CONFLICT(kind, id) DO UPDATE SET
			   rev = docs.rev + 1, value = excluded.value,
			   updated_at = CURRENT_TIMESTAMP`, kind, id, value); err == nil {
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

func openStore() (*storeDB, error) {
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	varDir := filepath.Join(root, "var")
	if err := os.MkdirAll(varDir, 0o755); err != nil {
		return nil, fmt.Errorf("create var dir: %w", err)
	}
	dbPath := filepath.Join(varDir, dbFileName)
	fd, err := acquireLock(dbPath + ".lock")
	if err != nil {
		return nil, err
	}
	dsn := "file:" + dbPath +
		"?_txlock=immediate" + // write transactions grab the write lock up front
		"&_journal_mode=WAL" + // crash safety + concurrent readers (sqlite3 CLI, DuckDB attach)
		"&_busy_timeout=10000" + // wait, don't error, when another process holds the write lock
		"&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("open %s: %w", dbPath, err)
	}
	// Serialized tool handlers make one connection plenty; one connection
	// also means exactly one SQLite write lock and no SQLITE_BUSY in practice.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err := migrate(db); err != nil {
		_ = db.Close()
		_ = syscall.Close(fd)
		return nil, err
	}
	// Derived search index: self-heal when it disagrees with `docs` (a
	// crash, a manual DB edit, rows written around put). Cheap when in
	// sync — count + max(rowid) — so a normal start does not re-tokenize
	// the store (docs/WIRE.md "Store contract").
	rebuilt, err := syncSearchIndex(db)
	if err != nil {
		_ = db.Close()
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("search index: %w", err)
	}
	if rebuilt {
		fmt.Println("store-sqlite: rebuilt search index from docs")
	}
	return &storeDB{DB: db, lockFd: fd}, nil
}

// acquireLock takes the exclusive non-blocking flock; the fd stays open for
// as long as the store holds it (closing it would release the lock).
func acquireLock(lockPath string) (int, error) {
	fd, err := syscall.Open(lockPath, syscall.O_CREAT|syscall.O_RDWR, 0o644)
	if err != nil {
		return -1, fmt.Errorf("open lock %s: %w", lockPath, err)
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		return -1, fmt.Errorf("another store is already serving the database (%s) — "+
			"stop the other harness (`make down`) or kill the stale store process, "+
			"then start again", lockPath)
	}
	return fd, nil
}

func migrate(db *sql.DB) error {
	dir, err := fs.Sub(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("migration fs: %w", err)
	}
	provider, err := goose.NewProvider(goose.DialectSQLite3, db, dir)
	if err != nil {
		return fmt.Errorf("goose provider: %w", err)
	}
	applied, err := provider.Up(context.Background())
	if err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	for _, m := range applied {
		fmt.Println("store-sqlite: applied migration", m.Source.Path)
	}
	return nil
}

// ---------------------------------------------------------------------------
// arg decoding — lenient like the barrel engine's argString/argInt (a
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

		// Session scoping, mirrored from the barrel store: the harness
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

		// Doc, revision AND search index move in ONE transaction — the index
		// (docs_fts) is derived from the same write, so a search can never
		// observe a document the store has not committed (or vice versa).
		tx, err := db.BeginTx(context.Background(), nil)
		if err != nil {
			return nil, fmt.Errorf("put: %w", err)
		}
		defer func() { _ = tx.Rollback() }() // no-op once committed

		if expectRev > 0 {
			res, err := tx.Exec(
				`UPDATE docs SET rev = rev + 1, value = ?, updated_at = CURRENT_TIMESTAMP
				 WHERE kind = ? AND id = ? AND rev = ?`,
				string(value), kind, id, expectRev)
			if err != nil {
				_ = tx.Rollback()
				return nil, fmt.Errorf("put: %w", err)
			}
			if n, _ := res.RowsAffected(); n == 0 {
				_ = tx.Rollback()
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
			if err := indexDoc(tx, kind, id, value); err != nil {
				_ = tx.Rollback()
				return nil, err
			}
			if err := tx.Commit(); err != nil {
				return nil, fmt.Errorf("put: %w", err)
			}
			return sdk.OK(map[string]any{"rev": expectRev + 1}), nil
		}

		// Upsert: rev starts at 1 on insert, increments on update.
		var rev int64
		if err := tx.QueryRow(
			`INSERT INTO docs (kind, id, rev, value, updated_at)
			 VALUES (?, ?, 1, ?, CURRENT_TIMESTAMP)
			 ON CONFLICT(kind, id) DO UPDATE SET
			   rev = docs.rev + 1, value = excluded.value,
			   updated_at = CURRENT_TIMESTAMP
			 RETURNING rev`,
			kind, id, string(value)).Scan(&rev); err != nil {
			_ = tx.Rollback()
			return nil, fmt.Errorf("put: %w", err)
		}
		if err := indexDoc(tx, kind, id, value); err != nil {
			_ = tx.Rollback()
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("put: %w", err)
		}
		return sdk.OK(map[string]any{"rev": rev}), nil
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
// (%, _ and the escape char). Ids are alphanumeric + ':' + '-' today, but
// the prefix is data — escape for defense and match the literal text.
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
			limit = 100 // default when absent, as the barrel engine's macro default
		}
		// Cap, and mirror barrel's critbit bound (any limit < 1 yields one
		// item there — see the header note on deliberate divergences).
		if limit > listCap {
			limit = listCap
		}
		if limit < 1 {
			limit = 1
		}
		// Exclusive id cursor (barrel's keysByPrefix has the same semantics:
		// `id <= after` is skipped). ORDER BY id matches the barrel engine's
		// key order, so paging is stable across both engines.
		query := `SELECT id, rev, value FROM docs
			 WHERE kind = ? AND id LIKE ? ESCAPE '\' ORDER BY id LIMIT ?`
		qargs := []any{kind, likeEscape(prefix) + "%", limit}
		if after != "" {
			query = `SELECT id, rev, value FROM docs
			 WHERE kind = ? AND id LIKE ? ESCAPE '\' AND id > ? ORDER BY id LIMIT ?`
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
		// stops when it is empty. nextAfter is the last returned id, and is
		// present only when another page may exist.
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
		// Idempotent, as in the barrel engine. Doc, revision AND index row
		// go in one transaction — a deleted document is unfindable by
		// `search` the moment `del` answers.
		tx, err := db.BeginTx(context.Background(), nil)
		if err != nil {
			return nil, fmt.Errorf("del: %w", err)
		}
		defer func() { _ = tx.Rollback() }() // no-op once committed
		var rowid int64
		switch err := tx.QueryRow(`SELECT rowid FROM docs WHERE kind = ? AND id = ?`,
			rawString(m, "kind"), rawString(m, "id")).Scan(&rowid); err {
		case sql.ErrNoRows:
			_ = tx.Rollback()
			return sdk.OK(nil), nil // already gone
		case nil:
		default:
			_ = tx.Rollback()
			return nil, fmt.Errorf("del: %w", err)
		}
		if _, err := tx.Exec(`DELETE FROM docs WHERE kind = ? AND id = ?`,
			rawString(m, "kind"), rawString(m, "id")); err != nil {
			_ = tx.Rollback()
			return nil, fmt.Errorf("del: %w", err)
		}
		if err := unindexDocIn(tx, rowid); err != nil {
			_ = tx.Rollback()
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("del: %w", err)
		}
		return sdk.OK(nil), nil
	}
}
