## End-to-end durable admission (docs/FLEET.md §4, slice F1) against a REAL
## store and session runner, with the mock model: no SSH, VM or provider.
##
## The contract under test is the one a requester with a lost reply depends on:
##
## - the admission record is durable BEFORE the turn starts (so a crash can
##   never leave work that was never admitted);
## - an exact retry returns the existing accepted/terminal receipt and runs
##   NO second turn (a real model call count pins that, not a flag);
## - a different birth policy under the same key is refused (accepted work is
##   immutable);
## - a record left `running` refuses rather than guessing, and its read-only
##   introspection (`admission_get`) answers for the requester.
import std/[json, os, strutils]
import natsnim

import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc main() =
  let repo = getCurrentDir()
  let sandbox = newCoreSandbox("fleet-adm", ["store", "llm", "bash"])
  defer: removeDir(sandbox.root)
  let llmLog = sandbox.root / "var" / "llm-requests.jsonl"
  discard fixtureBin(sandbox, "llm", repo / "tests/mock_llm.nim",
                     "fixture-mock-llm")
  let (bus, url) = startNats()
  defer: stopServer(bus)
  var nc = waitConnect(url)
  defer: nc.close()
  let core = startComponent(sandbox.sandboxBin("niffler"), url, sandbox.root,
    extra = [("NIF_MOCK_ROUNDS", "0"), ("NIF_MOCK_TOOLJSON", "[]"),
             ("NIF_MOCK_LOG", llmLog), ("NIF_RUNNER_IDLE_S", "600")],
    logFile = sandbox.root / "var/core.log")
  defer: stopProcess(core)
  doAssert waitComponent(nc, "llm")

  proc modelCalls(): int =
    ## Real provider round trips this harness has made — the only honest
    ## proof that a replay ran no second turn.
    if not fileExists(llmLog): return 0
    for line in readFile(llmLog).splitLines():
      if line.strip().len > 0: inc result

  let session = "admission-" & $getCurrentProcessId()
  let content = "Report the state of the workspace."
  proc submit(key: string, extraTools: JsonNode = nil,
              policy = 1): JsonNode =
    var args = %*{"sessionId": session, "content": content,
      "admission": {"key": key, "policyVersion": policy}}
    if extraTools != nil: args["tools"] = extraTools
    call(nc, "core", "session", args, 120_000)

  # --- a fresh admitted turn ------------------------------------------------
  let first = submit("act-1")
  check("admitted turn runs and reports its receipt",
        first{"error"} == nil and
        first{"admission", "state"}.getStr("") == "settled",
        $first)
  # Each mock turn makes TWO provider round trips by default (a scripted bash
  # round, then the final answer), so the baseline is measured, not assumed:
  # what matters everywhere below is that a replay/refusal adds none.
  let callsAfterFirst = modelCalls()
  check("an admitted turn reaches the provider", callsAfterFirst > 0,
        $callsAfterFirst)
  let admissionId = session & ":act-1"
  let stored = call(nc, "store", "get", %*{"kind": "admission",
                                           "id": admissionId})
  check("the admission record is durable under session:key",
        stored{"ok"}.getBool(false) and
        stored{"value", "state"}.getStr("") == "settled", $stored)
  check("the receipt binds the activation's turn, outcome and usage",
        stored{"value", "turnId"}.getStr("").len > 0 and
        stored{"value", "outcome"}.getStr("") == "done" and
        stored{"value", "usage", "turnId"}.getStr("") ==
          stored{"value", "turnId"}.getStr("") and
        stored{"value", "transcriptCommitted"}.getBool(false), $stored)

  # --- exact retry: same key, same work, NO second turn ---------------------
  let replay = submit("act-1")
  check("an exact retry replays the receipt instead of running again",
        replay{"admissionReplay"}.getBool(false) and
        replay{"admission", "turnId"}.getStr("") ==
          stored{"value", "turnId"}.getStr(""), $replay)
  check("the replay spent no provider round trip", modelCalls() == callsAfterFirst)

  # --- same key, different work: refused, and nothing runs -----------------
  var wider = %*{"sessionId": session, "content": content,
    "admission": {"key": "act-1", "policyVersion": 1},
    "tools": ["read", "grep"]}
  let conflated = call(nc, "core", "session", wider, 120_000)
  check("a different birth policy under an accepted key is refused",
        conflated{"error"} != nil and
        conflated{"error"}.getStr("").contains("different work"), $conflated)
  check("the refusal ran no turn", modelCalls() == callsAfterFirst)

  # --- policy version negotiation ------------------------------------------
  let future = submit("act-future", policy = 99)
  check("a future admission policy version is refused before any turn",
        future{"error"} != nil and modelCalls() == callsAfterFirst, $future)

  # --- malformed keys and non-turns ----------------------------------------
  for bad in ["", "has space"]:
    let refused = submit(bad)
    check("bad admission key refused: '" & bad & "'",
          refused{"error"} != nil and modelCalls() == callsAfterFirst)
  let wake = call(nc, "core", "session",
    %*{"sessionId": session, "wake": true,
       "admission": {"key": "act-wake"}}, 60_000)
  check("a wake cannot be admitted", wake{"error"} != nil, $wake)
  let empty = call(nc, "core", "session",
    %*{"sessionId": session, "content": "",
       "admission": {"key": "act-empty"}}, 60_000)
  check("an admitted turn needs content", empty{"error"} != nil, $empty)

  # --- a record left `running` refuses to run twice ------------------------
  let runningId = session & ":act-running"
  let stored2 = call(nc, "store", "put", %*{"kind": "admission",
    "id": runningId, "value": {"id": runningId, "sessionId": session,
      "key": "act-running", "activation": 1, "digest": "sha256:other",
      "policyVersion": 1, "state": "running", "acceptedAt": 1.0},
    "expectRev": -1})
  check("a pre-existing running record was seeded", stored2{"ok"}.getBool(false))
  let busy = submit("act-running")
  check("an already-started activation refuses instead of repeating it",
        busy{"error"} != nil, $busy)
  check("the refusal spent no provider round trip",
        modelCalls() == callsAfterFirst)

  # --- read-only introspection for a requester that lost the reply --------
  let read = call(nc, "core", "admission_get",
    %*{"session": session, "key": "act-1"}, 10_000)
  check("admission_get answers for a settled activation",
        read{"known"}.getBool(false) and
        read{"state"}.getStr("") == "settled" and
        read{"admission", "turnId"}.getStr("") ==
          stored{"value", "turnId"}.getStr(""), $read)
  let unknown = call(nc, "core", "admission_get",
    %*{"session": session, "key": "never-submitted"}, 10_000)
  check("an unknown admission is explicitly unknown, not an outcome",
        not unknown{"known"}.getBool(true) and unknown{"error"} == nil and
        unknown{"note"}.getStr("").len > 0, $unknown)
  let badRead = call(nc, "core", "admission_get",
    %*{"session": session, "key": "bad key"}, 10_000)
  check("admission_get validates the key shape", badRead{"error"} != nil)
  report("FLEET ADMISSION E2E TEST")

main()
