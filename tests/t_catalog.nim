## Catalog admission must not crash on malformed registrations or publish
## a UI notification before its durable slash-table checkpoint.

import std/[json, os, strutils, tables]
import natsnim
import ../core/catalog
import helpers

proc main() =
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let cat = newCatalog(nc)
  var updates: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr updates, nc.conn,
    "ev.catalog.updated") == NATS_OK
  defer: natsSubscription_Destroy(updates)
  var checkpoints = 0
  cat.onChange = proc(c: Catalog) =
    inc checkpoints
    doAssert natsConnection_FlushTimeout(nc.conn, 1000) == NATS_OK
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, updates, 100)
    check("checkpoint precedes catalog event", st == NATS_TIMEOUT)
    if st == NATS_OK: natsMsg_Destroy(msg)
  for tools in [%*{}, %"wrong", newJNull(), %*[1],
                %*[{"name": "duplicate"}, {"name": "duplicate"}]]:
    cat.applyReg(%*{"name": "invalid", "pid": 1, "tools": tools})
    check("invalid registration rejected atomically",
      not cat.components.hasKey("invalid") and
      not cat.toolIndex.hasKey("duplicate"))
  check("rejected registrations do not announce", checkpoints == 0)
  cat.applyReg(%*{"name": "valid", "pid": 2,
    "tools": [{"name": "valid_tool", "schema": {"type": "object"}}]})
  check("valid registration still accepted", cat.components.hasKey("valid"))
  check("valid registration checkpointed", checkpoints == 1)
  var msg: ptr natsMsg
  let st = natsSubscription_NextMsg(addr msg, updates, 1000)
  check("catalog event follows checkpoint", st == NATS_OK)
  if st == NATS_OK: natsMsg_Destroy(msg)

  # Client reaping: interactive clients are external processes with no
  # supervisor to match their pid, so a hard-exited TUI must be swept by
  # pid liveness (a 2^30 pid is beyond any platform's pid_max — certainly
  # dead; the test process itself is certainly alive). A FRESH catalog keeps
  # these announces away from the strict checkpoint assertions above; the
  # sweep runs on the system catalog only (marked by its onChange hook), so
  # give cat2 a no-op one.
  let cat2 = newCatalog(nc)
  cat2.onChange = proc(c: Catalog) = discard
  cat2.applyReg(%*{"name": "tui-dead", "pid": 1 shl 30, "client": true})
  cat2.applyReg(%*{"name": "tui-alive", "pid": getCurrentProcessId(),
                   "client": true})
  check("dead client registered before the sweep",
        cat2.components.hasKey("tui-dead"))
  cat2.reapDeadClients()
  check("dead client reaped by pid liveness",
        not cat2.components.hasKey("tui-dead"))
  check("live client survives the sweep",
        cat2.components.hasKey("tui-alive"))
  # Non-client components are never swept — the supervisor owns their pids.
  cat2.applyReg(%*{"name": "worker", "pid": 1 shl 30, "client": false})
  cat2.reapDeadClients()
  check("non-client components are never reaped by the client sweep",
        cat2.components.hasKey("worker"))

  # --- ownership: a foreign root's component must not join the queue group --
  #
  # The catalog accepted any reg.publish, assuming every publisher serves this
  # harness. When a component of ANOTHER root (a test root, a second clone)
  # lands on the same bus, its store subscribes to the SAME `store` queue group
  # on `svc.store.call` and answers a slice of this harness's calls from
  # another database — intermittent not-founds for rows that exist, which
  # reads as data loss (2026-11-10). Keyed on the announced ROOT, not the pid: a
  # stub component a test starts from the same root is a legitimate stand-in.
  let cat3 = newCatalog(nc)
  cat3.onChange = proc(c: Catalog) = discard
  let myRoot = "/home/someone/nifflerprod"
  cat3.ownsRoot = proc(announced: string): bool =
    normalizedPath(announced) == normalizedPath(myRoot)
  cat3.applyReg(%*{"name": "store", "pid": 4242, "root": "/home/someone/devclone",
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("a foreign root's registration is refused",
        not cat3.components.hasKey("store"))
  check("the refusal names the offending root",
        cat3.lastRejection("store").contains("/home/someone/devclone"))
  check("a refused foreign component publishes no tool",
        not cat3.toolIndex.hasKey("get"))
  cat3.applyReg(%*{"name": "store", "pids": [4242, 4245], "root": myRoot,
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("a store group cannot start with multiple PIDs",
        not cat3.components.hasKey("store"))
  cat3.applyReg(%*{"name": "store", "pid": 4242, "root": myRoot,
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("a component of this root is accepted", cat3.components.hasKey("store"))
  check("an accepted component records its replica",
        cat3.components["store"].pids.len == 1)
  cat3.applyReg(%*{"name": "store", "pid": 4245, "root": myRoot,
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("a second store PID is refused even from the same root",
        cat3.components["store"].pids == @[4242] and
        cat3.lastRejection("store").contains("SINGLE-WRITER VIOLATION"))
  cat3.applyReg(%*{"name": "store", "pid": 4246,
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("a legacy extra store cannot bypass the single-writer alarm",
        cat3.components["store"].pids == @[4242])
  cat3.applyReg(%*{"name": "store", "pid": 4242, "root": myRoot,
    "tools": [{"name": "get", "schema": {"type": "object"}}]})
  check("the existing store can re-announce after recovery",
        cat3.lastRejection("store").len == 0)
  let trace = registrationTrace("reg.publish", %*{"name": "store",
    "pid": 4245, "root": "/foreign\nforged", "version": "test"})
  let identity = parseJson(trace[trace.find("{") .. ^1])
  check("registration evidence carries timestamp, PID and escaped root",
        trace.startsWith("[20") and trace.contains("Z] catalog:") and
        not trace.contains('\n') and identity["pid"].getInt() == 4245 and
        identity["root"].getStr() == "/foreign\nforged")
  check("legacy diagnostic root is explicitly empty",
        registrationTrace("reg.depart", %*{"name": "store", "pid": 4242}).contains(
          "\"root\":\"\""))
  # A UI is exempt: it answers no tool subject, so it cannot misroute a call,
  # and older clients announce no root at all.
  cat3.applyReg(%*{"name": "tui-ext", "pid": 4243, "client": true})
  check("an external interactive client is exempt from the root check",
        cat3.components.hasKey("tui-ext"))
  # An unvouchable (root-less) announcement still registers — older SDKs and
  # hand-rolled publishers predate the field — but it must not erase a
  # registration when it departs under a pid we never recorded.
  cat3.applyReg(%*{"name": "legacy", "pid": 4244})
  check("a root-less registration still registers",
        cat3.components.hasKey("legacy"))
  cat3.arriveForTest("reg.depart", $(%*{"name": "store", "pid": 9999}))
  check("a foreign departure cannot retire an owned component",
        cat3.components.hasKey("store"))

  # Request/reply admission reaches only the system catalog, even with runner
  # catalogs subscribed to reg.>. Reserve before acknowledging; a competing
  # store must receive a negative verdict rather than joining the queue group.
  let inbox = "_INBOX.catalog.admission." & $getCurrentProcessId()
  var replies: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr replies, nc.conn,
    inbox.cstring) == NATS_OK
  defer: natsSubscription_Destroy(replies)
  for pid in [4242, 4247]:
    let data = $(%*{"name": "store", "pid": pid, "root": myRoot,
      "tools": [{"name": "get", "schema": {"type": "object"}}]})
    discard natsConnection_PublishRequest(nc.conn, "reg.admit", inbox.cstring,
      data.cstring, data.len.cint)
    discard natsConnection_FlushTimeout(nc.conn, 1000)
    cat.pump()
    cat2.pump()
    cat3.pump()
    var reply: ptr natsMsg
    let status = natsSubscription_NextMsg(addr reply, replies, 1000)
    check("admission has a reply for pid " & $pid, status == NATS_OK)
    if status == NATS_OK:
      let verdict = parseJson($natsMsg_GetData(reply))
      natsMsg_Destroy(reply)
      check("admission verdict is correlated and enforces single writer",
        verdict["pid"].getInt() == pid and verdict["ok"].getBool() == (pid == 4242))
    check("runner catalogs do not answer admission",
      natsSubscription_NextMsg(addr reply, replies, 100) == NATS_TIMEOUT)

  report("CATALOG")

main()
