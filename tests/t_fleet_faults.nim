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
  let run: CommandRunner = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    var r: JsonNode
    # The identity probe and the capability probe issue the same CLI call, so
    # one reply carries both contracts: provision.probe reads the identity
    # fields, validateCapabilities reads taskScopeVersion/components.
    if input.contains("\"op\":\"components\""):
      r = identity.copy()
      r["taskScopeVersion"] = %1
      r["components"] = %*{"core": ["session", "session_prepare", "get", "list", "catalog"], "edit": ["read"]}
    elif input.contains("\"op\":\"schemas\""):
      r = %*{"tools": [{"name": "read", "schema": {"type": "object", "x-harness": {"effect": "read"}}}]}
    elif input.contains("'op'"): r = %*{}
    elif input.contains("call session ") or input.contains("call 'session' "):
      inc submissions; r = %*{"ok": true}
    elif input.contains("\"kind\":\"activity\""):
      r = %*{"items": [{"id": id, "value": {"sessionId": id, "seq": 1, "outcome": "done"}}]}
    elif input.contains("\"kind\":\"message\""):
      let middle = if runtimeBoundary: %*{"role": "user", "notice": {"kind": "fleet-settled"}} else: %*{"role": "user", "content": "steer"}
      r = %*{"items": [{"id": id & ":1", "value": {"role": "user", "content": "task"}},
        {"id": id & ":2", "value": middle}, {"id": id & ":3", "value": {"role": "assistant", "content": "final report"}}]}
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
  let reconciled = c.storeGet("fleetjob", id).value
  check("first successful reconciliation has no false transport error",
    reconciled{"reachable"}.getBool(false) and not reconciled.hasKey("diagnostic"))
  check("unmarked steering yields honest unavailable summary", c.storeGet("fleetjob", id).value["notice"]["summary"].getStr().contains("unavailable"))
  var item = c.storeGet("fleetjob", id)
  item.value["state"] = %"unknown"
  discard c.storePut("fleetjob", id, item.value, item.rev)
  runtimeBoundary = true
  reconcileJob(c, id, run)
  check("runtime notice does not end activation summary", c.storeGet("fleetjob", id).value["notice"]["summary"].getStr() == "final report" and submissions == 1)
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
