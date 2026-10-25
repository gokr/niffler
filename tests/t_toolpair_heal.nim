## t_toolpair_heal — a conversation whose stored transcript lost a tool result
## must be able to run again.
##
## The regression this pins (conversation `sqlite-vec`): four stored messages
## were missing, leaving one assistant `tool_calls` entry with no result and one
## `tool` message answering a call that no longer existed. Every later turn was
## refused with "An assistant message with 'tool_calls' must be followed by tool
## messages responding to each 'tool_call_id'" — permanently, because the damage
## lives in canonical history and each request repeats it.
##
## Contract under test:
##  * the load-time repair makes the request valid: the turn RUNS (the fixture
##    provider enforces pairing exactly like the real one, NIF_MOCK_ENFORCE_PAIRING);
##  * canonical history is NOT rewritten — the stored documents are byte-identical
##    after the repair (the store keeps the gap, recall stays honest);
##  * the loss is recorded durably (kind toolpairrepair) and visible through
##    context_status, instead of a silent hole in the transcript;
##  * the repair is idempotent: a second turn adds nothing to the ledger;
##  * a healthy conversation is never "repaired".

import std/[json, os, strutils, times]
import natsnim
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  ## Membership comes from core's authoritative catalog snapshot; a raw
  ## reg.publish announcement is fire-once and can be missed.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 2_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)

proc put(nc: NatsConnection, kind, id: string, value: JsonNode) =
  let r = call(nc, "store", "put", %*{"kind": kind, "id": id, "value": value})
  doAssert r{"ok"}.getBool(false), $r

proc getDoc(nc: NatsConnection, kind, id: string): JsonNode =
  call(nc, "store", "get", %*{"kind": kind, "id": id})

proc msg(nc: NatsConnection, conv: string, seq: int, value: JsonNode) =
  put(nc, "message", conv & ":" & align($seq, 6, '0'), value)

proc turn(nc: NatsConnection, id, content: string): JsonNode =
  call(nc, "core", "session", %*{"sessionId": id, "content": content}, 240_000)

proc snapshot(nc: NatsConnection, conv: string,
              seqs: openArray[int]): JsonNode =
  ## The stored bytes of the seeded messages, for a before/after comparison.
  result = newJObject()
  for seq in seqs:
    result[$seq] = getDoc(nc, "message", conv & ":" & align($seq, 6, '0')){"value"}

