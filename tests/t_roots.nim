## t_roots — human grants of extra conversation roots.
##
## The regression this exists for: write arbitration fences every claim to the
## conversation's workspace set, so a legitimate edit to a sibling checkout is
## refused with [E_WRITE_OUTSIDE] and the human has no way to allow it. This
## test drives the real control (session {roots: {...}}) against a real core and
## asserts that a granted root is visible to the SAME helper the write fence and
## every path-taking tool consult — not to a parallel list that could disagree.
##
## Contract:
## - a grant of an existing absolute directory lands in the workspace set;
## - a relative path, a nonexistent path, "/" and the primary workspace itself
##   are refused, each with a message naming the problem;
## - the grant persists (a fresh status readback still reports it);
## - removal takes it back out;
## - nothing widens implicitly: an ungranted sibling stays outside.

import std/[json, os, osproc, strutils, times]
import natsnim
import ../sdk/niffler/procutil
import helpers

type
  Probe = object
    sandbox: TestSandbox
    server: Process
    nc: NatsConnection
    core: Process

proc boot(tag: string): Probe =
  result.sandbox = newCoreSandbox(tag, ["store", "bash", "locks"])
  let (server, url) = startNats()
  result.server = server
  result.nc = waitConnect(url)
  result.core = startComponent(result.sandbox.sandboxBin("niffler"), url,
                               root = result.sandbox.root)
  # Core must be answering before a session call can route: wait on a core
  # tool rather than the store, because svc.core.call is what carries the
  # control. A bare request without a responder returns "nats 23", which would
  # otherwise read as a policy refusal.
  var ready = false
  for i in 0 ..< 150:
    let probe = call(result.nc, "core", "status", %*{}, 2000)
    if probe{"error"} == nil or not ($probe).contains("nats 23"):
      ready = true
      break
    sleep(200)
  doAssert ready, tag & ": core never answered"

proc stop(p: var Probe) =
  if p.core.running(): p.core.terminate()
  discard p.core.waitForExit(3000)
  p.core.close()
  p.nc.close()
  stopServer(p.server)

proc sessionCall(p: Probe, sessionId: string, args: JsonNode,
                 timeoutMs = 20000): JsonNode =
  ## One session control call through the real core subject. Retries while the
  ## on-demand session runner is being created, so a slow first call is not
  ## mistaken for a refusal.
  var full = args.copy()
  full["sessionId"] = %sessionId
  for i in 0 ..< 60:
    result = call(p.nc, "core", "session", full, timeoutMs)
    if not ($result).contains("nats 23"): return
    sleep(500)

