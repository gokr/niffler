## One unattended coding task (docs/FLEET.md §8, slice F2) against a REAL store
## and session runner, with the mock model. No SSH, VM or provider.
##
## What this pins, in the order the authority is decided:
##
## - an operator `taskprofile` plus the requesting human's grant produce an
##   effective policy, recorded before any tool runs;
## - inside it, approval-gated coding tools (bash, edit) run with NO human
##   attached — the old behavior stalled here forever;
## - outside it, the task refuses explicitly instead of waiting (widened tool,
##   unapproved root, absent profile, no ceiling, a confinement this harness
##   cannot enforce);
## - the terminal receipt carries the policy, its digest and the honest
##   confinement verdict;
## - a resumed runner re-applies exactly the admitted authority, and a policy
##   that is not durably committed refuses to run at all;
## - `ask` mode is untouched: the same coding tool is not granted there.
import std/[json, os, osproc, strutils, times]
import natsnim
import helpers
# The same pure contract the worker and the requester enforce.
import ../sdk/niffler/taskpolicy
import ../sdk/niffler/codingartifact

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc main() =
  let repo = getCurrentDir()
  let sandbox = newCoreSandbox("taskpolicy", ["store", "llm", "bash", "edit"])
  defer: removeDir(sandbox.root)
  let llmLog = sandbox.root / "var" / "llm-requests.jsonl"
  discard fixtureBin(sandbox, "llm", repo / "tests/mock_llm.nim",
                     "fixture-mock-llm")
  let (bus, url) = startNats()
  defer: stopServer(bus)
  var nc = waitConnect(url)
  defer: nc.close()
  # The mock answers the first round with a scripted `edit` call: an
  # approval-gated coding tool. If unattended authority does not reach the
  # gate, that call is denied/left waiting and the task ends refused — which is
  # exactly the stall F2 exists to remove.
  let workspace = sandbox.root / "project"
  createDir(workspace)
  writeFile(workspace / "note.txt", "before\n")
  # The workspace is a real checkout: the receipt has to name the commit the
  # task produced against the base it started from (docs/FLEET.md §6), and that
  # is only provable in a repository.
  for cmd in ["init -q -b main", "config user.email task@example.test",
              "config user.name task", "add -A", "commit -q -m 'base commit'"]:
    let r = execCmdEx("git -C " & quoteShell(workspace) & " " & cmd)
    doAssert r.exitCode == 0, "git " & cmd & ": " & r.output
  let baseCommit = execCmdEx(
    "git -C " & quoteShell(workspace) & " rev-parse HEAD").output.strip()
  let core = startComponent(sandbox.sandboxBin("niffler"), url, sandbox.root,
    extra = [
             # Round 1 edits; round 2 commits, the way a worker acting as a
             # developer finishes real work. The artifact must then name it.
             ("NIF_MOCK_ROUNDS", "2"),
             ("NIF_MOCK_TOOLJSON",
              "[{\"name\":\"edit\",\"arguments\":{\"path\":\"note.txt\",\"edits\":[{\"old_string\":\"before\",\"new_string\":\"after\"}]}}," &
              "{\"name\":\"bash\",\"arguments\":{\"command\":\"git add -A && git commit -q -m 'fix the note file'\"}}]"),
             ("NIF_MOCK_LOG", llmLog), ("NIF_RUNNER_IDLE_S", "2"),
             ("NIF_AUTO_APPROVE", "")],
    logFile = sandbox.root / "var/core.log")
  defer: stopProcess(core)
  doAssert waitComponent(nc, "llm")
  doAssert waitComponent(nc, "edit")

  proc providerRounds(): int =
    if not fileExists(llmLog): return 0
    for line in readFile(llmLog).splitLines():
      if line.strip().len > 0: inc result

  proc putProfile(name: string, tools: JsonNode, root: string,
                  unattended = true): JsonNode =
    call(nc, "store", "put", %*{"kind": "taskprofile", "id": name,
      "value": {"name": name, "unattended": unattended,
                "tools": tools, "roots": [root],
                "maxRounds": 6, "maxCalls": 20, "maxTokens": 50000,
                "confinement": "unconfined"}})

  discard putProfile("coding", %*["read", "grep", "edit", "bash", "write"], workspace)

  # A rerun must not collide with the admission keys of a previous run: keys
  # are durable by design, so the scenario names carry a run tag.
  let tag = $getTime().toUnix() & "-" & $getCurrentProcessId()
  # Build every admission key explicitly: a `%*` literal evaluates its values
  # as Nim expressions, and a silently-constant key would collide with the
  # previous run's durable record (which is exactly what it must not do).
  proc key(name: string): string = name & "-" & tag
  let session = "unattended-" & $getCurrentProcessId() & "-" & tag

  proc submit(extra: JsonNode = nil): JsonNode =
    var args = %*{"sessionId": session,
      "content": "Fix the note file, then report what you changed.",
      "task": {"profile": "coding", "workspace": workspace,
               "tools": ["read", "edit", "bash"], "maxRounds": 4, "maxCalls": 8,
               "maxTokens": 20000},
      "admission": {"key": key("act-1"), "policyVersion": 1}}
    if extra != nil:
      for key, value in extra: args[key] = value
    call(nc, "core", "session", args, 180_000)


  # --- the happy path: coding tools run with no human attached -------------
  let ran = submit()
  check("an unattended task runs to completion without an approval wait",
        ran{"error"} == nil, $ran)
  check("the effective policy is returned with the turn",
        ran{"taskPolicy", "unattended"}.getBool(false) and
        ran{"taskPolicy", "tools"} == %*["bash", "edit", "read"] and
        ran{"taskPolicy", "confinement"}.getStr("") == "unconfined", $ran)
  check("the approval-gated coding tool actually executed",
        readFile(workspace / "note.txt") == "after\n", $ran)
  check("the task really reached the provider", providerRounds() > 0)

  # --- the receipt states the authority and the honest confinement --------
  let stored = call(nc, "store", "get", %*{"kind": "admission",
    "id": session & ":" & key("act-1")})
  let admissionDoc = stored{"value"}
  check("the admission receipt binds the effective policy",
        admissionDoc{"taskPolicy", "profile"}.getStr("") == "coding" and
        admissionDoc{"taskPolicy", "digest"}.getStr("").startsWith("sha256:") and
        admissionDoc{"taskPolicy", "confined"}.getBool(true) == false, $stored)
  check("the receipt records the workspace and unconfined verdict",
        admissionDoc{"workspace"}.getStr("") == workspace and
        admissionDoc{"confinement"}.getStr("") == "unconfined")
  # --- the artifact: the receipt names what the task ACTUALLY changed ------
  # This is the F2 exit's missing half (docs/FLEET.md §6): a report is only
  # checkable beside the commit it describes.
  let artifact = admissionDoc{"artifact"}
  check("the receipt carries a coding artifact",
        artifact != nil and artifact{"version"}.getInt(0) == 1, $admissionDoc)
  check("the artifact names the base the task started from",
        artifact{"base", "commit"}.getStr("") == baseCommit, $artifact)
  check("the artifact reports that the task produced a commit",
        artifact{"producedCommit"}.getBool(false) and
        artifact{"headMoved"}.getBool(false), $artifact)
  check("the commit is built on the approved base",
        artifact{"onBase"}.getBool(false), $artifact)
  check("the produced commit subject describes the change",
        artifact{"head", "subject"}.getStr("").contains("fix the note file"),
        $artifact)
  check("the artifact carries a diffstat for the change",
        artifact{"diffstat"}.getStr("").contains("note.txt"), $artifact)
  check("a committed tree is reported clean",
        not artifact{"dirty"}.getBool(true), $artifact)
  # The artifact and the working tree must agree: the SHA is real, not a claim.
  let realHead = execCmdEx(
    "git -C " & quoteShell(workspace) & " rev-parse HEAD").output.strip()
  check("the reported commit is the repository's actual HEAD",
        artifact{"head", "commit"}.getStr("") == realHead, $artifact)
  check("the artifact renders a one-line summary for the notice",
        artifactSummary(artifact).contains("fix the note file"), artifactSummary(artifact))

  check("the receipt still refuses to call this verified success",
        admissionDoc{"state"}.getStr("") == "settled" and
        admissionDoc{"transcriptCommitted"}.getBool(false))
  # The task's workspace is a DECISION, not the harness-root default, so it must
  # be pinned in the header. Otherwise a bare `cwd` control call (no content, no
  # `task`) reaches main's repin path and could move an admitted task's
  # workspace out from under the directory a human approved.
  let headerDoc = call(nc, "store", "get",
    %*{"kind": "conversation", "id": session}){"value"}
  check("the task workspace is recorded as a pinned decision",
        headerDoc{"cwdPinned"}.getBool(false), $headerDoc)
  let repin = call(nc, "core", "session",
    %*{"sessionId": session, "cwd": sandbox.root}, 60_000)
  check("a control call cannot repin an admitted task's workspace",
        repin{"error"}.getStr("").contains("immutable"), $repin)

  # Exact retries return the activation receipt without another provider call.
  let roundsAfterTask = providerRounds()
  proc followupRefused(label: string) =
    # Measure the calls this check makes, not a baseline from an earlier turn:
    # the scenario deliberately runs provider work between these checks.
    let before = providerRounds()
    let followup = call(nc, "core", "session", %*{"sessionId": session,
      "content": "Continue editing with your previous grant."}, 60_000)
    check(label, followup{"error"}.getStr("").contains("fresh activation grant"),
      $followup)
    let wake = call(nc, "core", "session", %*{"sessionId": session,
      "wake": true}, 60_000)
    check(label & " (wake)",
      wake{"error"}.getStr("").contains("fresh activation grant"), $wake)
    let imageTurn = call(nc, "core", "session", %*{"sessionId": session,
      "attachments": [{"type": "image"}]}, 60_000)
    check(label & " (image turn)",
      imageTurn{"error"}.getStr("").contains("fresh activation grant"), $imageTurn)
    check(label & " spends no provider calls", providerRounds() == before)
  followupRefused("live task cannot reuse authority for content-only follow-up")
  let replay = submit()
  check("an exact task retry returns the existing terminal receipt",
    replay{"admissionReplay"}.getBool(false) and
    replay{"admission", "turnId"} == ran{"admission", "turnId"}, $replay)
  check("task replay spends no provider round trip", providerRounds() == roundsAfterTask)
  let changedGrant = submit(%*{"task": {"profile": "other", "workspace": workspace,
    "tools": ["read", "edit"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000}})
  check("same admission key cannot name a different task grant",
    changedGrant{"error"}.getStr("").contains("different work"), $changedGrant)

  # --- refusals: explicit, and no work runs -------------------------------
  # Captured HERE: the unchanged-grant turn above legitimately spent rounds,
  # and every refusal below must add none.
  let roundsBefore = providerRounds()
  var widening = %*{"sessionId": session & "-wide", "content": "do more",
    "task": {"profile": "coding", "workspace": workspace,
             "tools": ["read", "invoke"], "maxRounds": 2, "maxCalls": 4,
             "maxTokens": 20000},
    "admission": {"key": key("act-wide"), "policyVersion": 1}}
  let widened = call(nc, "core", "session", widening, 60_000)
  check("an indirect-delegation tool is refused, never granted",
        widened{"error"} != nil and
        widened{"error"}.getStr("").contains("control-plane"), $widened)

  var overRoot = widening.copy()
  overRoot["sessionId"] = %(session & "-root")
  overRoot["admission"] = %*{"key": key("act-root"), "policyVersion": 1}
  overRoot["task"] = %*{"profile": "coding", "workspace": "/etc",
    "tools": ["read"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000}
  let rooted = call(nc, "core", "session", overRoot, 60_000)
  check("a workspace outside the operator's roots is refused",
        rooted{"error"} != nil and
        rooted{"error"}.getStr("").contains("outside"), $rooted)

  # The worker audits its own live catalog, not the requester's claim: a tool
  # the operator profile names but this harness does not serve cannot run.
  var ghostProfile = putProfile("ghost",
    %*["read", "unavailable_plugin_tool"], workspace)
  check("the ghost profile was stored", ghostProfile{"ok"}.getBool(false), $ghostProfile)
  var ghost = overRoot.copy()
  ghost["sessionId"] = %(session & "-ghost")
  ghost["admission"] = %*{"key": key("act-ghost"), "policyVersion": 1}
  ghost["task"] = %*{"profile": "ghost", "workspace": workspace,
    "tools": ["read", "unavailable_plugin_tool"], "maxRounds": 2,
    "maxCalls": 4, "maxTokens": 20000}
  let ghosted = call(nc, "core", "session", ghost, 60_000)
  check("the worker refuses a granted tool its own catalog does not serve",
    ghosted{"error"}.getStr("").contains("unavailable"), $ghosted)
  discard call(nc, "store", "del", %*{"kind": "taskprofile", "id": "ghost"})

  # A grant mutated after the human approved it must not run: the worker
  # recomputes the digest over what actually arrived and compares it with the
  # requester's pre-dispatch record.
  var tampered = overRoot.copy()
  tampered["sessionId"] = %(session & "-tampered")
  tampered["admission"] = %*{"key": key("act-tampered"), "policyVersion": 1}
  tampered["task"] = %*{"profile": "coding", "workspace": workspace,
    "tools": ["read"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000,
    "grantDigest": grantDigest(%*{"profile": "coding", "tools": ["read"],
      "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000})}
  tampered["task"]["tools"] = %*["read", "bash"]
  let mismatched = call(nc, "core", "session", tampered, 60_000)
  check("a grant that changed after approval is refused",
    mismatched{"error"}.getStr("").contains("does not match"), $mismatched)

  var noProfile = overRoot.copy()
  noProfile["sessionId"] = %(session & "-noprofile")
  noProfile["admission"] = %*{"key": key("act-noprofile"), "policyVersion": 1}
  noProfile["task"] = %*{"profile": "does-not-exist", "workspace": workspace,
    "tools": ["read"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000}
  let absent = call(nc, "core", "session", noProfile, 60_000)
  check("an unknown operator profile refuses (no unattended by default)",
        absent{"error"} != nil and
        absent{"error"}.getStr("").contains("unattended authority"), $absent)

  # A profile the operator revoked stops new admissions immediately.
  discard call(nc, "store", "del", %*{"kind": "taskprofile", "id": "coding"})
  followupRefused("revoked task cannot reuse authority")
  # Observe runner retirement rather than merely assuming a sleep restarted it.
  var retired = false
  for _ in 0..<60:
    let snapshot = call(nc, "core", "catalog", %*{"op": "components"})
    if snapshot{"components"} != nil and
        snapshot{"components"}{"session-" & session} == nil:
      retired = true
      break
    sleep(100)
  check("task runner retired before resume checks", retired)
  followupRefused("resumed revoked task cannot reuse persisted authority")
  let revokedReplay = submit()
  check("revocation does not erase an existing activation receipt",
    revokedReplay{"admissionReplay"}.getBool(false) and
    revokedReplay{"admission", "turnId"} == ran{"admission", "turnId"}, $revokedReplay)
  var revoked = overRoot.copy()
  revoked["sessionId"] = %(session & "-revoked")
  revoked["admission"] = %*{"key": key("act-revoked"), "policyVersion": 1}
  revoked["task"] = %*{"profile": "coding", "workspace": workspace,
    "tools": ["read"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000}
  let afterRevoke = call(nc, "core", "session", revoked, 60_000)
  check("a revoked profile refuses new tasks", afterRevoke{"error"} != nil)
  discard putProfile("coding", %*["read", "grep", "edit", "bash", "write"], workspace)

  check("no refusal ran a provider round trip",
        providerRounds() == roundsBefore, $providerRounds())

  # The inverse of the tampered-grant case: identical authority arriving with a
  # matching digest IS admitted and runs. Kept after the no-spend assertion
  # above so this legitimate turn cannot pollute it.
  let intact = call(nc, "core", "session", %*{"sessionId": session & "-intact",
    "content": "do more", "admission": {"key": key("act-intact"), "policyVersion": 1},
    "task": {"profile": "coding", "workspace": workspace,
      "tools": ["read"], "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000,
      "grantDigest": grantDigest(%*{"profile": "coding", "tools": ["read"],
        "maxRounds": 2, "maxCalls": 4, "maxTokens": 20000})}}, 180_000)
  check("a grant that arrives unchanged is accepted",
    intact{"error"} == nil and intact{"taskPolicy", "tools"} == %*["read"], $intact)

  # --- a task cannot re-grant itself --------------------------------------
  # A second grant on an existing task conversation is refused outright: the
  # authority its earlier activations were admitted under is not reinterpreted.
  var escalation = submit(%*{"sessionId": session,
    "admission": {"key": key("act-escalate"), "policyVersion": 1},
    "approvals": "auto", "tools": ["read", "edit", "bash", "write"],
    "maxCalls": 100,
    "task": {"profile": "coding", "workspace": workspace,
             "tools": ["read", "edit", "bash", "write"], "maxRounds": 6,
             "maxCalls": 100, "maxTokens": 50000}})
  # helpers.call flattens the error envelope to its message; the stable code
  # (task-policy-immutable) travels in error.code for structured callers.
  check("a different grant cannot be applied to an existing task conversation",
        escalation{"error"} != nil and
        escalation{"error"}.getStr("").contains("already an unattended task"),
        $escalation)
  check("plain arguments cannot widen an unattended task's grant",
        not escalation{"taskPolicy", "tools"}.getStr("").contains("bash"))

  report("TASK POLICY E2E TEST")

main()
