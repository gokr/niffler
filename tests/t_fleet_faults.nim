## Record/dispatch/append/ack crash windows with a real NATS fault store.
import std/[json, os, strutils, tables]
import natsnim
import niffler/sdk
import helpers
import ../components/fleet/[delegation, provision]
import ../core/[conversation, dispatch, catalog]
proc rejected(body: proc()): bool =
  try: body()
  except CatchableError: return true
proc main() =
  let root = getCurrentDir() / "var" / ("fleet-faults-" & $getCurrentProcessId())
  createDir(root)
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let fixture = getCurrentDir() / "var/bin/fixture-fleet-fault-store"
  let sp = startComponent(fixture, url, root)
  defer: stopProcess(sp)
  sleep(300)
  let c = newComponent("fault-test", "0.1.0"); c.nc = nc
  let identity = %*{"instanceId": repeat('a', 32), "root": "/srv/peer", "name": "peer", "gitHash": "abc"}
  let receipt = %*{"version": 1, "transport": "ssh", "target": "fake", "root": "/srv/peer", "expect": identity}
  let profile = root / "receipt.json"
  writeFile(profile, $receipt); setFilePermissions(profile, {fpUserRead, fpUserWrite})
  var a = %*{"__session": {"session": "origin"}, "requestId": "first", "profile": profile,
    "content": "read", "cwd": "/srv/peer", "tools": ["read"], "maxRounds": 2, "maxCalls": 2, "maxTokens": 10000}
  proc fault(v: JsonNode) = writeFile(root / "fault.json", $v)
  fault(%*{"state": "queued"})
  check("failed initial commit refuses", rejected(proc() = discard createJob(c, a)))
  check("failed initial create leaves no dispatchable job", c.storeListAll("fleetjob").len == 0)
  fault(%*{})
  let id = createJob(c, a)["id"].getStr()
  # Atomic create must refuse overwriting even if another process read absence.
  check("create-only race refuses overwrite", rejected(proc() = discard c.storePut("fleetjob", id, %*{"owner": "foreign"}, -1)))
  check("create-only preserves owner", c.storeGet("fleetjob", id).value["owner"].getStr() == "origin")
  var submissions = 0
  var runtimeBoundary = false
  var workerSettled = false
  # The fixture answers about whichever job the request names, not one captured
  # id: reconciliation happens for several distinct jobs in this test, and a
  # reply carrying the wrong session id must fail the requester's own
  # foreign-transcript check (that check is itself a contract worth keeping).
  var answerId = id
  let run: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    var r: JsonNode
    let asked = block:
      var found = answerId
      for probe in ["\"sessionId\":\"", "\"idPrefix\":\""]:
        let at = input.find(probe)
        if at >= 0:
          let rest = input[at + probe.len .. ^1]
          let stop = rest.find('"')
          if stop > 0: found = rest[0 ..< stop]
          break
      found
    # The identity probe and the capability probe issue the same CLI call, so
    # one reply carries both contracts: provision.probe reads the identity
    # fields, validateCapabilities reads taskScopeVersion/components.
    if input.contains("\"op\":\"components\""):
      r = identity.copy()
      r["taskScopeVersion"] = %1
      # Durable admission (docs/FLEET.md §4): a peer without it is refused
      # before dispatch, so the fixture advertises the capability and answers
      # the requester's post-submission receipt read.
      r["admissionPolicyVersion"] = %1
      r["components"] = %*{"core": ["session", "session_prepare", "admission_get", "get", "list", "catalog"], "edit": ["read"]}
    elif input.contains("\"op\":\"schemas\""):
      r = %*{"tools": [{"name": "read", "schema": {"type": "object", "x-harness": {"effect": "read"}}}]}
    elif input.contains("'op'"): r = %*{}
    elif input.contains("call admission_get") or input.contains("call 'admission_get'"):
      # The worker's own receipt for this activation. `workerSettled` models the
      # case the seam exists for: the submission reply was lost, yet the worker
      # admitted the turn and finished it — the requester must reconcile from
      # this receipt instead of replaying.
      let session = (if input.contains("admission_get"): asked else: input)
      if workerSettled:
        r = %*{"ok": true, "known": true, "state": "settled", "ageSeconds": 2.0,
          "admission": {"id": session & ":k", "sessionId": session, "key": "k",
            "activation": 1, "state": "settled", "turnId": "turn-worker-1",
            "outcome": "done", "transcriptCommitted": true}}
      else:
        r = %*{"ok": true, "known": true, "state": "running", "ageSeconds": 0.0,
          "admission": {"id": session & ":k", "sessionId": session, "key": "k",
            "activation": 1, "state": "running"}}
    elif input.contains("call session ") or input.contains("call 'session' "):
      inc submissions; r = %*{"ok": true}
    elif input.contains("\"kind\":\"activity\""):
      r = %*{"items": [{"id": asked, "value": {"sessionId": asked, "seq": 1, "outcome": "done"}}]}
    elif input.contains("\"kind\":\"message\""):
      let middle = if runtimeBoundary: %*{"role": "user", "notice": {"kind": "fleet-settled"}} else: %*{"role": "user", "content": "steer"}
      r = %*{"items": [{"id": asked & ":1", "value": {"role": "user", "content": "task"}},
        {"id": asked & ":2", "value": middle}, {"id": asked & ":3", "value": {"role": "assistant", "content": "final report"}}]}
    else: r = %*{"items": [], "ok": true}
    CommandResult(output: $r)
  fault(%*{"state": "submitting"})
  check("failed submitting commit refuses", rejected(proc() = reconcileJob(c, id, run)),
    $c.storeGet("fleetjob", id).value)
  check("failed submitting starts no turn or stale diagnostic write", submissions == 0 and c.storeGet("fleetjob", id).value["state"].getStr() == "queued")
  fault(%*{"state": "settled"})
  check("failed terminal commit refuses", rejected(proc() = reconcileJob(c, id, run)))
  check("no durable terminal means no deliverable notice", taskNotices(c, %*{"session": "origin"})["count"].getInt() == 0 and submissions == 1)
  fault(%*{})
  reconcileJob(c, id, run)
  check("unmarked steering yields honest unavailable summary", c.storeGet("fleetjob", id).value["notice"]["summary"].getStr().contains("unavailable"))
  var item = c.storeGet("fleetjob", id)
  item.value["state"] = %"unknown"
  discard c.storePut("fleetjob", id, item.value, item.rev)
  runtimeBoundary = true
  reconcileJob(c, id, run)
  check("runtime notice does not end activation summary", c.storeGet("fleetjob", id).value["notice"]["summary"].getStr() == "final report" and submissions == 1)
  # --- the F1 seam: a LOST submission reply, reconciled without a replay ----
  # The job is left `submitting` (exactly what a crash or a lost reply does) and
  # the worker reports a settled admission. Reconciliation must adopt that
  # receipt — one activation, no second submission — and the resulting notice
  # must still be deliverable.
  # These two jobs belong to their own requester conversation: a pending notice
  # for "origin" would otherwise join the drain assertions further down.
  a["requestId"] = %"lost-reply"
  a["__session"] = %*{"session": "reconciler"}
  let lostId = createJob(c, a)["id"].getStr()
  item = c.storeGet("fleetjob", lostId)
  item.value["state"] = %"submitting"
  discard c.storePut("fleetjob", lostId, item.value, item.rev)
  let submissionsBefore = submissions
  workerSettled = true
  reconcileJob(c, lostId, run)
  let reconciled = c.storeGet("fleetjob", lostId).value
  check("a settled worker receipt reconciles a lost submission reply",
    reconciled["state"].getStr() == "settled" and
    reconciled["completion"]["turnId"].getStr() == "turn-worker-1" and
    reconciled["completion"]["source"].getStr() == "worker-admission",
    $reconciled)
  check("reconciliation never submits the uncertain task again",
    submissions == submissionsBefore, $submissions)
  check("the reconciled activation produces a deliverable notice",
    reconciled["owner"].getStr() == "reconciler" and
    reconciled["notice"]["activation"].getInt() == 1 and
    reconciled["notice"]["transcriptCommitted"].getBool(false) and
    not reconciled["delivered"].getBool(true) and
    taskNotices(c, %*{"session": "reconciler"})["count"].getInt() == 1)
  workerSettled = false
  # A worker that knows NO admission answers `known:false`; the job stays
  # unknown rather than becoming a success or a failure.
  a["requestId"] = %"no-admission"
  let absentId = createJob(c, a)["id"].getStr()
  item = c.storeGet("fleetjob", absentId)
  item.value["state"] = %"unknown"
  if item.value.hasKey("admissionReceipt"): item.value.delete("admissionReceipt")
  discard c.storePut("fleetjob", absentId, item.value, item.rev)
  let submissionsAbsent = submissions
  reconcileJob(c, absentId, run)
  check("an unknown worker admission stays unknown, never a replay",
    submissions == submissionsAbsent)

  # Real runner drain, with a fake catalog router only for the inbox endpoint.
  let cat = newCatalog(nc)
  cat.applyReg(%*{"name": "fleet", "version": "0.1.0", "tools": [{"name": "fleet_notices", "schema": {"type": "object", "x-harness": {"hidden": true, "runner": true}}}]})
  # Serve fleet inbox in a separate process by using fleet itself, workers off.
  let fp = startComponent(getCurrentDir() / "var/bin/fleet", url, root,
    extra = [("NIF_FLEET_TASK_WORKERS", "0")])
  defer: stopProcess(fp)
  sleep(300)
  var ct = CoreTools(nc: nc, cat: cat, root: root)
  var p = newPersister(ct)
  p.convId = "origin"
  var messages: seq[JsonNode]
  fault(%*{"message": true})
  discard drainNotices(ct, p, messages, nil)
  check("failed notice append never acks", not c.storeGet("fleetjob", id).value{"delivered"}.getBool(false))
  fault(%*{"ack": true})
  discard drainNotices(ct, p, messages, nil)
  check("failed ack keeps pending after successful append", not c.storeGet("fleetjob", id).value{"delivered"}.getBool(false) and c.storeListAll("message").len == 1)
  # Simulate runner restart and compacted projection: only canonical records
  # remain, no in-memory dedup. Durable scan must acknowledge without append.
  fault(%*{})
  var resumed = newPersister(ct)
  resumed.convId = "origin"
  resumed.seqNo = 2
  var emptyProjection: seq[JsonNode]
  discard drainNotices(ct, resumed, emptyProjection, nil)
  check("restart canonical dedup repairs lost ack", c.storeGet("fleetjob", id).value{"delivered"}.getBool(false) and c.storeListAll("message").len == 1)
  check("foreign owner cannot ack", taskNotices(c, %*{"session": "foreign", "ack": id})["count"].getInt() == 0)
  report("FLEET FAULTS TEST")
main()
