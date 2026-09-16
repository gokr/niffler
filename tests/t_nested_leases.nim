## P2.5 B — keyed nested-call leases (unit test).
##
## The nested-call proxy (svc.session.<id>.tool) once validated against a
## SINGLE lease string that each session-context dispatch replaced on entry
## and restored on exit. Two overlapping session-context dispatches could
## clobber each other: the second's restore would reinstate the first's
## lease while the first was still in flight. Leases are now keyed by id —
## each dispatch owns its entry and removes only it.
##
## This test drives handleNestedCall directly (the wave scheduler still
## refuses sessionContext tools, so overlap cannot be produced end-to-end
## today — that is exactly why the keyed table makes the invariant true
## regardless of future dispatch policy). Two synthetic leases are
## registered the way two overlapping dispatches would register them, and
## the error-code matrix proves neither clobbers nor prematurely kills the
## other. With the old single-string design, the second lease could not
## coexist with the first at all (bad-lease after the first registered).

import std/[json, monotimes, strutils, tables, times]
import natsnim
import envelope
import ../core/[catalog, dispatch]

proc main() =
  var failures = 0
  proc check(name: string, cond: bool, detail = "") =
    if cond:
      echo "OK: ", name
    else:
      inc failures
      echo "FAIL: ", name, " — ", detail

  # handleNestedCall's lease paths never reach the bus (they end at the
  # lease/denied/no-tool checks, before any component dispatch), so a nil
  # connection and an empty catalog are enough — like t_core_requests.
  var ct = CoreTools(cat: Catalog(),
                     pending: PendingCalls(items: @[]))
  ct.nested = NestedState(session: "t-unit")

  proc reg(lease: string; seconds: float = 30) =
    ct.nested.leases[lease] = NestedLease(
      deadline: getMonoTime() + initDuration(milliseconds = int(seconds * 1000)),
      hasDeadline: true)

  proc call(lease: string, tool = "bash"): Envelope =
    ## A nested-call envelope the way a session-context component forwards it.
    let args = %*{"__session": {"session": "t-unit", "lease": lease}}
    callEnvelope(tool, args)

  # --- no leases at all: no-session (the empty-table early exit) ----------
  let e0 = handleNestedCall(ct, call("anything"))
  check("no registered lease reads no-session",
        e0.error{"code"}.getStr("") == "no-session", $e0.error)

  # --- two overlapping leases: BOTH validate (the keyed invariant) --------
  reg("leaseA")
  reg("leaseB")
  let eA = handleNestedCall(ct, call("leaseA"))
  check("lease A accepted with lease B also registered",
        eA.error{"code"}.getStr("") == "no-tool", $eA.error)
  let eB = handleNestedCall(ct, call("leaseB"))
  check("lease B accepted with lease A also registered",
        eB.error{"code"}.getStr("") == "no-tool", $eB.error)
  # "no-tool" means the call got PAST the lease/denied checks and stopped at
  # the (empty) catalog — the target tool was never reached, by design.
  check("accepted calls failed at the catalog, not the lease",
        eA.error{"message"}.getStr("").contains("no component"),
        $eA.error)

  # --- unknown / empty leases still fail closed ---------------------------
  let eBogus = handleNestedCall(ct, call("bogus"))
  check("unknown lease denied (bad-lease)",
        eBogus.error{"code"}.getStr("") == "bad-lease", $eBogus.error)
  let eEmpty = handleNestedCall(ct, call(""))
  check("empty lease denied (bad-lease)",
        eEmpty.error{"code"}.getStr("") == "bad-lease", $eEmpty.error)

  # --- denied-list tools are refused even with a live lease ---------------
  let eAgent = handleNestedCall(ct, call("leaseA", tool = "agent"))
  check("agent tool denied through the proxy even with a live lease",
        eAgent.error{"code"}.getStr("") == "denied", $eAgent.error)

  # --- one dispatch completing removes only its own key -------------------
  ct.nested.leases.del("leaseA")
  let eAfterA = handleNestedCall(ct, call("leaseA"))
  check("completed dispatch's lease is dead",
        eAfterA.error{"code"}.getStr("") == "bad-lease", $eAfterA.error)
  let eBAfter = handleNestedCall(ct, call("leaseB"))
  check("the overlapping lease SURVIVES the other's completion",
        eBAfter.error{"code"}.getStr("") == "no-tool", $eBAfter.error)

  # --- an expired lease is denied even though its key exists --------------
  reg("leaseC", seconds = -5)
  let eExpired = handleNestedCall(ct, call("leaseC"))
  check("expired lease denied",
        eExpired.error{"code"}.getStr("") == "expired", $eExpired.error)

  # --- the no-session path: no active turn --------------------------------
  let savedSession = ct.nested.session
  ct.nested.session = ""
  let eNoTurn = handleNestedCall(ct, call("leaseB"))
  check("no live turn reads no-session even with a registered lease",
        eNoTurn.error{"code"}.getStr("") == "no-session", $eNoTurn.error)
  ct.nested.session = savedSession

  if failures > 0:
    echo "nested-leases FAILED: ", failures, " failure(s)"
    quit(1)
  echo "nested-leases PASSED"

when isMainModule:
  main()
