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
##   slash        id=slash          {updatedAt, commands: [{name, description,
##                                  component, tool, params}]} — core's
##                                  checkpoint of the merged slash-command
##                                  table (docs/WIRE.md); UIs read it first

import std/[json, os, strutils]
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
  let path = getEnv("NIF_ROOT", ".") / "var" / "barrel-db"
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

comp.tool:
  proc put(kind: string, id: string, value: JsonNode, expectRev: int = 0): JsonNode =
    ## Upsert a document into the store. Hidden from the LLM: writes are
    ## made by core on the agent's behalf (conversations, messages,
    ## spawned component records). expectRev > 0 → fail if the current
    ## revision differs (optimistic concurrency).
    ## - kind: Document kind (conversation, message, component, ...)
    ## - id: Document id within the kind
    ## - value: The document body (any JSON)
    ## - expectRev: Require this current revision, or fail with rev-conflict
    let cur = getRev(kind, id)
    if expectRev > 0:
      if cur == 0:
        return %*{"ok": false, "error": "not found", "code": "rev-conflict"}
      if cur != expectRev:
        return %*{"ok": false, "error": "rev conflict", "code": "rev-conflict",
                  "currentRev": cur}
    discard   db.set(docKey(kind, id), $value)
    discard   db.set(revKey(kind, id), $(cur + 1))
    return %*{"ok": true, "rev": cur + 1}

comp.tools[^1].schema["x-harness"] = %*{"hidden": true}

comp.tool:
  proc get(kind: string, id: string): JsonNode =
    ## Fetch a document by kind and id. Read-only; use it to inspect
    ## persisted state. Kinds in use: conversation (id conv-*), message
    ## (id <convId>:<n>), component (id <name>). Returns ok, rev and value,
    ## or ok:false with code not-found.
    ## - kind: Document kind
    ## - id: Document id within the kind
    let rev = getRev(kind, id)
    if rev == 0:
      return %*{"ok": false, "error": "not found", "code": "not-found"}
    return %*{"ok": true, "rev": rev, "value": parseJson(  db.get(docKey(kind, id)))}

comp.tool:
  proc list(kind: string, idPrefix: string = "", limit: int = 100): JsonNode =
    ## List documents of a kind, ordered by id, optionally filtered by an
    ## id prefix. Read-only; use it to enumerate conversations (kind
    ## conversation) or the messages of one conversation (kind message,
    ## idPrefix <convId>:). Returns ok and items [{id, rev, value}].
    ## - kind: Document kind
    ## - idPrefix: Only items whose id starts with this
    ## - limit: Max items (default 100, cap 1000)
    let prefix = "d:" & kind & ":" & idPrefix
    let (keys, _, _) =   db.keysByPrefix(prefix, min(limit, 1000))
    var items = newJArray()
    for key in keys:
      let id = key[len("d:" & kind & ":" ) .. ^1]
      let rev = getRev(kind, id)
      if rev == 0: continue  # tombstoned
      items.add(%*{"id": id, "rev": rev,
                   "value": parseJson(  db.get(docKey(kind, id)))})
    return %*{"ok": true, "items": items}

comp.tool:
  proc del(kind: string, id: string): JsonNode =
    ## Delete a document. Hidden from the LLM: deletes are made by core
    ## (e.g. core.remove dropping a component record).
    ## - kind: Document kind
    ## - id: Document id within the kind
    discard   db.delete(docKey(kind, id))
    discard   db.delete(revKey(kind, id))
    return %*{"ok": true}

comp.tools[^1].schema["x-harness"] = %*{"hidden": true}

proc onDrain(c: Component, subject: string, payload: JsonNode) =
  db.close()

discard comp.on("ev.sys.drain", onDrain)
comp.run()
