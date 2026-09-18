## recall tests — the replaced-content reference space: ref resolution, the
## in-document grep (mode:match), and mode:search across a conversation's whole
## canonical history (including the span a trim or compaction removed from the
## projection, which no notice points at).
##
## Also pins the tool's *reachability*: context_recall must be x-harness.onDemand,
## never hidden. Every trim/prune notice in a conversation tells the model to use
## context_recall with the ref verbatim — a hidden tool is invisible to exactly
## that caller (discover never lists it, invoke refuses it), so the advice would
## be unactionable and the store the only way back. This check would have caught
## that; the component shipped with hidden: true and no test at all.

import std/[json, os, strutils, times]
import natsnim
import helpers

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let recallBin = root / "var" / "bin" / "recall"
  if not fileExists(recallBin):
    fail(recallBin & " missing — run `make build` first")
    report("RECALL TEST")
  let storeBin = resolveStoreBin(root)
  if not fileExists(storeBin):
    fail(storeBin & " missing — run `make build` first")
    report("RECALL TEST")

  let tmp = tempRoot("recall")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # Capture the registration stream before the components start: the schema is
  # the contract the model sees, and the flags on it decide whether the tool is
  # reachable at all.
  var regSub: ptr natsSubscription
  let rsub = natsConnection_SubscribeSync(addr regSub, nc.conn,
                                          "reg.publish".cstring)
  check("subscribed to reg.publish", checkStatus(rsub), "reg.publish")

  let storeProc = startComponent(storeBin, url, root = tmp)
  defer: stopProcess(storeProc)
  let recallProc = startComponent(recallBin, url, root = tmp)
  defer: stopProcess(recallProc)

  # Read both announcements off the subscription opened BEFORE the spawns.
  # `reg.publish` carries the registration object *itself* — `envelope.decode`
  # leaves `payload` nil for it, which is why the payload-based drain this
  # replaces never captured anything — and it is fire-and-forget, so a
  # subscription opened after a spawn misses what already happened. Both matter
  # here: `recall` announces (one tool, no store) while `store` is still
  # opening its database, so waiting for store on a fresh subscription ate
  # recall's announcement and the check failed 15 s later; the nil `reg` then
  # reached `$reg` and segfaulted the run.
  var storeReg, recallReg: JsonNode
  block:
    let deadline = epochTime() + 20
    while epochTime() < deadline and (storeReg == nil or recallReg == nil):
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, regSub, 500)
      if st != NATS_OK: continue
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      var node: JsonNode
      try:
        node = parseJson(data)
      except CatchableError:
        continue
      case node{"name"}.getStr("")
      of "store": storeReg = node
      of "recall": recallReg = node
      else: discard
  check("store registers", storeReg != nil, "reg.publish")
  check("recall registers", recallReg != nil, "reg.publish")

  # --- the registered schema: reachable by the caller the notices address ----
  let reg = recallReg
  var hs: JsonNode
  if reg != nil:
    let tools = reg{"tools"}
    if tools != nil and tools.kind == JArray:
      for t in tools:
        if t{"name"}.getStr("") == "context_recall":
          hs = t{"schema"}{"x-harness"}
  # `$` on a nil JsonNode dereferences (json.nim has no nil guard), so the
  # detail strings are guarded: a missing announcement must report, not
  # segfault the run.
  let regText = if reg == nil: "no recall announcement captured" else: $reg
  let hsText = if hs == nil: "no recall schema in the announcement" else: $hs
  check("context_recall is registered", hs != nil, regText)
  check("context_recall is onDemand, not hidden",
        hs != nil and hs{"onDemand"}.getBool(false) and hs{"hidden"} == nil,
        "the notices tell the model to call it; hidden makes that impossible — " & hsText)
  check("context_recall declares sessionId (the runner injects the conversation)",
        hs != nil and hs{"sessionId"}.getBool(false), hsText)

  # --- seed a conversation whose middle stands in for dropped messages -------
  const conv = "conv-recalltest"
  let seeded = [
    ("000001", %*{"role": "user", "content": "Please look at the auth flow."}),
    ("000002", %*{"role": "assistant", "content": "I will read the middleware."}),
    ("000003", %*{"role": "tool",
                  "content": "src/auth.nim:41:5  error  ZEBRAFISH timeout after 250ms [pyright]\n" &
                             "src/auth.nim:60:1  warning  unused import os"}),
    ("000004", %*{"role": "assistant",
                  "content": "Found it: the zebrafish timeout is too low."}),
  ]
  for (seqNo, msg) in seeded:
    let r = call(nc, "store", "put",
                 %*{"kind": "message", "id": conv & ":" & seqNo, "value": msg},
                 10_000)
    check("seeded " & seqNo, r{"ok"}.getBool(false), $r)

  # --- mode:search: the question a ref cannot answer ------------------------
  let s1 = call(nc, "recall", "context_recall",
                %*{"mode": "search", "query": "ZEBRAFISH", "session": conv},
                15_000)
  check("search finds every mentioning message, case-insensitively",
        s1{"ok"}.getBool(false) and s1{"count"}.getInt(0) == 2, $s1)
  check("search reports the ids a follow-up can fetch",
        s1{"count"}.getInt(0) == 2 and
        s1{"matches"}[0]{"id"}.getStr("") == conv & ":000003", $s1)
  check("search snippets show the matching line",
        "ZEBRAFISH" in s1{"matches"}[0]{"snippet"}.getStr(""), $s1)
  check("search scanned the whole conversation",
        s1{"scanned"}.getInt(0) == 4, $s1)

  let limited = call(nc, "recall", "context_recall",
                     %*{"mode": "search", "query": "zebrafish",
                        "session": conv, "limit": 1}, 15_000)
  check("search is bounded and says it capped",
        limited{"count"}.getInt(0) == 1 and limited{"capped"}.getBool(false),
        $limited)

  let toolOnly = call(nc, "recall", "context_recall",
                      %*{"mode": "search", "query": "zebrafish",
                         "session": conv, "role": "tool"}, 15_000)
  check("search can filter by role",
        toolOnly{"count"}.getInt(0) == 1 and
        toolOnly{"matches"}[0]{"role"}.getStr("") == "tool", $toolOnly)

  let none = call(nc, "recall", "context_recall",
                  %*{"mode": "search", "query": "no-such-token-xyz",
                     "session": conv}, 15_000)
  check("a search with no hits is an empty result, not an error",
        none{"ok"}.getBool(false) and none{"count"}.getInt(0) == 0, $none)

  # --- the round trip: search finds the message, ref reads it in full --------
  let full = call(nc, "recall", "context_recall",
                  %*{"mode": "full",
                     "ref": {"source": "canonical", "id": conv & ":000003"}},
                  15_000)
  check("a search hit reads back in full by ref",
        full{"ok"}.getBool(false) and "ZEBRAFISH" in full{"text"}.getStr(""),
        $full)

  let m = call(nc, "recall", "context_recall",
               %*{"mode": "match", "query": "unused import os",
                  "ref": {"source": "canonical", "id": conv & ":000003"}},
               15_000)
  check("mode:match greps one document's lines",
        m{"ok"}.getBool(false) and
        "unused import os" in m{"text"}.getStr("") and
        "ZEBRAFISH" notin m{"text"}.getStr(""), $m)

  # --- refusal paths are explicit -------------------------------------------
  let noConv = call(nc, "recall", "context_recall",
                    %*{"mode": "search", "query": "x"}, 15_000)
  check("search without a conversation says which argument is missing",
        not noConv{"ok"}.getBool(true) and "session" in noConv{"error"}.getStr(""),
        $noConv)
  let noQuery = call(nc, "recall", "context_recall",
                     %*{"mode": "search", "session": conv}, 15_000)
  check("search without a query says which argument is missing",
        not noQuery{"ok"}.getBool(true) and "query" in noQuery{"error"}.getStr(""),
        $noQuery)
  let badMode = call(nc, "recall", "context_recall",
                     %*{"mode": "teleport", "ref": {"source": "canonical",
                                                    "id": conv & ":000003"}},
                     15_000)
  check("an unknown mode is refused",
        not badMode{"ok"}.getBool(true) and "mode" in badMode{"error"}.getStr(""),
        $badMode)
  let badRef = call(nc, "recall", "context_recall",
                    %*{"mode": "full",
                       "ref": {"source": "canonical", "id": conv & ":999999"}},
                    15_000)
  check("an unresolvable ref fails loudly, not silently empty",
        not badRef{"ok"}.getBool(true) and "not found" in badRef{"error"}.getStr(""),
        $badRef)

  report("RECALL TEST")

main()