proc logLines(path: string): seq[JsonNode] =
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    if line.strip().len == 0: continue
    try: result.add(parseJson(line))
    except CatchableError: discard

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "session"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing " & bin & " binary — run `make build` first")
      quit(1)

  let sandbox = newCoreSandbox("toolpair-heal", ["store", "bash", "llm"])
  defer:
    if getEnv("NIF_TEST_KEEP") == "1":
      echo "kept test sandbox: " & sandbox.root
    else:
      removeDir(sandbox.root)
  discard fixtureBin(sandbox, "llm", repoRoot / "tests" / "mock_llm.nim",
                     prebuiltName = "fixture-mock-llm")
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let mockLog = sandbox.root / "var" / "mock-llm.jsonl"
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = @[("NIF_AUTO_APPROVE", "1"),
              ("NIF_MOCK_ENFORCE_PAIRING", "1"),
              ("NIF_MOCK_LOG", mockLog)],
    logFile = sandbox.root / "var" / "test-logs" / "core.log")
  defer: stopProcess(coreProc)
  doAssert waitComponent(nc, "store"), "store did not register"
  doAssert waitComponent(nc, "llm"), "mock llm did not register"

  # --- the damaged transcript (the sqlite-vec shape) ----------------------
  const damaged = "pair-damaged"
  put(nc, "conversation", damaged,
      %*{"createdAt": epochTime(), "title": "damaged", "context": 200000})
  msg(nc, damaged, 1, %*{"role": "user", "content": "start"})
  msg(nc, damaged, 2, %*{"role": "assistant", "content": newJNull(),
    "tool_calls": [
      {"id": "call-a", "type": "function",
       "function": {"name": "bash", "arguments": "{}"}},
      {"id": "call-b", "type": "function",
       "function": {"name": "bash", "arguments": "{}"}}]})
  msg(nc, damaged, 3, %*{"role": "tool", "tool_call_id": "call-a",
                         "name": "bash", "content": "result of a"})
  # 000004 never landed; 000005 answers a call that is gone entirely.
  msg(nc, damaged, 5, %*{"role": "tool", "tool_call_id": "call-gone",
                         "name": "bash", "content": "output of a lost call"})
  msg(nc, damaged, 6, %*{"role": "assistant", "content": "half way"})

  const seeded = [1, 2, 3, 5, 6]
  let before = snapshot(nc, damaged, seeded)

  # The guard is real: the same damage handed straight to the provider is
  # refused with the exact 400 text a real backend returns.
  let rawTurn = call(nc, "llm", "chat", %*{
    "messages": [
      %*{"role": "user", "content": "start"},
      %*{"role": "assistant", "content": newJNull(),
         "tool_calls": [%*{"id": "call-a", "type": "function",
                           "function": {"name": "bash", "arguments": "{}"}},
                        %*{"id": "call-b", "type": "function",
                           "function": {"name": "bash", "arguments": "{}"}}]},
      %*{"role": "tool", "tool_call_id": "call-a", "name": "bash",
         "content": "result of a"}],
    "stream": false}, 30_000)
  check("the fixture provider rejects the unpaired request",
        rawTurn{"error"}.getStr("").contains("insufficient tool messages"),
        $rawTurn)

  # --- the repaired load: the conversation runs again --------------------
  let r1 = turn(nc, damaged, "continue")
  check("a conversation with a lost tool result can run a turn",
        r1{"error"}.getStr("").len == 0 and
        (r1{"text"}.getStr("").len > 0 or r1{"ok"}.getBool(false)),
        $r1)
  check("the request core built was pairing-valid (provider enforced it)",
        block:
          var ok = true
          var seen = 0
          for line in logLines(mockLog):
            if line{"rejected"}.getBool(false): continue
            inc seen
            if line{"pairViolation"}.getStr("").len > 0: ok = false
          ok and seen > 0)

  # --- canonical history is untouched ------------------------------------
  let after = snapshot(nc, damaged, seeded)
  check("the stored transcript is byte-identical after the repair",
        $before == $after, "store was rewritten")
  check("the hole is still a hole (nothing fabricated into canonical history)",
        not getDoc(nc, "message", damaged & ":000004"){"ok"}.getBool(false))

  # --- the loss is durable and visible -----------------------------------
  let ledger = getDoc(nc, "toolpairrepair", damaged)
  check("the repair is recorded in the store", ledger{"ok"}.getBool(false), $ledger)
  check("the ledger names one synthesized result and one drop",
        ledger{"value"}{"count"}.getInt(0) == 2, $ledger)
  check("both repairs are attributable", block:
    var synth = false
    var drop = false
    for e in ledger{"value"}{"repaired"}:
      if e{"action"}.getStr("") == "synthesized" and
          e{"callId"}.getStr("") == "call-b" and
          e{"assistant"}.getStr("").endsWith(":000002"): synth = true
      if e{"action"}.getStr("") == "dropped" and
          e{"toolCallId"}.getStr("") == "call-gone": drop = true
    synth and drop, $ledger)
  let health = call(nc, "core", "context_status", %*{"sessionId": damaged})
  check("context_status surfaces the durable repair",
        health{"toolPairRepair"}{"count"}.getInt(0) == 2, $health)

  # --- idempotent: a second turn repairs nothing new --------------------
  let r2 = turn(nc, damaged, "again")
  check("a later turn still runs", r2{"error"}.getStr("").len == 0, $r2)
  check("the ledger does not grow on every load",
        getDoc(nc, "toolpairrepair", damaged){"value"}{"count"}.getInt(0) == 2)
  check("every request core sent stayed pairing-valid", block:
    var ok = true
    for line in logLines(mockLog):
      if line{"rejected"}.getBool(false): continue
      if line{"pairViolation"}.getStr("").len > 0: ok = false
    ok)

  # --- a healthy conversation is never "repaired" -----------------------
  const healthy = "pair-healthy"
  put(nc, "conversation", healthy,
      %*{"createdAt": epochTime(), "title": "healthy", "context": 200000})
  msg(nc, healthy, 1, %*{"role": "user", "content": "hello"})
  msg(nc, healthy, 2, %*{"role": "assistant", "content": "hello back"})
  let r3 = turn(nc, healthy, "more")
  check("a healthy conversation runs", r3{"error"}.getStr("").len == 0, $r3)
  check("no ledger is written for a healthy transcript",
        not getDoc(nc, "toolpairrepair", healthy){"ok"}.getBool(false))

  report("TOOLPAIR HEAL")

main()
