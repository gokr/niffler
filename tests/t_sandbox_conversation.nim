## Conversation sandbox policy — STAGE A contract (persist, don't enforce).
##
## docs/research/SANDBOX-NEXT-SLICE.md defines three stages and, more
## importantly, three different CLAIMS. This suite tests the first one and
## deliberately refuses to test a claim the code does not make yet:
##
## - a human's decision is persisted with a revision, survives a runner
##   restart, and is isolated per conversation;
## - a stale concurrent edit is a REFUSAL, never a silent overwrite;
## - the policy is human-only: a session with a lineage parent cannot change it
##   (nor can an unreadable-lineage caller), because a child that could turn
##   confinement off would make the parent's decision advisory;
## - a child INHERITS a snapshot at birth, in its own workspace;
## - every readback says `enforced: false` / `state: configured`, because
##   nothing consults the policy for confinement in this stage.
##
## The last one is the load-bearing assertion: it is what stops this slice from
## being mistaken for a sandbox. When stage C lands and bash actually confines,
## its own suite must flip that expectation — and that flip should be a
## deliberate, visible edit rather than a test that always looked green.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "agent"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let sandbox = newCoreSandbox("sandboxpolicy", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  for bin in ["agent"]:
    copyFileWithPermissions(repoRoot / "var" / "bin" / bin,
                            sandbox.sandboxBin(bin))

  let (server, url, _) = startNatsMonitoring()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1"),
                                         ("NIF_RUNNER_IDLE_S", "2"),
                                         ("NIF_AGENT_WAKE", "0")],
                                logFile = root / "var" / "test-logs" / "core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running(): coreProc.kill()
      sleep(200)
    if coreProc != nil: coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 extra = [("NIF_AGENT_WAKES", "0"),
                                          ("NIF_AGENT_NOTICE_HOLD", "0")],
                                 logFile = root / "var" / "test-logs" / "agent.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # Two scratch directories to approve — real paths, because the control
  # refuses a root that is not an existing directory.
  let readDir = root / "approved-read"
  let writeDir = root / "approved-write"
  createDir(readDir)
  createDir(writeDir)

  proc status(session: string): JsonNode =
    call(nc, "core", "session", %*{"sessionId": session}, 20_000)

  # --- 1. default is off, configured, and NOT enforced --------------------
  let a = "sbx-a"
  let defaultStatus = status(a)
  check("a fresh conversation reports a sandbox policy",
        defaultStatus{"sandbox"} != nil, $defaultStatus)
  check("the default is off",
        not defaultStatus{"sandbox"}{"enabled"}.getBool(true), $defaultStatus)
  check("the readback is configured, not applied",
        defaultStatus{"sandbox"}{"state"}.getStr("") == "configured" and
        not defaultStatus{"sandbox"}{"enforced"}.getBool(true),
        $defaultStatus)
  # The workspace is already inside its own policy: a sandbox whose owner
  # cannot touch its own tree is not a policy, it is a denial.
  var ws = defaultStatus{"sandbox"}{"readRoots"}
  check("the conversation workspace is a default root",
        ws != nil and ws.len >= 1, $defaultStatus)

  # --- 2. a human enables it; the choice persists and is revisioned ------
  let enabled = call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"enabled": true}}, 20_000)
  check("a human can enable the policy", enabled{"error"} == nil, $enabled)
  let afterEnable = status(a)
  check("enablement is reported back",
        afterEnable{"sandbox"}{"enabled"}.getBool(false), $afterEnable)
  check("still not enforced after enabling",
        not afterEnable{"sandbox"}{"enforced"}.getBool(true) and
        afterEnable{"sandbox"}{"state"}.getStr("") == "configured",
        $afterEnable)
  let rev1 = afterEnable{"sandbox"}{"rev"}.getInt(0)
  check("the policy carries a revision", rev1 > 0, $afterEnable)

  # --- 3. a stale revision is refused, not silently overwritten ----------
  # Edit from rev1 ONCE, which advances the document...
  let fresh = call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"enabled": false, "expectRev": rev1}}, 20_000)
  check("the revision you were looking at is accepted", fresh{"error"} == nil, $fresh)
  check("the accepted edit took effect",
        not status(a){"sandbox"}{"enabled"}.getBool(true), $status(a))
  # ...and the SAME rev1 is now stale. A second human tab that never reloaded
  # must not overwrite the first one's decision.
  let stale = call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"enabled": true, "expectRev": rev1}}, 20_000)
  # The test harness's call() flattens an error envelope to {"error": text},
  # so the refusal's own code field is not visible here — assert the message,
  # which is what a human (and the client) actually sees.
  check("a stale expectRev refuses the edit",
        stale{"error"} != nil and
        stale{"error"}.getStr("").contains("changed since revision"), $stale)
  check("the refused stale edit changed nothing",
        not status(a){"sandbox"}{"enabled"}.getBool(true), $status(a))

  # --- 4. roots: read is separate, write implies read --------------------
  let granted = call(nc, "core", "session", %*{
    "sessionId": a,
    "sandbox": {"addRead": [readDir], "addWrite": [writeDir]}}, 20_000)
  check("a human can approve roots", granted{"error"} == nil, $granted)
  let rooted = status(a){"sandbox"}
  var readRoots: seq[string] = @[]
  var writeRoots: seq[string] = @[]
  for r in rooted{"readRoots"}: readRoots.add r.getStr("")
  for r in rooted{"writeRoots"}: writeRoots.add r.getStr("")
  check("the read root was added", readDir in readRoots, $rooted)
  check("the write root was added", writeDir in writeRoots, $rooted)
  check("a write root implies the matching read root", writeDir in readRoots, $rooted)
  check("a read root alone does not imply a write root", readDir notin writeRoots, $rooted)
  # The write fence consults the granted-root set, so a WRITE approval must
  # appear there or a tool is permitted by the policy and refused by the fence.
  let fences = status(a){"grantedRoots"}
  var fenceList: seq[string] = @[]
  if fences != nil:
    for r in fences: fenceList.add r.getStr("")
  check("an approved WRITE root also joins the write fence's grant set",
        writeDir in fenceList, $fences)
  # ...and a READ-only approval must NOT. The fence's set is a write set:
  # syncing a read root into it would grant write in practice while the policy
  # document said read-only — read-implies-write through the back door.
  check("a read-only approval does NOT join the write fence",
        readDir notin fenceList, $fences)

  # Revoking the WRITE root must leave the read root it came with... but a
  # path granted read-only keeps its read allowance when only write is removed.
  discard call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"addRead": [readDir]}}, 20_000)
  discard call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"remove": [writeDir]}}, 20_000)
  let afterRemove = status(a){"sandbox"}
  var readsNow: seq[string] = @[]
  for r in afterRemove{"readRoots"}: readsNow.add r.getStr("")
  check("removing a write root leaves an independent read root",
        readDir in readsNow, $afterRemove)

  # --- 5. refusals: the filesystem root, a relative path, the workspace --
  for bad in [%*{"addRead": ["/"]}, %*{"addWrite": ["relative/path"]},
              %*{"remove": [root]}, %*{"enabled": "yes"}, %*{"nonsense": []}]:
    let refused = call(nc, "core", "session",
      %*{"sessionId": a, "sandbox": bad}, 20_000)
    check("refused: " & $bad, refused{"error"} != nil, $refused)
  let wsRoot = status(a){"sandbox"}{"readRoots"}[0].getStr("")
  let removeWs = call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"remove": [wsRoot]}}, 20_000)
  check("the conversation workspace cannot be removed from its own policy",
        removeWs{"error"} != nil, $removeWs)

  # --- 6. per-conversation isolation and resume -------------------------
  let b = "sbx-b"
  let bStatus = status(b)
  check("another conversation keeps the default",
        not bStatus{"sandbox"}{"enabled"}.getBool(true), $bStatus)
  var bReads: seq[string] = @[]
  for r in bStatus{"sandbox"}{"readRoots"}: bReads.add r.getStr("")
  check("a conversation does not inherit another's grants", readDir notin bReads, $bStatus)

  # Resume: the runner retires after 2s idle (NIF_RUNNER_IDLE_S), and the next
  # status call builds a fresh one whose only source is the STORE.
  discard call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"enabled": true}}, 20_000)
  let before = status(a){"sandbox"}{"enabled"}.getBool(false)
  sleep(3000)
  let resumed = status(a){"sandbox"}
  check("the enabled decision survives a runner restart",
        before and resumed{"enabled"}.getBool(false), $resumed)
  var resumedReads: seq[string] = @[]
  for r in resumed{"readRoots"}: resumedReads.add r.getStr("")
  check("approved roots survive the restart", readDir in resumedReads, $resumed)
  check("and the deny defaults survive it", resumed{"denyPatterns"} != nil and
        resumed{"denyPatterns"}.len >= 1, $resumed)
  check("a resumed policy is still not enforced",
        not resumed{"enforced"}.getBool(true), $resumed)

  # --- 7. child inheritance, and the human-only refusal -----------------
  # A subagent must inherit, never negotiate. Two facts are asserted with the
  # pieces that actually carry them:
  #
  # - the BIRTH path: `sandbox_inherit` is what the agent component calls when
  #   it creates a child (a real agent_spawn needs a live turn and a provider,
  #   which this suite has none of), and
  # - the LINEAGE refusal: core refuses a sandbox edit for any session whose
  #   durable sessionmeta.parent is set — the same relation agent_run
  #   authorizes against, written here directly because that is exactly what
  #   the check reads.
  let child = "agent-sbx-child"
  discard call(nc, "store", "put", %*{"kind": "sessionmeta", "id": child,
    "value": {"parent": a}}, 10_000)
  let inherited = call(nc, "core", "sandbox_inherit",
    %*{"parent": a, "sessionId": child, "workspace": root}, 20_000)
  check("the birth path inherits the parent's policy",
        inherited{"error"} == nil, $inherited)
  let childStatus = status(child)
  check("the child inherited the enabled snapshot",
        childStatus{"sandbox"}{"enabled"}.getBool(false), $childStatus)
  var childReads: seq[string] = @[]
  for r in childStatus{"sandbox"}{"readRoots"}: childReads.add r.getStr("")
  check("the child inherited the parent's approved roots",
        readDir in childReads, $childStatus)
  # A child that could widen or disable confinement would make the parent's
  # decision advisory. Refused whatever auto-approval says.
  let childEdit = call(nc, "core", "session",
    %*{"sessionId": child, "sandbox": {"enabled": false}}, 20_000)
  check("a subagent cannot change the sandbox policy",
        childEdit{"error"} != nil and
        childEdit{"error"}.getStr("").contains("human-only"), $childEdit)
  check("the refused child edit left the policy intact",
        status(child){"sandbox"}{"enabled"}.getBool(false), $status(child))
  # A later parent change must not silently reach an existing child: the
  # documented semantics are a SNAPSHOT at birth, and continuation/revocation
  # propagation is a separate lifecycle decision this stage does not claim.
  discard call(nc, "core", "session",
    %*{"sessionId": a, "sandbox": {"enabled": false}}, 20_000)
  check("a later parent change does not reach an existing child",
        status(child){"sandbox"}{"enabled"}.getBool(false), $status(child))
  # ...and the parent's own change DID land, so the assertion above is about
  # isolation rather than a failed write.
  check("the parent's own change landed",
        not status(a){"sandbox"}{"enabled"}.getBool(true), $status(a))

  # Unreadable lineage is not permission: a session whose sessionmeta cannot be
  # read must not be able to edit a confinement decision.
  let orphan = "sbx-orphan"
  discard call(nc, "store", "put", %*{"kind": "sessionmeta", "id": orphan,
    "value": {"parent": "who-knows"}}, 10_000)
  let orphanEdit = call(nc, "core", "session",
    %*{"sessionId": orphan, "sandbox": {"enabled": true}}, 20_000)
  check("a session with any lineage parent is refused",
        orphanEdit{"error"} != nil and
        orphanEdit{"error"}.getStr("").contains("human-only"), $orphanEdit)

  report("SANDBOX POLICY CONVERSATION")

main()
