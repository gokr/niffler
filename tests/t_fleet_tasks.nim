## Hermetic two-instance Fleet smoke: real NATS/runners/store, mock model and
## local script transport (never SSH, VMs or credentials).
import std/[json, os, osproc, strutils]
import natsnim
import niffler/sdk
import helpers
import ../components/fleet/[delegation, provision]

proc rejected(body: proc()): bool =
  try: body()
  except CatchableError: return true

proc waitComponent(nc: NatsConnection, name: string): bool =
  for i in 0..<100:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 3000)
    if snap{"components"}{name} != nil: return true
    sleep(200)

proc main() =
  let repo = getCurrentDir()
  let local = newCoreSandbox("fleet-owner", ["store", "fleet", "llm", "bash"])
  let peer = newCoreSandbox("fleet-peer", ["store", "llm", "edit", "bash"])
  defer:
    removeDir(local.root)
    removeDir(peer.root)
  for s in [local, peer]:
    discard fixtureBin(s, "llm", repo / "tests/mock_llm.nim", "fixture-mock-llm")
  let (bus, url) = startNats()
  defer: stopServer(bus)
  let (otherBus, otherUrl) = startNats()
  defer: stopServer(otherBus)
  var nc = waitConnect(url)
  defer: nc.close()
  var remoteNc = waitConnect(otherUrl)
  defer: remoteNc.close()
  let cp = startComponent(local.sandboxBin("niffler"), url, local.root,
    extra = [("NIF_MOCK_ROUNDS", "0"), ("NIF_MOCK_TOOLJSON", "[]"),
      ("NIF_AGENT_WAKES", "1"), ("NIF_AGENT_NOTICE_HOLD", "1"),
      ("NIF_FLEET_TASK_WORKERS", "0"), ("NIF_RUNNER_IDLE_S", "2")],
    logFile = local.root / "var/core.log")
  defer: stopProcess(cp)
  # One scripted round, two calls, so a single peer fixture can prove BOTH
  # contracts: the store write that must stay unreachable ("fabricprog"/"bad")
  # and, for an unattended task only, a real coding tool. `put` is
  # control-plane, so it is denied in every mode; `bash` is granted only by the
  # unattended task policy below.
  let marker = peer.root / "var" / "unattended-ran"
  let rp = startComponent(peer.sandboxBin("niffler"), otherUrl, peer.root,
    extra = [("NIF_MOCK_ROUNDS", "2"), ("NIF_MOCK_TOOLJSON",
      "[{\"name\":\"put\",\"arguments\":{\"kind\":\"fabricprog\",\"id\":\"bad\",\"value\":{}}}," &
      # Round 2 writes the marker AND commits, like a developer finishing a
      # change: the notice's artifact must then name that commit.
      # The change must land INSIDE the checkout, or there is nothing to
      # commit — and the artifact would (correctly) report producedCommit
      # false. The marker alone lives outside it, on purpose.
      "{\"name\":\"bash\",\"arguments\":{\"command\":\"echo ran >> " & marker &
      " && echo changed > task.txt && git add -A && git commit -q -m 'task change'\"}}]")],
    logFile = peer.root / "var/core.log")
  defer: stopProcess(rp)
  doAssert waitComponent(nc, "fleet") and waitComponent(nc, "llm")
  doAssert waitComponent(remoteNc, "llm") and waitComponent(remoteNc, "edit")
  let c = newComponent("fleet-test-owner", "0.1.0")
  c.nc = nc
  let identity = call(remoteNc, "core", "catalog", %*{"op": "components"})
  let receipt = %*{"version": 1, "transport": "ssh", "target": "fake", "root": peer.root,
    "expect": {"instanceId": identity["instanceId"], "root": peer.root,
      "name": identity["name"], "gitHash": identity["gitHash"]}}
  let profile = local.root / "receipt.json"
  writeFile(profile, $receipt)
  setFilePermissions(profile, {fpUserRead, fpUserWrite})
  # Execute only the generated guest script locally in the isolated peer root.
  # This exercises the real CLI catalog shape and dispatch, not a guessed JSON.
  var submissions = 0
  var disconnected = false
  let run: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    doAssert argv[0] == "ssh" # inspected, never executed
    if disconnected: return CommandResult(code: 124)
    if input.contains("call 'session' ") or input.contains("call session "): inc submissions
    let script = local.root / "transport.sh"
    writeFile(script, input)
    let r = execCmdEx("bash " & quoteShell(script))
    if r.exitCode != 0:
      # Keep the last failing transport script and its output: a wrapped
      # "command failed" tells an operator nothing, and this is where the
      # peer's own words actually live.
      writeFile(local.root / "var" / "last-failed-script.sh", input)
      writeFile(local.root / "var" / "last-failed-output.txt", r.output)
    CommandResult(code: r.exitCode, output: r.output)
  var args = %*{"__session": {"session": "origin"}, "profile": profile,
    "requestId": "one", "content": "Inspect only", "cwd": peer.root,
    "tools": ["read"], "maxRounds": 3, "maxCalls": 2, "maxTokens": 10000}
  check("no model-supplied owner", rejected(proc() = discard owner(%*{"session": "origin"})))
  for tool in ["invoke", "fabric", "agent_spawn", "fleet_task_submit", "put", "bash", "core.session"]:
    let bad = args.copy(); bad["tools"] = %*[tool]
    check("refuses indirect authority " & tool, rejected(proc() = validateTask(bad)))
  for key in ["maxRounds", "maxCalls", "maxTokens"]:
    let bad = args.copy(); bad[key] = %0
    check("requires finite " & key, rejected(proc() = validateTask(bad)))
  check("malformed capabilities refuse safely", rejected(proc() = validateCapabilities(%*{}, %*{}, args)))
  block:
    # Trusted goal delegation: a goal alone validates; anything that would
    # widen authority or smuggle orchestration still refuses.
    let named = %*{"content": "goal", "cwd": peer.root, "mode": "delegate",
                   "taskProfile": "coding"}
    check("delegate refuses a named profile", rejected(proc() = validateTask(named)))
    let bare = %*{"content": "goal", "cwd": peer.root, "mode": "delegate"}
    check("delegate needs no tools or budgets", not rejected(proc() = validateTask(bare)))
    let smuggled = %*{"content": "goal", "cwd": peer.root, "mode": "delegate",
                      "tools": ["fleet_task_submit"]}
    check("delegate refuses control-plane tools", rejected(proc() = validateTask(smuggled)))
  block:
    # The worker's trust setting is resolved at birth; a machine without one
    # refuses, and enabling it is a plain store document (never a model call).
    let stalled = newCoreSandbox("fleet-delegate", ["store", "llm", "edit", "bash"])
    defer: removeDir(stalled.root)
    discard fixtureBin(stalled, "llm", repo / "tests/mock_llm.nim", "fixture-mock-llm")
    let (dbus, durl) = startNats()
    defer: stopServer(dbus)
    var dnc = waitConnect(durl)
    defer: dnc.close()
    let dp = startComponent(stalled.sandboxBin("niffler"), durl, stalled.root,
      extra = [("NIF_MOCK_ROUNDS", "0"), ("NIF_MOCK_TOOLJSON", "[]"),
        ("NIF_FLEET_TASK_WORKERS", "0")], logFile = stalled.root / "var/core.log")
    defer: stopProcess(dp)
    doAssert waitComponent(dnc, "edit")
    let refused = call(dnc, "core", "session", %*{
      "sessionId": "delegate-nosetting", "content": "do the thing",
      "task": {"delegate": true, "workspace": stalled.root}})
    # The refusal arrives as the session error text: no turn was started, which
    # is the point (never a task that waits for an approval nobody will give).
    check("a worker without a trust setting refuses a delegated goal",
      "does not accept unattended delegation" in refused{"error"}.getStr(""),
      $refused)
    # Enable it once, with a ceiling, the way an operator would.
    discard call(dnc, "store", "put", %*{"kind": "delegation",
      "id": "settings", "value": {"name": "trusted-delegation",
        "unattended": true, "tools": ["read", "bash"], "roots": [stalled.root],
        "maxRounds": 2, "maxCalls": 4, "maxTokens": 8000}})
    let admitted = call(dnc, "core", "session", %*{
      "sessionId": "delegate-setting", "content": "do the thing",
      "admission": {"key": "delegate-one"},
      "task": {"delegate": true, "workspace": stalled.root}})
    check("an enabled trust setting admits a goal with no tools/budgets",
      admitted{"admissionReplay"}.getBool(false) == false and
      admitted{"error"}.getStr("") == "", $(admitted))
    let header = call(dnc, "store", "get", %*{"kind": "conversation", "id": "delegate-setting"})
    let policy = header{"value", "taskPolicy"}
    check("the admitted policy takes the configured ceiling",
      policy != nil and policy.kind == JObject and
      policy{"profile"}.getStr("") == "trusted-delegation" and
      policy{"tools"}.len == 2 and
      policy{"budget", "maxRounds"}.getInt(0) == 2, $header)
  block:
    discard c.storePut("fleetinstance", identity["instanceId"].getStr(), receipt)
    let named = args.copy()
    named.delete("profile")
    named["instance"] = identity["name"]
    named["requestId"] = %"named-worker"
    let created = createJob(c, named)
    let pinned = c.storeGet("fleetjob", created["id"].getStr()).value
    check("named worker pins the registered receipt", pinned["receipt"] == receipt)
    discard c.requestOk("store", "del", %*{"kind": "fleetinstance", "id": identity["instanceId"]})
    check("named retry uses durable job after registry removal",
      createJob(c, named)["id"] == created["id"])
    let unknown = named.copy(); unknown["requestId"] = %"unknown-worker"
    check("unknown named worker refuses", rejected(proc() = discard createJob(c, unknown)))
    discard c.requestOk("store", "del", %*{"kind": "fleetjob", "id": created["id"]})
  block:
    let schemas = call(remoteNc, "core", "catalog",
      %*{"op": "schemas", "tools": args["tools"]})
    var coding = args.copy()
    coding["mode"] = %"unattended"
    let older = identity.copy()
    if older.hasKey("taskPolicyVersion"): older.delete("taskPolicyVersion")
    var reason = ""
    try: validateCapabilities(older, schemas, coding)
    except CatchableError as e: reason = e.msg
    check("unattended tasks refuse admission-only peers before submission",
      reason.contains("taskPolicyVersion") and submissions == 0, reason)
    let future = identity.copy()
    future["taskPolicyVersion"] = %99
    check("unattended tasks refuse unsupported task-policy versions",
      rejected(proc() = validateCapabilities(future, schemas, coding)))
    check("read-only tasks do not require unattended policy support", block:
      validateCapabilities(older, schemas, args)
      true)
    check("matching unattended policy capability is accepted", block:
      validateCapabilities(identity, schemas, coding)
      true)
  # Subscribe before submitting: the settle event is fire-and-forget, so a
  # listener that arrives late has nothing to replay (by design — the job
  # record is the truth). Collecting from here proves the real transition
  # emits, and the re-reconcile below proves it emits only once.
  var settleSub: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr settleSub, nc.conn,
                                        "ev.fleet.settled") == NATS_OK
  defer: natsSubscription_Destroy(settleSub)
  discard natsConnection_Flush(nc.conn)
  proc settleEvents(): seq[JsonNode] =
    while true:
      var msg: ptr natsMsg
      if natsSubscription_NextMsg(addr msg, settleSub, 0) != NATS_OK: break
      let env = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if env.kind == ekEvent and env.payload != nil: result.add(env.payload)

  let job = createJob(c, args)
  let id = job["id"].getStr()
  let ownedQuery = %*{"jobId": id, "__session": {"session": "origin"}}
  let status = call(nc, "fleet", "fleet_task_status", ownedQuery)
  let cached = call(nc, "fleet", "fleet_task_result", ownedQuery)
  check("status and result handlers remain distinct/local", status{"owner"}.getStr("") == "origin" and cached{"bounded"}.getBool(false), $status & " / " & $cached)
  check("owner job durable before dispatch", c.storeGet("fleetjob", id).value["state"].getStr() == "queued" and submissions == 0)
  check("identical request deduplicates", createJob(c, args)["id"].getStr() == id)
  let bad = args.copy(); bad["content"] = %"different"
  check("changed request refuses", rejected(proc() = discard createJob(c, bad)))
  let foreign = %*{"jobId": id, "__session": {"session": "foreign"}}
  check("foreign owner refuses", rejected(proc() = discard authorized(c, foreign)))
  disconnected = true
  reconcileJob(c, id, run)
  check("disconnect is not interruption/success", c.storeGet("fleetjob", id).value["state"].getStr() == "queued")
  disconnected = false
  reconcileJob(c, id, run)
  for i in 0..<20:
    if c.storeGet("fleetjob", id).value["state"].getStr() == "settled": break
    sleep(250)
    reconcileJob(c, id, run)
  let done = c.storeGet("fleetjob", id).value
  check("real remote turn settled", done["state"].getStr() == "settled", $done)

  # --- the settle EVENT (docs/FLEET-INBOX.md) ---------------------------
  # A connected client must be able to alert without polling. The event has to
  # carry enough to render a notification with no store read, and it must fire
  # exactly once per real transition (re-reading a settled job re-emits
  # nothing, or a polling client would be re-alerted forever).
  let events = settleEvents()
  var ev: JsonNode
  for e in events:
    if e{"jobId"}.getStr("") == id: ev = e
  check("a settle transition publishes ev.fleet.settled", ev != nil, $events)
  if ev != nil:
    check("the event names the peer and its objective",
          ev{"peer"}.getStr("").len > 0 and ev{"objective"}.getStr("").len > 0, $ev)
    check("the event carries the verdict inline",
          ev{"status"}.getStr("").len > 0 and
          ev{"summary"}.getStr("").len > 0, $ev)
    check("the event names the activation it reports",
          ev{"activation"}.getInt(0) >= 1, $ev)
    check("the event is not a capability grant",
          ev{"tools"} == nil and ev{"taskPolicy"} == nil and ev{"grant"} == nil,
          $ev)
  let before = events.len
  reconcileJob(c, id, run)          # already settled: early return
  check("re-reading a settled job does not re-emit the event",
        settleEvents().len == 0 and before >= 1, $before)
  check("no duplicate submission", submissions == 1, $submissions)
  let escape = call(remoteNc, "store", "get", %*{"kind": "fabricprog", "id": "bad"})
  check("model cannot use exempt store machinery", escape{"error"} != nil)
  let header = call(remoteNc, "store", "get", %*{"kind": "conversation", "id": id})["value"]
  check("remote frozen authority/budgets", header{"toolAllowlist"} == %*["read"] and header{"maxCalls"}.getInt() == 2 and header{"maxRounds"}.getInt() == 3)
  let exposure = call(remoteNc, "store", "get", %*{"kind": "session", "id": id & ":tools"})
  check("allowed on-demand tool frozen into direct schemas", ($exposure).contains("\"name\":\"read\""))
  check("bounded result summary persisted before delivery", done{"notice", "summary"}.getStr("").len <= 2051 and done{"notice", "summary"}.getStr("").len > 0)

  # --- human-scope reads: a person is not a conversation -----------------
  # The owner check keeps CONVERSATIONS apart. The inbox lists every job this
  # harness submitted, so its drill-down must be openable by the same client —
  # otherwise the UI can enumerate tasks it can never show. Found live: the
  # TUI's `/tasks <jobId>` failed with "session context required" because
  # authorized() demanded an owner the client legitimately does not have.
  block humanScope:
    check("a job read without context refuses",
          rejected(proc() = discard authorized(c, %*{"jobId": id})))
    let asHuman = c.storeGet("fleetjob", id)
    check("a human-scope read needs no session context",
          humanReadable(%*{"human": true}), "humanReadable rejected the scope")
    check("humanReadable accepts a session-carried scope too",
          humanReadable(%*{"__session": {"human": true}}))
    check("humanReadable defaults to false (conversation scope)",
          not humanReadable(%*{}))
    check("the job is readable once the scope is human", asHuman.value != nil)
    # Scope is not a capability: it changes WHO may read, never what is
    # returned. The receipt stays withheld by publicJob regardless.
    let pub = publicJob(asHuman.value)
    check("a human-scope read withholds the receipt",
          pub{"receipt"} == nil and pub{"profile"} == nil and pub{"task"} == nil, $pub)

  # --- the human inbox is a local read over fleetjob ----------------------
  # Contract (docs/FLEET-INBOX.md): a settled job is answerable from the INBOX
  # reply alone — the peer may be down, the remote transcript pruned, the
  # artifact expired — and reading never acknowledges the model's notice.
  block humanInbox:
    let inbox = taskInbox(c, newJObject())
    check("inbox lists the settled job", inbox{"count"}.getInt(0) >= 1, $inbox)
    var row: JsonNode
    for item in inbox{"items"}:
      if item{"jobId"}.getStr("") == id: row = item
    check("the job appears with its peer named", row != nil and
          row{"peer"}.getStr("").len > 0, $inbox)
    if row != nil:
      check("a settled row carries a self-contained verdict",
            row{"state"}.getStr("") == "settled" and
            row{"settled"}{"status"}.getStr("").len > 0 and
            row{"settled"}{"summary"}.getStr("").len > 0, $row)
      check("the row quotes the operator's objective",
            row{"objective"}.getStr("").len > 0, $row)
      # `notified` mirrors the RUNNER's delivery flag, which is false until it
      # appends the notice to a transcript (that happens further down, via a
      # real `origin` turn). The contract worth pinning here is that the inbox
      # EXPOSES it and does not invent a human-read marker of its own — the row
      # carries no "read"/"seen" field at all.
    # The artifact must arrive as the peer produced it. A whitelist of
    # name/mediaType/size/digest matched NONE of a coding artifact's fields
    # (version/observed/base/head/dirty/verification/headMoved/onBase/diffstat/
    # producedCommit), so the row claimed an artifact and described nothing.
    # Guarded by row != nil: an unguarded `row{"artifact"} != nil` is vacuously
    # true on a nil row, so these would never fire on the very failure they
    # exist to catch.
    if row != nil:
      # An ADVISORY task has no coding artifact: core stamps one only when a
      # task policy ran (unattended coding). So the row legitimately has none —
      # and the bug this pins is different: when there IS one, it must arrive
      # as produced, not filtered through a descriptor whitelist that matched
      # none of its fields.
      check("an advisory row carries no coding artifact",
            row{"artifact"} == nil, $row)
      if row{"artifact"} != nil and row{"artifact"}.kind == JObject:
        check("the row's artifact keeps its coding shape",
              row{"artifact"}{"version"}.getInt(0) >= 1 and
              row{"artifact"}{"observed"} != nil, $row{"artifact"})
        check("the row's artifact names a commit or says why not",
              row{"artifact"}{"head"}{"short"} != nil or
              row{"artifact"}{"reason"}.getStr("").len > 0, $row{"artifact"})
      check("the row carries no human seen marker of its own",
            row{"read"} == nil and row{"seen"} == nil and row{"unread"} == nil, $row)
      check("the row reports the runner's delivery flag verbatim",
            row{"notified"}.getBool(false) ==
              c.storeGet("fleetjob", id).value{"delivered"}.getBool(false), $row)
    # Reading is not acknowledging: the durable notice stays undelivered/
    # delivered exactly as the runner left it, never flipped by an inbox read.
    let beforeRead = c.storeGet("fleetjob", id).value{"delivered"}.getBool(false)
    discard taskInbox(c, newJObject())
    check("reading the inbox acknowledges nothing",
          c.storeGet("fleetjob", id).value{"delivered"}.getBool(false) == beforeRead)
    # Filtering keeps paging honest: a filtered page advances by id and never
    # ends early because a scanned row was rejected.
    let settledOnly = taskInbox(c, %*{"state": "settled"})
    check("state filter narrows to settled jobs",
          settledOnly{"count"}.getInt(0) >= 1 and
          settledOnly{"scanned"}.getInt(0) >= settledOnly{"count"}.getInt(0),
          $settledOnly)
    let noMatch = taskInbox(c, %*{"state": "queued"})
    check("a state with no jobs is empty, not an error", noMatch{"ok"}.getBool(false) and
          noMatch{"count"}.getInt(-1) == 0, $noMatch)
    check("an invalid state refuses",
          rejected(proc() = discard taskInbox(c, %*{"state": "bogus"})))
    # Limit + nextAfter walk the kind without loss (the reconnect contract).
    let firstPage = taskInbox(c, %*{"limit": 1})
    check("inbox caps a page", firstPage{"count"}.getInt(-1) <= 1, $firstPage)
    if firstPage{"hasMore"}.getBool(false):
      check("a truncated page carries a job-id cursor",
            firstPage{"nextAfter"}.getStr("").len > 0, $firstPage)
      check("the cursor continues the walk",
            taskInbox(c, %*{"limit": 1, "after": firstPage{"nextAfter"}.getStr("")}){"count"}.getInt(-1) >= 0)
  check("successful reconciliation clears any stale diagnostic",
    done{"reachable"}.getBool(false) and not done.hasKey("diagnostic"))
  var query = %*{"jobId": id, "__session": {"session": "origin"}}
  check("on-demand remote result", resultPage(c, query, run)["items"].len > 0)
  query["after"] = %"foreign:000001"
  check("foreign result cursor refused", rejected(proc() = discard resultPage(c, query, run)))
  # The component's serialized management pump owns delivery; jobs remain
  # durable when its transport worker is disconnected or after restart.
  let origin = call(nc, "core", "session", %*{"sessionId": "origin", "content": "Hello"}, 60000)
  check("origin turn available", origin{"error"} == nil, $origin)
  proc notices(): int =
    let page = call(nc, "store", "list", %*{"kind": "message", "idPrefix": "origin:", "limit": 100})
    for e in page["items"]:
      if e{"value", "notice", "kind"}.getStr("") == "fleet-settled": inc result
  check("runner appends actual notice", notices() == 1)
  check("runner acknowledges after append", c.storeGet("fleetjob", id).value{"delivered"}.getBool(false))
  # Re-open the crash-after-append-before-ack window. Canonical transcript
  # dedup must ack without appending a second message (even after resume).
  var item = c.storeGet("fleetjob", id)
  item.value["delivered"] = %false
  discard c.storePut("fleetjob", id, item.value, item.rev)
  sleep(3500) # idle-retire the runner: replay must dedup from durable history
  discard call(nc, "core", "session", %*{"sessionId": "origin", "wake": true}, 60000)
  check("replayed pending notice deduplicates", notices() == 1)
  proc seedNotice(job, session: string) =
    discard c.storePut("fleetjob", job, %*{"id": job, "owner": session,
      "state": "settled", "delivered": false,
      "notice": {"kind": "fleet-settled", "jobId": job, "status": "done",
        "summary": "Bounded remote report"}})
  discard call(nc, "core", "session", %*{"sessionId": "origin", "content": "Next"}, 60000)
  seedNotice("idle-settlement", "origin")
  for i in 0..<150:
    if c.storeGet("fleetjob", "idle-settlement").value{"delivered"}.getBool(false): break
    sleep(100)
  check("idle parent automatically woken", c.storeGet("fleetjob", "idle-settlement").value{"delivered"}.getBool(false))
  # The budget decline must be observed while a notice is actually pending.
  # Two timing facts make a single shot racy: `delivered` is stamped when the
  # runner appends/acks a notice BEFORE that turn finishes (so a wake turn
  # started by the previous check can still drain a freshly seeded notice),
  # and a busy runner refuses with "busy". Re-seed and retry until the runner
  # is idle with a pending notice; only then does the answer mean anything.
  var declined = newJNull()
  for attempt in 0..<100:
    var delivered = false
    try:
      delivered = c.storeGet("fleetjob", "budget-settlement").value{"delivered"}.getBool(true)
    except CatchableError:
      delivered = true  # not created yet (or already swept): (re)seed
    if delivered:
      seedNotice("budget-settlement", "origin")
    declined = call(nc, "core", "session", %*{"sessionId": "origin", "wake": true}, 60000)
    if declined{"wake"}.getStr("") == "declined": break
    sleep(100)
  check("wake budget declines with notice pending", declined{"wake"}.getStr("") == "declined" and
    not c.storeGet("fleetjob", "budget-settlement").value{"delivered"}.getBool(false), $declined)
  discard call(nc, "core", "session", %*{"sessionId": "origin", "content": "Human returned"}, 60000)
  check("human turn drains declined notice", c.storeGet("fleetjob", "budget-settlement").value{"delivered"}.getBool(false))
  # The default mock's first bash round sleeps: settlement lands mid-turn.
  let data = callEnvelope("session", %*{"sessionId": "busy-origin", "content": "Go"}).encode()
  discard natsConnection_PublishRequest(nc.conn, "svc.core.call", "_INBOX.fleet.busy", data.cstring, data.len.cint)
  sleep(500)
  seedNotice("busy-settlement", "busy-origin")
  for i in 0..<100:
    if c.storeGet("fleetjob", "busy-settlement").value{"delivered"}.getBool(false): break
    sleep(100)
  check("busy parent drains before stopping", c.storeGet("fleetjob", "busy-settlement").value{"delivered"}.getBool(false))
  # Unknown submission and no completion must never be replayed, including
  # reconciliation through a fresh Component (the restart equivalent).
  args["requestId"] = %"unknown"
  let unknownId = createJob(c, args)["id"].getStr()
  item = c.storeGet("fleetjob", unknownId)
  item.value["state"] = %"submitting"
  discard c.storePut("fleetjob", unknownId, item.value, item.rev)
  let resumed = newComponent("fleet-resumed", "0.1.0"); resumed.nc = nc
  reconcileJob(resumed, unknownId, run)
  check("restart unknown outcome never replayed", submissions == 1 and c.storeGet("fleetjob", unknownId).value["state"].getStr() == "unknown")
  args["requestId"] = %"bounded"
  args["maxRounds"] = %1
  args["maxCalls"] = %1
  let boundedId = createJob(c, args)["id"].getStr()
  reconcileJob(c, boundedId, run)
  for i in 0..<20:
    if c.storeGet("fleetjob", boundedId).value["state"].getStr() == "settled": break
    sleep(100)
    reconcileJob(c, boundedId, run)
  check("actual runner stops at round budget", c.storeGet("fleetjob", boundedId).value{"completion", "outcome"}.getStr("") == "needs-attention")
  # Identity mismatch refuses before submission; route remains pinned in job.
  args["requestId"] = %"mismatch"
  let mismatchId = createJob(c, args)["id"].getStr()
  item = c.storeGet("fleetjob", mismatchId)
  item.value["receipt"]["expect"]["instanceId"] = %repeat('f', 32)
  discard c.storePut("fleetjob", mismatchId, item.value, item.rev)
  reconcileJob(c, mismatchId, run)
  check("identity mismatch refuses dispatch", submissions == 2 and not c.storeGet("fleetjob", mismatchId).value{"reachable"}.getBool(true))
  args["requestId"] = %"cancel"
  let cancelledId = createJob(c, args)["id"].getStr()
  let cancelled = call(nc, "fleet", "fleet_task_cancel", %*{"jobId": cancelledId, "__session": {"session": "origin"}})
  check("queued cancellation settles without remote dispatch", cancelled{"state"}.getStr("") == "settled" and submissions == 2)
  let deniedCancel = call(nc, "fleet", "fleet_task_cancel", %*{"jobId": unknownId, "__session": {"session": "origin"}})
  check("uncertain remote cancellation refuses", deniedCancel{"error"} != nil)

  # Cancelling ACTIVE work asks the PEER and reports its answer. The remote
  # session id is the job's admission key — reading the settle notice for it
  # was wrong, because a running job has no notice yet, so a cancel of active
  # work could never have found its target.
  block remoteCancelTargetsTheSession:
    check("the remote session is the admission key",
          admissionKey(cancelledId) == cancelledId)
    # A dispatched job with no peer recording is "unknown", not "no session":
    # the reply must not claim a cancellation it could not deliver.
    let midFlight = call(nc, "fleet", "fleet_task_cancel",
                         %*{"jobId": unknownId, "human": true})
    check("a cancel with no known peer answer is not reported as success",
          midFlight{"error"} != nil, $midFlight)
    # A finished job cannot be cancelled and says so, rather than pretending.
    let finished = call(nc, "fleet", "fleet_task_cancel",
                        %*{"jobId": cancelledId, "human": true})
    check("an already finished task refuses cancellation",
          finished{"error"} != nil and finished{"code"}.getStr("") == "not-active",
          $finished)

  # --- F2: one unattended coding task through the requester ---------------
  # The peer operator permits bash in its checkout; the requesting conversation
  # approves read+bash for this exact task. The model's control-plane store
  # write must still fail while its bash call actually runs.
  let peerWorkspace = peer.root / "checkout"
  createDir(peerWorkspace)
  # A real checkout, so the notice's artifact can name a commit the task made
  # (docs/FLEET.md §6) instead of only describing the work in prose.
  for cmd in ["init -q -b main", "config user.email task@example.test",
              "config user.name task"]:
    let r = execCmdEx("git -C " & quoteShell(peerWorkspace) & " " & cmd)
    doAssert r.exitCode == 0, "git " & cmd & ": " & r.output
  writeFile(peerWorkspace / "seed.txt", "seed\n")
  discard execCmdEx("git -C " & quoteShell(peerWorkspace) & " add -A")
  discard execCmdEx("git -C " & quoteShell(peerWorkspace) &
    " commit -q -m 'base'")
  let peerBase = execCmdEx(
    "git -C " & quoteShell(peerWorkspace) & " rev-parse HEAD").output.strip()
  discard call(remoteNc, "store", "put", %*{"kind": "taskprofile",
    "id": "coding", "value": {"name": "coding", "unattended": true,
      "tools": ["read", "bash", "edit"], "roots": [peerWorkspace],
      "maxRounds": 3, "maxCalls": 8, "maxTokens": 20000,
      "confinement": "unconfined"}})
  # The read-only slice still refuses a coding tool: mode is opt-in, and a
  # caller cannot get shell by relabeling a read-only task.
  let sneaky = args.copy()
  sneaky["requestId"] = %"sneaky-bash"
  sneaky["tools"] = %*["read", "bash"]
  check("read-only mode refuses a coding tool",
    rejected(proc() = validateTask(sneaky)))
  # Control-plane machinery is refused in unattended mode too.
  let controlPlane = args.copy()
  controlPlane["requestId"] = %"control-plane"
  controlPlane["mode"] = %"unattended"
  controlPlane["tools"] = %*["read", "fleet_task_submit"]
  check("unattended mode refuses control-plane tools",
    rejected(proc() = validateTask(controlPlane)))

  var unattended = args.copy()
  unattended["requestId"] = %"code-it"
  unattended["mode"] = %"unattended"
  unattended["taskProfile"] = %"coding"
  unattended["content"] = %"Write a marker in the checkout."
  unattended["cwd"] = %peerWorkspace
  unattended["tools"] = %*["read", "bash"]
  # Explicit budgets: an earlier scenario narrowed the shared `args` to one
  # call, which cannot cover the two scripted rounds below.
  unattended["maxRounds"] = %3
  unattended["maxCalls"] = %8
  unattended["maxTokens"] = %10000
  let codingJob = createJob(c, unattended)
  let codingId = codingJob["id"].getStr()
  check("an unattended task is recorded as such before dispatch",
    c.storeGet("fleetjob", codingId).value{"task", "mode"}.getStr("") ==
      "unattended")
  let submissionsBeforeTask = submissions
  disconnected = false
  reconcileJob(c, codingId, run)
  for i in 0..<40:
    if c.storeGet("fleetjob", codingId).value["state"].getStr() == "settled": break
    sleep(250)
    reconcileJob(c, codingId, run)
  let coding = c.storeGet("fleetjob", codingId).value
  check("the unattended task settles from the worker's receipt",
    coding["state"].getStr() == "settled", $coding)
  check("the coding tool really ran on the peer",
    fileExists(marker), "no marker written")
  check("the model still cannot reach control-plane store machinery",
    call(remoteNc, "store", "get", %*{"kind": "fabricprog", "id": "bad"}){"error"} != nil)
  check("the notice reports the effective policy and confinement honestly",
    coding{"notice", "confinement"}.getStr("") == "unconfined" and
    coding{"notice", "taskPolicyDigest"}.getStr("").startsWith("sha256:"), $coding)
  # The result is the CHANGE, not just a description of it. Without this, a
  # requester could only take the summary's word for what happened.
  check("the notice carries the coding artifact",
    coding{"notice", "artifact", "version"}.getInt(0) == 1, $coding)
  check("the artifact names the base the task started from",
    coding{"notice", "artifact", "base", "commit"}.getStr("") == peerBase, $coding)
  check("the artifact reports the commit the task produced",
    coding{"notice", "artifact", "producedCommit"}.getBool(false) and
    coding{"notice", "artifact", "head", "short"}.getStr("").len >= 7, $coding)
  check("the artifact renders a one-line summary for a human",
    coding{"notice", "artifactSummary"}.getStr("").contains("commit"), $coding)
  check("the unattended submission was not replayed",
    submissions == submissionsBeforeTask + 1, $submissions)

  # --- the artifact must survive into the INBOX ROW ----------------------
  # This is the regression the whitelist bug needed and did not have: the row
  # used to copy only name/mediaType/size/digest, none of which a coding
  # artifact has, so it claimed an artifact and described nothing. Asserting on
  # the STORED notice (above) could never catch that — the damage happened when
  # building the row.
  block inboxArtifact:
    let inbox = taskInbox(c, %*{"state": "settled"})
    var row: JsonNode
    for item in inbox{"items"}:
      if item{"jobId"}.getStr("") == codingId: row = item
    check("the coding task appears in the inbox", row != nil, $inbox)
    if row != nil:
      let art = row{"artifact"}
      check("the row carries the artifact object", art != nil and art.kind == JObject, $row)
      if art != nil and art.kind == JObject:
        check("the row's artifact is the one the peer produced",
              art{"version"}.getInt(0) == 1 and
              art{"base", "commit"}.getStr("") == peerBase, $art)
        check("the row's artifact names the commit, not a media descriptor",
              art{"producedCommit"}.getBool(false) and
              art{"head", "short"}.getStr("").len >= 7, $art)
        check("the row's artifact keeps the human one-liner",
              art{"summary"}.getStr("").contains("commit"), $art)
        check("the row's artifact is not a name/size descriptor shell",
              art{"name"} == nil and art{"mediaType"} == nil, $art)
    # And the settle EVENT carries the same, so a toast can say what changed.
    var eventArtifact: JsonNode
    for e in settleEvents():
      if e{"jobId"}.getStr("") == codingId: eventArtifact = e{"artifact"}
    check("the settle event carries the coding artifact too",
          eventArtifact != nil and eventArtifact{"producedCommit"}.getBool(false),
          $eventArtifact)
  # --- trusted goal delegation, through the REAL submission seam ----------
  # The simplification's promise (docs/FLEET-SIMPLIFICATION.md) is a goal, no
  # profile, no mandatory tools or budgets. The unit tests above prove the
  # resolver; this proves the seam that actually broke before (fleet_task_submit
  # → the peer's own birth-policy resolution → a prose report), including the
  # refusal path when the worker has not enabled delegation.
  block delegatedGoal:
    discard c.storePut("fleetinstance", identity["instanceId"].getStr(), receipt)
    let goalArgs = %*{"__session": {"session": "goal-owner"},
      "instance": identity["name"].getStr(),
      "requestId": "goal-1", "mode": "delegate",
      "content": "Solve the goal and report what you did", "cwd": peer.root}
    # No `tools`, no `maxRounds`/`maxCalls`/`maxTokens`: validation alone used
    # to require them, so this is the compatibility promise under test.
    let goalId = createJob(c, goalArgs)["id"].getStr()
    check("a goal is creatable with no tools or budgets",
          c.storeGet("fleetjob", goalId).value{"task", "mode"}.getStr() ==
            "delegate")
    # 1. The peer has NOT enabled delegation: the job must not settle as work,
    #    and no remote turn may have run. `unknown` with a diagnostic is the
    #    honest outcome; a settled job or a silently dropped refusal is not.
    reconcileJob(c, goalId, run)
    let blocked = c.storeGet("fleetjob", goalId).value
    check("a peer without a trust setting does not run the goal",
          blocked["state"].getStr() != "settled" and
          blocked{"admissionReceipt"} == nil, $blocked)
    # 2. The operator enables it once (a store document on the worker, never a
    #    model call), then the same goal completes under that ceiling.
    discard call(remoteNc, "store", "put", %*{"kind": "delegation",
      "id": "settings", "value": {"name": "trusted-delegation",
        "unattended": true, "tools": ["read", "bash"],
        "roots": [peer.root], "maxRounds": 6, "maxCalls": 20,
        "maxTokens": 60000}})
    let openId = createJob(c, %*{"__session": {"session": "goal-owner"},
      "instance": identity["name"].getStr(),
      "requestId": "goal-2", "mode": "delegate",
      "content": "Solve the goal and report what you did",
      "cwd": peer.root})["id"].getStr()
    for _ in 0..<24:
      reconcileJob(c, openId, run)
      if c.storeGet("fleetjob", openId).value["state"].getStr() == "settled": break
      sleep(200)
    let goal = c.storeGet("fleetjob", openId).value
    check("a goal completes under the worker's own trust ceiling",
          goal["state"].getStr() == "settled", $goal)
    check("the goal's result is a prose report",
          goal{"report"}.getStr("").len > 0, $goal)
    let goalHeader = call(remoteNc, "store", "get",
      %*{"kind": "conversation", "id": openId})["value"]
    let resolved = goalHeader{"taskPolicy"}
    check("the worker resolved the ceiling, not the requester",
          resolved != nil and
          resolved{"profile"}.getStr("") == "trusted-delegation" and
          resolved{"tools"}.len == 2 and
          resolved{"budget", "maxRounds"}.getInt(0) == 6, $goalHeader)
    # The goal is now readable as a report through the same tool the TUI uses.
    let page = reportPage(c.storeGet("fleetjob", openId).value, newJObject())
    check("the completed goal's report is pageable without the peer",
          page["report"].getStr("").len > 0, $page)
    # --- slice 3: continue the SAME worker conversation -------------------
    # The point of delegating to a machine you trust: "now address the review
    # comments". The follow-up keeps the parent's remote session (so the worker
    # still has the context it built), gets its OWN admission key, and may
    # change only the instruction.
    let settledParent = c.storeGet("fleetjob", openId).value
    # Rules first, so a bad continuation never reaches the peer.
    let widened = %*{"content": "do more", "cwd": "/elsewhere"}
    check("a follow-up may not retarget the workspace", rejected(proc() =
      validateContinuation(settledParent, widened)))
    let tooled = %*{"content": "do more", "tools": ["bash"]}
    check("a follow-up may not widen the tool set", rejected(proc() =
      validateContinuation(settledParent, tooled)))
    check("a follow-up needs an instruction", rejected(proc() =
      validateContinuation(settledParent, %*{"content": ""})))
    var unrunnable = settledParent.copy()
    unrunnable["state"] = %"running"
    check("an unfinished goal cannot be continued", rejected(proc() =
      validateContinuation(unrunnable, %*{"content": "do more"})))
    let contArgs = %*{"__session": {"session": "goal-owner"},
      "jobId": openId, "requestId": "goal-followup",
      "content": "Now address the review comments"}
    let contId = continueJob(c, contArgs)["id"].getStr()
    let contJob = c.storeGet("fleetjob", contId).value
    check("the follow-up targets the parent's remote conversation",
          contJob["sessionId"].getStr("") == openId and
          contJob{"parentJob"}.getStr("") == openId, $contJob)
    check("the follow-up reuses the parent's pinned route",
          contJob["receipt"] == settledParent["receipt"])
    check("the follow-up is its own activation key",
          contJob{"admission", "key"}.getStr("") != openId)
    check("a follow-up retry is idempotent",
          continueJob(c, contArgs)["id"].getStr("") == contId)
    for _ in 0..<24:
      reconcileJob(c, contId, run)
      if c.storeGet("fleetjob", contId).value["state"].getStr() == "settled": break
      sleep(200)
    let cont = c.storeGet("fleetjob", contId).value
    check("the continued goal settles",
          cont["state"].getStr() == "settled", $cont)
    check("its result is attributed to the follow-up activation",
          cont{"completion", "source"}.getStr("") == "worker-admission", $cont)
    check("the parent's own report is untouched",
          c.storeGet("fleetjob", openId).value{"report"}.getStr("") ==
            settledParent{"report"}.getStr(""))
    discard c.requestOk("store", "del", %*{"kind": "fleetjob", "id": contId})
    discard c.requestOk("store", "del",
      %*{"kind": "fleetinstance", "id": identity["instanceId"].getStr()})
    # These jobs are fixtures of THIS block, and a settled-undelivered job
    # keeps waking its owner. Left in place they would add wake traffic the
    # later notice tests do not account for (observed as a spurious "conversation
    # is mid-turn" on the origin turn). Remove them; the assertions above already
    # read what they needed.
    for fixture in [goalId, openId]:
      discard c.requestOk("store", "del", %*{"kind": "fleetjob", "id": fixture})


  report("FLEET TASKS TEST")

main()
