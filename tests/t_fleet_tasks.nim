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
  check("no duplicate submission", submissions == 1, $submissions)
  let escape = call(remoteNc, "store", "get", %*{"kind": "fabricprog", "id": "bad"})
  check("model cannot use exempt store machinery", escape{"error"} != nil)
  let header = call(remoteNc, "store", "get", %*{"kind": "conversation", "id": id})["value"]
  check("remote frozen authority/budgets", header{"toolAllowlist"} == %*["read"] and header{"maxCalls"}.getInt() == 2 and header{"maxRounds"}.getInt() == 3)
  let exposure = call(remoteNc, "store", "get", %*{"kind": "session", "id": id & ":tools"})
  check("allowed on-demand tool frozen into direct schemas", ($exposure).contains("\"name\":\"read\""))
  check("bounded result summary persisted before delivery", done{"notice", "summary"}.getStr("").len <= 2051 and done{"notice", "summary"}.getStr("").len > 0)
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
  report("FLEET TASKS TEST")

main()
