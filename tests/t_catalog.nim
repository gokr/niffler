## Catalog admission must not crash on malformed registrations or publish
## a UI notification before its durable slash-table checkpoint.

import std/[json, os, tables]
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

  report("CATALOG")

main()
