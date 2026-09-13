## store component — persistence as a bus service.
##
## A dumb document store backed by an embedded BitBarrel database (Bitcask
## KV, critbit index for ordered prefix scans). The bus contract
## (put/get/list/del) is the artifact; consumers interpret the JSON.
## Exactly ONE process owns the barrel — every other process talks
## envelopes, never a DB driver. A store-tidb component later implements
## the same tools (SQL tables, FTS, vector) as a drop-in.
##
## Keys: d:<kind>:<id> (JSON doc), r:<kind>:<id> (revision counter).
## put supports optimistic concurrency (expectRev). list returns items in
## key order (deterministic; sort on the consumer side if needed).
##
## Kinds used by core:
##   component    id=<name>         {name, binary, policy, addedAt}
##   conversation id=conv-<ts>      {createdAt, model, title}
##   message      id=<convId>:<n>   {conversationId, role, content, ...}
##   approval     id=<convId>:<tool> per-conversation auto-approve memory
##   agentjob     id=<jobId> background subagent job (status, reply/error)
##   slash        id=slash          {updatedAt, commands: [{name, description,
##                                  component, tool, params}]} — core's
##                                  checkpoint of the merged slash-command
##                                  table (docs/WIRE.md); UIs read it first

import std/[json, os, strutils, times]
when defined(posix):
  import std/posix
  proc flock(fd: cint, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}
  # POSIX values (identical on Linux and macOS): 2 = LOCK_EX, 4 = LOCK_NB
  const FLOCK_EX_NB = 2 or 4
import bitbarrel/barrel
import niffler/sdk

let comp = newComponent("store", "0.1.0")

var db: Barrel
var lockFd: cint = -1

proc acquireLock(path: string) =
  ## Single-writer enforcement: exactly one store process may serve a
  ## barrel file. flock is released by the kernel when the process dies,
  ## so a crash never wedges the store — but a second live store refuses
  ## to start instead of silently sharing the bus: two stores in the
  ## "store" queue group would each answer svc.store.call from its own
  ## in-memory index, making lists alternate between two inconsistent
  ## views (the classic flapping session sidebar).
  when defined(posix):
    let lockPath = path & ".lock"
    lockFd = posix.open(lockPath.cstring, O_CREAT or O_RDWR, 0o644)
    if lockFd < 0 or flock(lockFd, FLOCK_EX_NB) != 0:
      stderr.writeLine("store: another store is already serving " & path &
        " — stop the other harness (`make down`) or kill the stale store " &
        "process, then start again")
      quit(1)

proc openDb() =
  # barrel is bitcask-style: the path is a data file, created if missing
  let path = rootVarDir("barrel-db")
  acquireLock(path)
  var config = defaultBarrelConfig()
  config.mode = bmCritBit  # ordered prefix scans
  db = openBarrel(path, config)

openDb()

proc docKey(kind, id: string): string = "d:" & kind & ":" & id
proc revKey(kind, id: string): string = "r:" & kind & ":" & id
proc getRev(kind, id: string): int =
  let raw = db.get(revKey(kind, id))
  if raw.len == 0: return 0
  return raw.parseInt()

# Low-level registration (not the `comp.tool:` macro): sessions may save
# model-curated documents (kind fabricprog — the fabric name-based
# library), so the handler needs the raw __session injection to scope
# writes. Direct bus callers (cli, tests, core-internal clients) carry no
# session and keep full access.
let putSchema = toolSchema(%*{
  "kind": {"type": "string",
            "description": "Document kind. From a session only curated kinds are writable: 'fabricprog' (programs fabric runs by name)."},
  "id": {"type": "string",
        "description": "Document id within the kind (fabricprog: the program name)"},
  "value": {"type": "object",
            "description": "The document body (any JSON). fabricprog entries: {code: <program source>}"},
  "expectRev": {"type": "integer",
                "description": "Require this current revision, or fail with rev-conflict (default 0 = upsert)"}
}, required = @["kind", "id", "value"],
  description = "Save a document into the store. From a session this writes the model-curated program library (kind fabricprog — code of fabric programs, run them with the fabric tool's name parameter; list what exists with store list). Other kinds are harness-managed and rejected from sessions.")
putSchema["x-harness"] = %*{"onDemand": true, "sessionId": true}
discard comp.tool("put", putSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let kind = toolArgs{"kind"}.getStr("")
    let id = toolArgs{"id"}.getStr("")
    let value = toolArgs{"value"}
    let expectRev = toolArgs{"expectRev"}.getInt(0)
    # Session scoping: the harness manages its own kinds (conversation,
    # message, component, ...) through the SDK store client; a session may
    # only curate the model-owned library so no live session can corrupt
    # transcripts or component records. Direct bus callers (cli, tests)
    # carry an empty session and keep full access.
    if toolArgs{"__session"}{"session"}.getStr("").len > 0 and
        kind != "fabricprog":
      return errResult(
        "sessions may only put curated kinds (fabricprog); '" & kind &
        "' is harness-managed", "forbidden-kind")
    let cur = getRev(kind, id)
    if expectRev > 0:
      if cur == 0:
        return errResult("not found", "rev-conflict")
      if cur != expectRev:
        return errResult("rev conflict", "rev-conflict",
                         %*{"currentRev": cur})
    discard db.set(docKey(kind, id), $value)
    discard db.set(revKey(kind, id), $(cur + 1))
    return okResult(%*{"rev": cur + 1}))

