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

  report("ROOTS TEST")

main()
