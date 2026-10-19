## Test-only durable document store with explicit write-failure injection.
import std/[json, os, algorithm, strutils]
import niffler/sdk
let c = newComponent("store", "0.1.0")
let path = getEnv("NIF_ROOT") / "docs.json"
let control = getEnv("NIF_ROOT") / "fault.json"
var docs = if fileExists(path): parseFile(path) else: newJObject()
proc save() =
  writeFile(path & ".new", $docs)
  moveFile(path & ".new", path)
for tool in ["get", "put", "list", "del"]:
  let name = tool
  proc handler(name: string): ToolHandler =
    result = proc(c: Component, a: JsonNode): JsonNode =
      let kind = a{"kind"}.getStr("")
      let id = a{"id"}.getStr("")
      let key = kind & "/" & id
      let fault = if fileExists(control): parseFile(control) else: newJObject()
      if name == "put":
        let v = a["value"]
        if (fault{"state"}.getStr("") != "" and v{"state"}.getStr("") == fault["state"].getStr()) or
            (fault{"message"}.getBool(false) and kind == "message") or
            (fault{"ack"}.getBool(false) and v{"delivered"}.getBool(false)):
          return %*{"ok": false, "error": "injected durable write failure"}
        let rev = docs{key}{"rev"}.getInt(0)
        let expect = a{"expectRev"}.getInt(0)
        if (expect == -1 and rev > 0) or (expect > 0 and expect != rev):
          return %*{"ok": false, "code": "rev-conflict", "error": "conflict"}
        docs[key] = %*{"id": id, "rev": rev + 1, "value": v}
        save()
        return %*{"ok": true, "rev": rev + 1}
      if name == "get":
        if docs{key} == nil: return %*{"ok": false, "code": "not-found", "error": "missing"}
        result = docs[key].copy(); result["ok"] = %true
      elif name == "list":
        var keys: seq[string]
        for k, v in docs:
          if k.startsWith(kind & "/") and v["id"].getStr().startsWith(a{"idPrefix"}.getStr("")) and
              v["id"].getStr() > a{"after"}.getStr(""): keys.add(k)
        keys.sort()
        var items = newJArray()
        for k in keys: items.add(docs[k])
        result = %*{"ok": true, "items": items, "hasMore": false, "nextAfter": ""}
      else:
        docs.delete(key); save(); result = %*{"ok": true}
  discard c.tool(name, %*{"type": "object", "properties": {}}, handler(name))
c.run()
