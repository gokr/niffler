## Read-only context health: real core/store on a private bus, no provider.
import std/[json, os, strutils]
import natsnim
import helpers
import ../core/[catalog, dispatch]

proc main() =
  let sandbox = newCoreSandbox("context-status", ["store"])
  defer: removeDir(sandbox.root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let core = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root, extra = [("NIF_CTX_RESERVE", "")])
  defer: stopProcess(core)
  var ready = false
  for i in 0 ..< 100:
    let c = call(nc, "core", "catalog", %*{"op": "components"}, 1000)
    if c{"components"}{"store"} != nil:
      ready = true
      break
    sleep(100)
  check("context-status core/store ready", ready)

  let sid = "health-session"
  proc put(kind, id: string, value: JsonNode) =
    let r = call(nc, "store", "put", %*{"kind": kind, "id": id, "value": value})
    doAssert r{"ok"}.getBool(false), $r
  proc status(): JsonNode =
    call(nc, "core", "context_status", %*{"sessionId": sid})
  var header = %*{"context": 1000000, "output": 384000,
                 "contextUsed": 500000, "promptTokens": 499000}
  put("conversation", sid, header)
  let before = call(nc, "store", "get", %*{"kind": "conversation", "id": sid})
  let healthy = status()
  check("shared thresholds include declared output cap",
    healthy{"trimAt"}.getInt() == 616000 and
    healthy{"warnAt"}.getInt() == 462000 and
    healthy{"outputReserve"}.getInt() == 384000, $healthy)
  check("status classifies last persisted usage honestly",
    healthy{"state"}.getStr() == "warning" and
    healthy{"used"}.getInt() == 500000 and
    healthy{"headroomTokens"}.getInt() == 116000 and
    healthy{"usageSource"}.getStr() == "last-persisted")
  check("no loss/projection/snapshots are explicit",
    healthy{"trimThrough"}.getInt(-1) == 0 and
    healthy{"projection"}.kind == JNull and
    healthy{"lossNotices"}.len == 0 and healthy{"retainedSnapshots"}.len == 0)
  check("status never rewrites header",
    call(nc, "store", "get", %*{"kind": "conversation", "id": sid}) == before)

  header["contextUsed"] = %700000
  header["trimThrough"] = %42
  header["compactFailures"] = %2
  header["compactReason"] = %"compact:declined: input-budget-exceeded"
  put("conversation", sid, header)
  let projection = %*{"generation": 3, "covered": {"from": sid & ":000001",
    "to": sid & ":000020"}, "retained": [sid & ":000043"], "prunes": []}
  put("context_projection", sid, projection)
  let metaId = sid & ":attempt-1"
  let meta = %*{"attemptId": "attempt-1", "pageCount": 1,
    "trigger": "pressure", "createdAt": 123.5, "canonicalHigh": 80,
    "contentBytes": 300}
  put("compaction_input", metaId, meta)
  put("compaction_input", metaId & ":p000000", %*{"content": "PRIVATE PAGE"})
  put("compaction_input", "foreign:attempt-1", meta)
  let lost = status()
  check("trim-needed is pressure, not a claim that a trim is running",
    lost{"state"}.getStr() == "trim-needed" and lost{"headroomTokens"}.getInt(-1) == 0)
  check("loss watermark and recall survive without scanning canonical messages",
    lost{"trimThrough"}.getInt() == 42 and
    lost{"lossNotices"}.len == 1 and
    lost{"lossNotices"}[0]{"compactFailures"}.getInt() == 2 and
    lost{"lostRecallRef"}{"id"}.getStr() == sid & ":000001", $lost)
  check("projection reports coverage and generation",
    lost{"projection"}{"generation"}.getInt() == 3 and
    lost{"projection"}{"covered"} == projection["covered"] and
    lost{"projection"}{"retained"}.getInt() == 1)
  check("retained snapshots include metadata only and only this session",
    lost{"retainedSnapshots"}.len == 1 and
    lost{"retainedSnapshots"}[0]{"id"}.getStr() == metaId and
    lost{"retainedSnapshots"}[0]{"bytes"}.getInt() == 300 and
    not ($lost).contains("PRIVATE PAGE"))
  check("snapshot remains untouched",
    call(nc, "store", "get", %*{"kind": "compaction_input", "id": metaId}){"value"} == meta)
  check("missing and empty session ids refuse",
    call(nc, "core", "context_status", %*{}){"error"} != nil and
    call(nc, "core", "context_status", %*{"sessionId": "absent"}){"error"} != nil)
  check("invoke routes the same read-only tool",
    call(nc, "core", "invoke", %*{"tool": "context_status",
      "arguments": {"sessionId": sid}}) == lost)

  # Same dispatch gate a live runner uses: inject identity before forwarding.
  let cat = newCatalog(nc)
  let ct = CoreTools(nc: nc, cat: cat, runner: true,
                     nested: NestedState(session: sid))
  check("omitted and empty ids use the current runner's session",
    ct.dispatchToolCall("context_status", %*{}) == lost and
    ct.dispatchToolCall("context_status", %*{"sessionId": ""}) == lost)
  let schema = cat.toolSchema("context_status")
  check("health is on-demand and read-effect",
    schema{"x-harness"}{"effect"}.getStr() == "read" and
    schema{"x-harness"}{"onDemand"}.getBool(false))

  put("conversation", sid, %*{})
  let unknown = status()
  check("unknown window has no fabricated pressure verdict",
    unknown{"window"}.getInt(-1) == 0 and unknown{"state"} == nil and
    unknown{"headroomTokens"} == nil)
  header["contextUsed"] = %100
  put("conversation", sid, header)
  check("low occupancy reports ok", status(){"state"}.getStr() == "ok")
  report("CONTEXT-STATUS")

main()