comp.tool(%*{"onDemand": true}):
  proc get(kind: string, id: string): JsonNode =
    ## Fetch a stored document by kind and id. Read-only. Kinds in use:
    ## conversation (id conv-*), message (id <convId>:<n>), component
    ## (id <name>). Returns {ok, rev, value} or ok:false not-found.
    ## - kind: Document kind
    ## - id: Document id within the kind
    let rev = getRev(kind, id)
    if rev == 0:
      return errResult("not found", "not-found")
    return okResult(%*{"rev": rev, "value": parseJson(db.get(docKey(kind, id)))})

comp.tool(%*{"onDemand": true}):
  proc list(kind: string, idPrefix: string = "", limit: int = 100,
            after: string = ""): JsonNode =
    ## List stored documents of a kind, ordered by id, optionally
    ## id-prefix filtered. Read-only. Enumerate conversations (kind
    ## conversation) or one conversation's messages (kind message,
    ## idPrefix <convId>:). Returns {ok, items: [{id, rev, value}]}.
    ##
    ## `after` is an exclusive id cursor: pass the last id of the previous
    ## page to continue past it (the store keeps full histories, which can
    ## exceed the 1000-item cap). `hasMore` reports whether another page
    ## exists; absence of `nextAfter` with hasMore true is impossible.
    ## - kind: Document kind
    ## - idPrefix: Only items whose id starts with this
    ## - limit: Max items (default 100, cap 1000)
    ## - after: Exclusive id cursor from a previous page (default = first page)
    let prefix = "d:" & kind & ":" & idPrefix
    # Cursor semantics (verified against bitbarrel/critbitindex.nim: the
    # cursor is strictly exclusive — `key <= cursor` is skipped). The cursor
    # is the full document id without the "d:" key prefix, so callers pass
    # items[^1].id straight back.
    let cursor = if after.len == 0: "" else: "d:" & kind & ":" & after
    let (keys, _, hasMore) = db.keysByPrefix(prefix, min(limit, 1000), cursor)
    var items = newJArray()
    for key in keys:
      let id = key[len("d:" & kind & ":" ) .. ^1]
      let rev = getRev(kind, id)
      if rev == 0: continue  # tombstoned
      items.add(%*{"id": id, "rev": rev,
                   "value": parseJson(db.get(docKey(kind, id)))})
    # nextAfter must come from the last returned *key*, never from the last
    # item: a page whose documents are all tombstoned still advances the
    # cursor, otherwise a caller would silently skip every later page.
    # (keysByPrefix can report a spurious trailing hasMore; the follow-up
    # page then comes back empty and the loop terminates — harmless.)
    # The `tool` macro assigns this proc's `result` from its return value,
    # so build the envelope in a local and return it.
    var reply = %*{"items": items, "hasMore": hasMore}
    if hasMore and keys.len > 0:
      reply["nextAfter"] = %keys[^1][len("d:" & kind & ":" ) .. ^1]
    return okResult(reply)

comp.tool(%*{"hidden": true}):
  proc del(kind: string, id: string): JsonNode =
    ## Delete a document. Hidden from the LLM: deletes are made by core
    ## (e.g. core.remove dropping a component record).
    ## - kind: Document kind
    ## - id: Document id within the kind
    discard db.delete(docKey(kind, id))
    discard db.delete(revKey(kind, id))
    return okResult()

discard comp.selfTest(proc(c: Component, args: JsonNode): JsonNode =
  ## Self test (docs/WIRE.md): a full put/get/rev-cas/list/del roundtrip on
  ## a throwaway document, deleted afterwards. Exercises the engine's whole
  ## wire-relevant surface in a few ms; `deep` is accepted and ignored (the
  ## roundtrip IS the live probe — there is nothing deeper to spawn).
  let t0 = epochTime()
  var checks = newJArray()
  var allOk = true
  let kind = "selftest"
  let id = "probe-" & $getCurrentProcessId() & "-" & $int(epochTime() * 1000)
  let engine = getAppFilename().lastPathPart

  proc check(name: string, ok: bool, detail: string, t1: float) =
    if not ok: allOk = false
    checks.add(%*{"name": name, "ok": ok, "detail": detail,
                  "ms": int((epochTime() - t1) * 1000)})

  block roundtrip:
    let t1 = epochTime()
    try:
      # put → rev 1, value roundtrips verbatim
      discard db.set(docKey(kind, id), """{"hello":"selftest","n":42}""")
      discard db.set(revKey(kind, id), "1")
      let got = db.get(docKey(kind, id))
      check("put+get", got == """{"hello":"selftest","n":42}""",
            (if got.len > 0: "value roundtrips verbatim" else: "empty read"), t1)
      # optimistic-concurrency surface: the rev counter advanced
      let t2 = epochTime()
      check("rev counter", getRev(kind, id) == 1, "rev=1 after first put", t2)
      # list sees the document under its kind prefix
      let t3 = epochTime()
      let (keys, _, _) = db.keysByPrefix(docKey(kind, id), 10, "")
      var found = false
      for k in keys:
        if k == docKey(kind, id): found = true
      check("list prefix", found, "document visible under kind prefix", t3)
      # delete is immediate and complete (doc + rev)
      let t4 = epochTime()
      discard db.delete(docKey(kind, id))
      discard db.delete(revKey(kind, id))
      check("del", getRev(kind, id) == 0 and db.get(docKey(kind, id)).len == 0,
            "document and rev gone", t4)
    except CatchableError as e:
      check("roundtrip", false, e.msg, t1)
      try:
        discard db.delete(docKey(kind, id))
        discard db.delete(revKey(kind, id))
      except CatchableError: discard
  return %*{"ok": allOk,
            "summary": "engine roundtrip ok (" & engine & ")",
            "checks": checks})

discard comp.onDrain(proc(c: Component) = db.close())
comp.run()