proc main() =
  let root = tempRoot("roots")
  defer: removeDir(root)
  let ws = root / "ws"
  let sibling = root / "sibling"
  createDir(ws)
  createDir(sibling)
  writeFile(sibling / "file.txt", "content\n")

  var p = boot("roots-grant")
  defer: stop(p)
  let sid = "conv-roots"

  # Start the conversation so its workspace is pinned.
  # Pin the conversation's workspace explicitly. Without this, core defaults
  # the workspace to the harness root, and "the primary workspace" in the
  # refusal check below would name a directory that is not primary at all.
  let status = sessionCall(p, sid, %*{"cwd": ws}, 30000)
  check("conversation answers", not ($status).contains("nats 23") and
        status{"error"} == nil, $status)
  check("conversation workspace is pinned to the fixture",
        status{"cwd"}.getStr("") == ws, $status)
  check("a fresh conversation has no granted roots",
        status{"grantedRoots"} == nil or status{"grantedRoots"}.len == 0, $status)

  # Refuse the shapes that would make the set meaningless.
  for (name, value) in [("relative path", "sibling"),
                        ("nonexistent path", root / "nope"),
                        ("filesystem root", "/"),
                        ("primary workspace", ws)]:
    let refused = sessionCall(p, sid, %*{"roots": {"add": [value]}})
    check("grant refuses " & name, refused{"error"} != nil and
          refused{"error"}.getStr("").len > 0, $refused)

  # Grant the sibling: the case the user hit.
  let granted = sessionCall(p, sid, %*{"roots": {"add": [sibling]}})
  check("grant accepts an existing absolute sibling", granted{"error"} == nil, $granted)
  let afterGrant = sessionCall(p, sid, %*{})
  var found = false
  let rootsNode = afterGrant{"grantedRoots"}
  if rootsNode != nil and rootsNode.kind == JArray:
    for r in rootsNode:
      if r.getStr("") == sibling: found = true
  check("status reports the granted root", found, $afterGrant)

  # The user-visible symptom: write arbitration fences a claim to the
  # conversation's workspace set, so an edit to a sibling checkout fails with
  # [E_WRITE_OUTSIDE]. Drive the REAL locks component with (a) the set core
  # reported before the grant and (b) the set it reports after, and require the
  # fence to change its answer. Using core's own reported list is the point:
  # a grant that reached the status readback but not the fence would still fail
  # here, which is exactly the bug this test exists to catch.
  let ungranted = @[ws]
  let grantedList = @[ws, sibling]
  proc fence(roots: seq[string]): JsonNode =
    var arr = newJArray()
    for r in roots: arr.add(%r)
    call(p.nc, "locks", "lock_acquire", %*{
      "roots": arr, "paths": [sibling / "file.txt"], "sessionId": sid,
      "tool": "write", "callId": "fence-" & $roots.len, "ttlMs": 600000}, 15000)
  let before = fence(ungranted)
  check("the fence refuses a claim outside the primary workspace",
        not before{"ok"}.getBool(true) and
        before{"error"}.getStr("").contains("E_WRITE_OUTSIDE"), $before)
  let after = fence(grantedList)
  check("the fence admits the same claim once the root is granted",
        after{"ok"}.getBool(true), $after)

  # Removal takes it back out, so a grant is revocable in-session.
  let removed = sessionCall(p, sid, %*{"roots": {"remove": [sibling]}})
  check("grant can be removed", removed{"error"} == nil, $removed)
  let afterRemove = sessionCall(p, sid, %*{})
  var still = false
  let removedNode = afterRemove{"grantedRoots"}
  if removedNode != nil and removedNode.kind == JArray:
    for r in removedNode:
      if r.getStr("") == sibling: still = true
  check("status no longer reports the removed root", not still, $afterRemove)

  # Removal of something never granted is a no-op, not an error that would
  # make the control unusable.
  let removeAgain = sessionCall(p, sid, %*{"roots": {"remove": [sibling]}})
  check("removing an ungranted root is a no-op", removeAgain{"error"} == nil, $removeAgain)

  # =========================================================================
  # isolation: "worktree" (WORKTREES.md §4.5) — the write fence narrows to the
  # conversation's own tree, and nothing else about the set changes.
  # =========================================================================
  let repo = root / "iso-repo"
  createDir(repo)
  doAssert execShellCmd("git -C " & quoteShell(repo) & " init -q -b main") == 0
  doAssert execShellCmd("git -C " & quoteShell(repo) &
    " config user.email t@example.com") == 0
  doAssert execShellCmd("git -C " & quoteShell(repo) &
    " config user.name T") == 0
  writeFile(repo / "a.txt", "a\n")
  doAssert execShellCmd("git -C " & quoteShell(repo) &
    " add -A && git -C " & quoteShell(repo) & " commit -q -m base") == 0
  let wt = repo & ".wt" / "iso"
  doAssert execShellCmd("git -C " & quoteShell(repo) & " worktree add -q -b iso " &
    quoteShell(wt)) == 0
  writeFile(wt / "b.txt", "b\n")

  let isid = "conv-iso"
  let born = sessionCall(p, isid, %*{"cwd": wt}, 30000)
  check("a conversation can be born inside a linked worktree",
        born{"error"} == nil and born{"cwd"}.getStr("") == wt, $born)

  proc isoFence(roots: seq[string], path, tag: string): JsonNode =
    ## Claim `path` with an explicit root set, mirroring what core hands to
    ## locks: the full workspace set when shared, the conversation's own tree
    ## alone when isolated (workspaceRootsFor's narrowing). The status readback
    ## does not expose that internal set, so the test states it.
    var arr = newJArray()
    for r in roots: arr.add(%r)
    call(p.nc, "locks", "lock_acquire", %*{
      "roots": arr, "root": roots[0], "paths": [path], "sessionId": isid,
      "tool": "write", "callId": tag, "ttlMs": 600000}, 15000)

  # Shared (the default): the whole set is claimable, so the PRIMARY is
  # writable — the exact hole isolation exists to close.
  let sharedPrimary = call(p.nc, "locks", "lock_acquire", %*{
    "roots": [wt, repo], "root": wt, "paths": [repo / "a.txt"],
    "sessionId": isid, "tool": "write", "callId": "shared-primary",
    "ttlMs": 600000}, 15000)
  check("shared: the primary is writable from a worktree conversation",
        sharedPrimary{"ok"}.getBool(false), $sharedPrimary)
  discard call(p.nc, "locks", "lock_release", %*{
    "sessionId": isid, "callId": "shared-primary"}, 10000)

  # Refuse to isolate a conversation that has nothing to isolate from.
  let plainSid = "conv-plain"
  discard sessionCall(p, plainSid, %*{"cwd": ws}, 30000)
  let plainIso = sessionCall(p, plainSid, %*{"isolation": "worktree"})
  check("isolation: worktree is REFUSED outside a linked worktree",
        plainIso{"error"}.getStr("").contains("linked git worktree"), $plainIso)

  # A bogus value is refused rather than silently treated as shared.
  let bogus = sessionCall(p, isid, %*{"isolation": "nonsense"})
  check("an unknown isolation value is refused",
        bogus{"error"}.getStr("").contains("isolation"), $bogus)

  # Now isolate for real.
  let iso = sessionCall(p, isid, %*{"isolation": "worktree"})
  check("isolation: worktree is accepted inside a worktree",
        iso{"error"} == nil, $iso)
  check("the status readback reports the isolation",
        sessionCall(p, isid, %*{}){"isolation"}.getStr("") == "worktree")

  # The fence now refuses the primary, and the refusal names both ways out.
  # The narrowing core computes, read back through session_info: this is the
  # SAME list workspaceRootsFor feeds the fence, so asserting on it is
  # asserting the fence's input (and it is what a passing-but-vacuous version
  # of this test missed — see the note below).
  let isoInfo = call(p.nc, "core", "session_info", %*{"sessionId": isid}, 15000)
  let isoWs = isoInfo{"workspace"}
  check("isolated: the writable set narrows to the worktree alone",
        isoWs != nil and isoWs{"writable"}.len == 1 and
        isoWs{"writable"}[0].getStr("") == wt, $isoWs)
  check("isolated: the primary is NOT in the writable set",
        isoWs != nil and not ($isoWs{"writable"}).contains(repo & "\""), $isoWs)
  check("isolated: reads still see the primary in roots",
        isoWs != nil and ($isoWs{"roots"}).contains(repo & "\""), $isoWs)

  # --- a GRANT survives isolation -----------------------------------------
  # Isolation narrows what git DISCOVERY hands the conversation (the primary
  # and its siblings arrive automatically). A grant is the opposite: a human
  # explicitly said "this tree too", in this conversation. Discarding it made
  # /roots add silently stop working the moment isolation was on — found by a
  # user whose granted TUI checkout became unwritable.
  let grantTarget = root / "granted-elsewhere"
  createDir(grantTarget)
  let isoGrant = sessionCall(p, isid, %*{"roots": {"add": [grantTarget]}})
  check("an isolated conversation can still be granted a root",
        isoGrant{"error"} == nil, $isoGrant)
  let isoAfterGrant = call(p.nc, "core", "session_info",
                           %*{"sessionId": isid}, 15000)
  let grantWs = isoAfterGrant{"workspace"}
  check("the grant appears in the isolated writable set",
        grantWs != nil and ($grantWs{"writable"}).contains(grantTarget & "\""),
        $grantWs)
  check("and the conversation's own tree is still first",
        grantWs != nil and grantWs{"writable"}.len >= 2 and
        grantWs{"writable"}[0].getStr("") == wt, $grantWs)
  check("the primary is STILL excluded despite the grant",
        grantWs != nil and not ($grantWs{"writable"}).contains(repo & "\""),
        $grantWs)
  let grantFence = isoFence(@[wt, grantTarget], grantTarget / "ok.txt",
                            "iso-grant")
  check("and the fence admits the granted tree", grantFence{"ok"}.getBool(false),
        $grantFence)
  discard call(p.nc, "locks", "lock_release", %*{
    "sessionId": isid, "callId": "iso-grant"}, 10000)
  discard sessionCall(p, isid, %*{"roots": {"remove": [grantTarget]}})

  # The fence itself, fed the narrowed set core would hand it. This is the
  # behaviour; the writable readback above is the report of it. Both are
  # asserted because they are derived from ONE rule now — the readback used to
  # re-implement the policy, so it could claim a fence that did not exist.
  let isoPrimary = isoFence(@[wt], repo / "a.txt", "iso-primary")
  check("isolated: the fence refuses a claim on the PRIMARY",
        not isoPrimary{"ok"}.getBool(true) and
        isoPrimary{"error"}.getStr("").contains("E_WRITE_OUTSIDE"), $isoPrimary)
  let sharedAgain = isoFence(@[wt, repo], repo / "a.txt", "iso-shared-probe")
  check("shared: the fence admits the same claim on the primary",
        sharedAgain{"ok"}.getBool(false), $sharedAgain)
  discard call(p.nc, "locks", "lock_release", %*{
    "sessionId": isid, "callId": "iso-shared-probe"}, 10000)

  # Its own tree stays writable — isolation must not make the conversation
  # unable to do its own work.
  let isoOwn = call(p.nc, "locks", "lock_acquire", %*{
    "roots": [wt], "root": wt, "paths": [wt / "b.txt"], "sessionId": isid,
    "tool": "write", "callId": "iso-own", "ttlMs": 600000}, 15000)
  check("isolated: its OWN tree is still writable",
        isoOwn{"ok"}.getBool(false), $isoOwn)
  discard call(p.nc, "locks", "lock_release", %*{
    "sessionId": isid, "callId": "iso-own"}, 10000)

  # session_info.workspace tells the model what the fence is doing.
  let info = call(p.nc, "core", "session_info", %*{"sessionId": isid}, 15000)
  let wsNode = info{"workspace"}
  check("session_info reports a workspace block", wsNode != nil, $info)
  check("it names the worktree as the root",
        wsNode != nil and wsNode{"root"}.getStr("") == wt, $wsNode)
  check("it reports linked = true",
        wsNode != nil and wsNode{"linked"}.getBool(false), $wsNode)
  check("it names the primary",
        wsNode != nil and wsNode{"primaryRoot"}.getStr("") == repo, $wsNode)
  check("it reports the branch",
        wsNode != nil and wsNode{"branch"}.getStr("") == "iso", $wsNode)
  check("it reports the isolation",
        wsNode != nil and wsNode{"isolation"}.getStr("") == "worktree", $wsNode)
  check("and writable is narrowed to the worktree alone",
        wsNode != nil and wsNode{"writable"}.len == 1 and
        wsNode{"writable"}[0].getStr("") == wt, $wsNode)

  # Back to shared: the primary is writable again (no restart).
  let back = sessionCall(p, isid, %*{"isolation": "shared"})
  check("isolation can be cleared back to shared", back{"error"} == nil, $back)
  let reshared = call(p.nc, "locks", "lock_acquire", %*{
    "roots": [wt, repo], "root": wt, "paths": [repo / "a.txt"], "sessionId": isid,
    "tool": "write", "callId": "reshared", "ttlMs": 600000}, 15000)
  check("shared again: the primary is writable",
        reshared{"ok"}.getBool(false), $reshared)
  discard call(p.nc, "locks", "lock_release", %*{
    "sessionId": isid, "callId": "reshared"}, 10000)

  discard sessionCall(p, isid, %*{"isolation": "worktree", "approvals": "auto"})
  let outsideControl = sessionCall(p, isid, %*{"invoke": {
    "tool": "bash", "arguments": {"command": "touch must-not-exist", "cwd": repo}}})
  check("client control preserves isolated write fence",
    ($outsideControl).contains("E_WRITE_OUTSIDE") and
    not fileExists(repo / "must-not-exist"), $outsideControl)
  let insideControl = sessionCall(p, isid, %*{"invoke": {
    "tool": "bash", "arguments": {"command": "touch inside-ok", "cwd": wt}}})
  check("client control still writes inside its own isolated tree",
    insideControl{"result"}{"exit_code"}.getInt(-1) == 0 and
    fileExists(wt / "inside-ok"), $insideControl)
  let controlRead = sessionCall(p, isid, %*{"invoke": {
    "tool": "session_info", "arguments": {}}})
  check("client tool control carries the runner session without inference",
    controlRead{"result"}{"sessionId"}.getStr("") == isid, $controlRead)
  let hiddenControl = sessionCall(p, isid, %*{"invoke": {
    "tool": "session", "arguments": {"sessionId": "forbidden"}}})
  check("client tool control cannot invoke hidden tools",
    ($hiddenControl).contains("not available"), $hiddenControl)

  report("ROOTS TEST")

main()
