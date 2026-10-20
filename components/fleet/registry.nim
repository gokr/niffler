## Fleet instance registry — where a verified route LIVES.
##
## One document per instance, kind "fleetinstance", id = the instance's stable
## 32-hex identity. The payload is the verified version-1 receipt (transport,
## route, root and the pinned identity expectation) plus provenance; nothing
## about a route is spread across SQL columns, so adding a transport stays a
## payload change rather than a migration.
##
## The registry is NOT authority to act. Every mutation still re-verifies the
## live catalog identity before it writes (provision.guard/probe), so a
## tampered document fails instead of granting access. The receipt FILE remains
## a portable export/import format — bootstrap and interchange — not the
## authoritative registry.
import std/[json, strutils, times]
import niffler/sdk
import provision

const instancesKind* = "fleetinstance"

proc refuse(s: string) {.noreturn.} = raise newException(ValueError, s)

proc validId*(id: string): bool =
  id.len == 32 and id.allCharsInSet({'0'..'9', 'a'..'f'})

proc validateInstanceDoc*(doc: JsonNode) =
  ## A registry document must still be a valid receipt: a corrupted or
  ## hand-edited document refuses at load, never silently becomes a route.
  validateProfile(doc)

proc saveInstance*(c: Component, receipt: JsonNode, source: string): int =
  ## Persist a verified receipt. Callers save only AFTER identity verification;
  ## this validates again so a bug upstream cannot store a route nobody proved.
  validateProfile(receipt)
  let id = receipt{"expect", "instanceId"}.getStr("")
  if not validId(id): refuse("registry needs a valid instance identity")
  var doc = receipt.copy()
  doc["source"] = %source
  doc["updatedAt"] = %epochTime()
  result = c.storePut(instancesKind, id, doc)

proc loadInstance*(c: Component, id: string): JsonNode =
  if not validId(id): refuse("instance id must be 32 lowercase hex")
  let item = c.storeGet(instancesKind, id)
  if item.value == nil: refuse("unknown fleet instance " & id)
  validateInstanceDoc(item.value)
  item.value

proc importReceipt*(c: Component, path: string): JsonNode =
  ## Explicit one-time import of an existing private receipt file into the
  ## registry. Same validation as an install; the file is left untouched.
  let p = loadReceipt(receiptPath(path))
  if p == nil: refuse("no verified receipt at " & path)
  let id = p{"expect", "instanceId"}.getStr("")
  let rev = saveInstance(c, p, "import")
  %*{"ok": true, "instanceId": id, "rev": rev}

proc listInstances*(c: Component): JsonNode =
  ## Summaries for a picker/UI. An invalid document is reported, not dropped:
  ## a registry that silently hides a broken entry is worse than one that shows
  ## it, because the entry still names somebody's instance.
  var items = newJArray()
  for entry in c.storeListAll(instancesKind):
    let v = entry.value
    try:
      validateInstanceDoc(v)
    except CatchableError:
      items.add(%*{"instanceId": entry.id, "invalid": true,
                   "error": "document is not a valid receipt"})
      continue
    # Every field is read with an explicit default: a missing key is a nil
    # JsonNode, and embedding nil in a %* literal crashes `encode` (the
    # documented json.nim gotcha), taking the whole component down.
    items.add(%*{"instanceId": entry.id,
                 "name": v{"expect", "name"}.getStr(""),
                 "root": v{"root"}.getStr(""),
                 "transport": v{"transport"}.getStr(""),
                 "target": v{"target"}.getStr(""),
                 "host": v{"host"}.getStr(""),
                 "gitHash": v{"expect", "gitHash"}.getStr(""),
                 "source": v{"source"}.getStr(""),
                 "updatedAt": v{"updatedAt"}.getFloat(0.0)})
  %*{"ok": true, "count": items.len, "instances": items}
