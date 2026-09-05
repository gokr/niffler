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
		Tool("del", delSchema(), delHandler(db.DB)).
		OnDrain(func(c *sdk.Component) { _ = db.Close() })
	if err := comp.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "store-sqlite:", err)
		os.Exit(1)
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

		// Doc and revision move in ONE atomic statement each branch —
		// closing the barrel engine's two-step (doc key + rev key) crash
		// window. BEGIN IMMEDIATE (via _txlock) + the serialized handler
		// keep read-modify-write safe.
		if expectRev > 0 {
			res, err := db.Exec(
				`UPDATE docs SET rev = rev + 1, value = ?, updated_at = CURRENT_TIMESTAMP
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

		// Upsert: rev starts at 1 on insert, increments on update.
		var rev int64
		if err := db.QueryRow(
			`INSERT INTO docs (kind, id, rev, value, updated_at)
			 VALUES (?, ?, 1, ?, CURRENT_TIMESTAMP)
			 ON CONFLICT(kind, id) DO UPDATE SET
			   rev = docs.rev + 1, value = excluded.value,
			   updated_at = CURRENT_TIMESTAMP
			 RETURNING rev`,
			kind, id, string(value)).Scan(&rev); err != nil {
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
		},
		"required": []string{"kind"},
		"description": "List stored documents of a kind, ordered by id, optionally id-prefix filtered. " +
			"Read-only. Enumerate conversations (kind conversation) or one conversation's messages " +
			"(kind message, idPrefix <convId>:). Returns {ok, items: [{id, rev, value}]}.",
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
		rows, err := db.Query(
			`SELECT id, rev, value FROM docs
			 WHERE kind = ? AND id LIKE ? ESCAPE '\' ORDER BY id LIMIT ?`,
			kind, likeEscape(prefix)+"%", limit)
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
		return sdk.OK(map[string]any{"items": items}), nil
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
		// Idempotent, as in the barrel engine. The row (doc + rev) goes as
		// one — a re-put starts fresh at rev 1, exactly like deleting both
		// barrel keys did.
		if _, err := db.Exec(`DELETE FROM docs WHERE kind = ? AND id = ?`,
			rawString(m, "kind"), rawString(m, "id")); err != nil {
			return nil, fmt.Errorf("del: %w", err)
		}
		return sdk.OK(nil), nil
	}
}
