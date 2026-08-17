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

import std/[json, os, strutils]
import bitbarrel/barrel
import niffler/sdk

let comp = newComponent("store", "0.1.0")

var db: Barrel

proc openDb() =
  # barrel is bitcask-style: the path is a data file, created if missing
  let path = getEnv("NIF_ROOT", ".") / "var" / "barrel-db"
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
    ## Upsert a document. expectRev > 0 → fail if the current rev differs.
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
    ## Fetch a document by kind and id
    let rev = getRev(kind, id)
    if rev == 0:
      return %*{"ok": false, "error": "not found", "code": "not-found"}
    return %*{"ok": true, "rev": rev, "value": parseJson(  db.get(docKey(kind, id)))}

comp.tool:
  proc list(kind: string, idPrefix: string = "", limit: int = 100): JsonNode =
    ## List documents of a kind, optionally filtered by id prefix
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
    ## Delete a document
    discard   db.delete(docKey(kind, id))
    discard   db.delete(revKey(kind, id))
    return %*{"ok": true}

comp.tools[^1].schema["x-harness"] = %*{"hidden": true}

proc onDrain(c: Component, subject: string, payload: JsonNode) =
  db.close()

discard comp.on("ev.sys.drain", onDrain)
comp.run()
