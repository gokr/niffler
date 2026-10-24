## Fleet task pointers belong to the requester; transcripts stay on the worker.
## Only queued proves dispatch has never been attempted. Unknown is not replayable.
import std/[json, os, osproc, strutils, times, tables]
import checksums/sha1
import natsnim
import niffler/sdk
import provision
# The admission contract (key shape, policy version, receipt vocabulary) is
# core's generic seam — importing the pure module keeps the requester and the
# worker from drifting into two spellings of one protocol.
import niffler/admission
# Same reason: the task-policy contract (control-plane set, effective-policy
# shape, honest confinement wording) must not drift between peers.
import niffler/taskpolicy
import niffler/codingartifact

proc connectedRunner*(c: Component): CommandRunner =
  ## Service protocol traffic only while waiting for a transport child. Do not
  ## dispatch queued handlers: install/update must remain serialized.
  var lastPump = 0.0
  result = proc(argv: seq[string], input: string, timeoutMs: int): CommandResult =
    nativeRunnerWithWait(argv, input, timeoutMs, proc() =
      if epochTime() - lastPump >= 0.1:
        lastPump = epochTime()
        # Flush pumps PING/PONG and queues incoming messages without invoking
        # component handlers. Failure must not replay a remote mutation.
        discard natsConnection_FlushTimeout(c.nc.conn, 50))

proc refuse(s: string) {.noreturn.} = raise newException(ValueError, s)
proc owner*(args: JsonNode): string =
  result = args{"__session", "session"}.getStr("")
  if result.len == 0: refuse("session context required")
proc jobId*(session, requestId: string): string =
  if requestId.len < 1 or requestId.len > 128: refuse("requestId must be 1..128 bytes")
  "fleet-" & ($secureHash($(%*[session, requestId]))).toLowerAscii()

proc admissionKey*(id: string): string =
  ## The worker-side idempotency key of one job = its local id. One job is one
  ## activation, so the job id IS the stable admission identity: a retry after
  ## a lost reply re-presents the same key and the worker either reports the
  ## existing acceptance/receipt or refuses a second turn.
  id
proc taskMode*(args: JsonNode): string =
  ## "ask" (the original read-only slice) or "unattended" (F2). An absent
  ## `mode` is the read-only slice, so an existing caller keeps exactly the
  ## authority it had.
  ##
  ## The RECORDED grant answers too: validation runs again on the stored job
  ## during reconciliation, and by then the mode lives beside the grant fields
  ## it describes instead of in the caller's original argument.
  var mode = args{"mode"}.getStr("").strip()
  if mode.len == 0: mode = args{"task", "mode"}.getStr("").strip()
  if mode.len == 0: return "ask"
  if mode notin ["ask", "unattended"]:
    refuse("mode must be 'ask' or 'unattended'")
  mode

proc profileName*(args: JsonNode): string =
  ## The operator profile this task asks for. Accepted from the caller's
  ## `taskProfile` (the submit argument) or from the recorded grant
  ## (`task.profile`), because validation runs again on the stored job during
  ## reconciliation — by then the grant is the durable copy, not the call.
  result = args{"taskProfile"}.getStr("").strip()
  if result.len == 0: result = args{"task", "profile"}.getStr("").strip()

proc validateTask*(args: JsonNode) =
  if args{"content"}.getStr("").len notin 1..65536: refuse("content must be 1..65536 bytes")
  validateRoot(args{"cwd"}.getStr(""))
  let tools = args{"tools"}
  if tools == nil or tools.kind != JArray or tools.len notin 1..16:
    refuse("explicit tools required (1..16)")
  if taskMode(args) == "ask":
    for t in tools:
      let name = t.getStr("")
      if name notin ["read", "grep", "git_status", "git_diff", "git_log", "git_show", "git_blame"]:
        refuse("the read-only slice permits only audited file/search/git read tools" &
               " (use mode 'unattended' with an approved task profile for coding)")
  else:
    # Unattended authority is granted by the WORKER's operator profile, which
    # the requester cannot read; it may only name tools it wants and must never
    # smuggle control-plane machinery through as a request.
    if profileName(args).len == 0:
      refuse("unattended mode needs a `taskProfile` naming an operator profile")
    for t in tools:
      let name = t.getStr("")
      if name.len == 0: refuse("tools entries must be non-empty")
      if isControlPlane(name):
        refuse("tool '" & name & "' is control-plane machinery and cannot be requested")
  for (key, maximum) in [("maxRounds", 32), ("maxCalls", 100), ("maxTokens", 100000)]:
    if args{key}.getInt(0) notin 1..maximum: refuse(key & " out of bounds")

proc remoteCall*(run: CommandRunner, p: JsonNode, tool: string, args: JsonNode,
                 seconds = 10): JsonNode =
  discard probe(run, p)
  let script = guard(p) & "root=" & quoteShell(p["root"].getStr()) & "\n" & """
url=$(< "$root/var/nats-url")
[[ "$url" =~ ^nats://127\.0\.0\.1:[0-9]+$ ]] || exit 1
""" & "\"$root/var/bin/cli\" --bus \"$url\" --timeout " & $seconds &
    " call " & quoteShell(tool) & " " & quoteShell($args) & "\n"
  result = parseJson(remote(run, p, script, (seconds + 65) * 1000))
  if result.kind != JObject: refuse("invalid peer reply")
  if result.hasKey("args"): result = result["args"]
  if result.kind != JObject or result.hasKey("error") or
      (result{"ok"} != nil and not result{"ok"}.getBool(true)):
    # Name the peer's own reason: "peer refused call" told an operator nothing
    # about whether the refusal was authority, identity, capability or a
    # transient failure, and those call for completely different actions.
    var why = result{"error"}.getStr("")
    if why.len == 0: why = result{"message"}.getStr("")
    let code = result{"code"}.getStr("")
    refuse("peer refused " & tool & ": " &
           (if why.len > 0: why else: "no reason given") &
           (if code.len > 0: " [" & code & "]" else: ""))

# --- remote cancellation -----------------------------------------------------
# Cancelling ACTIVE remote work is a cross-machine operation, and the honest
# contract is narrower than "cancelled": the peer must acknowledge the request.
# The alternative — flipping local state to "cancelled" — would be the exact
# failure docs/FLEET.md §6 forbids, a local claim about remote work that may
# still be running.
#
# Cancellation rides the same cooperative side-channel subagents use
# (`__cancel` on the steer subject), which the runner checks between rounds,
# plus the llm cancel channel to abort an in-flight streaming request. So the
# peer stops PROMPTLY, not instantly: a tool already executing runs to
# completion (bash kills its process group; see the cancel side-channel docs).

proc remoteCancel*(run: CommandRunner, p: JsonNode, remoteSession: string): JsonNode =
  ## Ask the peer to stop one of its sessions, and return the peer's own reply.
  ##
  ## `session {stop: true}` is the peer-side surface for the same cooperative
  ## cancel a bus client sends directly: the runner raises its flag between
  ## rounds, an in-flight tool finishes first. `agent_stop` was the wrong tool
  ## and a useful mistake to have made live — it operates on `agentjob` records
  ## (subagents), so it answered "unknown job" for a fleet task, which is a
  ## CONVERSATION session. A peer without the `stop` op refuses, which is
  ## correct: an operator must learn that cancellation is unavailable rather
  ## than assume it worked.
  remoteCall(run, p, "session", %*{"sessionId": remoteSession, "stop": true},
             seconds = 20)

proc validateCapabilities*(catalog, schemas, task: JsonNode) =
  if catalog{"taskScopeVersion"}.getInt(0) != 1:
    refuse("peer lacks model-originated tool scope enforcement")
  # Durable admission (docs/FLEET.md §4, slice F1): without the worker's
  # idempotency record a lost reply can never be reconciled, and retrying could
  # run the task twice. An older peer is refused BEFORE anything is dispatched.
  if catalog{"admissionPolicyVersion"}.getInt(0) != admissionPolicyVersion:
    refuse("peer lacks durable task admission (admissionPolicyVersion " &
           $admissionPolicyVersion & ")")
  if taskMode(task) == "unattended" and
      catalog{"taskPolicyVersion"}.getInt(0) != taskPolicyVersion:
    refuse("peer lacks unattended task policy enforcement (taskPolicyVersion " &
           $taskPolicyVersion & ")")
  let comps = catalog{"components"}
  if comps == nil or comps.kind != JObject: refuse("malformed peer catalog")
  var available: seq[string]
  for _, names in comps:
    if names.kind != JArray: refuse("malformed component tool list")
    for name in names:
      if name.kind != JString: refuse("malformed tool name")
      available.add(name.getStr())
  for name in ["session", "session_prepare", "admission_get", "get", "list",
               "catalog"]:
    if name notin available: refuse("peer lacks " & name)
  let entries = schemas{"tools"}
  if entries == nil or entries.kind != JArray: refuse("malformed schema snapshot")
  # Two different questions, decided by the task's own mode:
  #
  # - the read-only slice (mode ask) may only name audited READ tools: it is a
  #   bounded investigation, and a write-shaped tool there would be authority
  #   the requester never approved;
  # - an unattended task may name writers, but its schema must still not be
  #   control-plane or an orchestrator. That second class is the single-hop
  #   boundary (docs/FLEET.md §3) and it applies in every mode, so `invoke`,
  #   `fabric`, `agent*`, `fleet_*` and friends are refused whatever the
  #   operator's profile says — and the worker re-checks it too.
  let unattended = taskMode(task) == "unattended"
  for t in task["tools"]:
    let name = t.getStr()
    var found = false
    for entry in entries:
      if entry{"name"}.getStr("") != name: continue
      let schema = entry{"schema"}
      if schema == nil or schema.kind != JObject: refuse("missing tool schema")
      let x = schema{"x-harness"}
      if x == nil:
        refuse("task tool '" & name & "' declares no x-harness contract")
      if x{"sessionContext"}.getBool(false) or x{"noSpawn"}.getBool(false) or
          x{"runner"}.getBool(false) or x{"hidden"}.getBool(false):
        refuse("task tool '" & name & "' is orchestrator or runner machinery")
      if not unattended and x{"effect"}.getStr("") != "read":
        refuse("the read-only slice permits only read-effect tools (got '" &
               name & "'); use mode 'unattended' for coding authority")
      found = name in available
    if not found: refuse("peer tool unavailable: " & name)

proc publicJob*(j: JsonNode): JsonNode =
  result = j.copy()
  for key in ["task", "receipt", "profile"]:
    if result.hasKey(key): result.delete(key)
# Human-scope reads: these do NOT require session context, and that is
# deliberate. The owner check on job tools exists so one CONVERSATION cannot
# touch another conversation's work; a human at a keyboard is not a
# conversation. Without this, the inbox (which lists every job) and the report
# behind it (which needs a session to exist at all) would disagree about who is
# allowed to look — shipping a drill-down that can never answer from a client.
proc humanReadable*(args: JsonNode): bool =
  result = args{"__session", "human"}.getBool(false) or
           args{"human"}.getBool(false)

proc authorized*(c: Component, args: JsonNode): StoreItem =
  result = c.storeGet("fleetjob", args{"jobId"}.getStr(""))
  if humanReadable(args): return
  if result.value{"owner"}.getStr("") != owner(args): refuse("foreign fleet job")
proc createJob*(c: Component, args: JsonNode): JsonNode =
  let session = owner(args)
  validateTask(args)
  let id = jobId(session, args{"requestId"}.getStr(""))
  var task = newJObject()
  for key in ["content", "cwd", "tools", "maxRounds", "maxCalls", "maxTokens"]:
    task[key] = args[key]
  let mode = taskMode(args)
  if mode == "unattended":
    # The immutable grant this job carries: which operator profile, and the
    # scope the requesting human approved. Folded into the job record BEFORE
    # dispatch, so the same requestId can never be reused with a wider grant
    # (the comparison below) and the requester knows exactly what it asked the
    # peer for even if the peer refuses.
    task["mode"] = %"unattended"
    task["taskProfile"] = %profileName(args)
    # The authority the human approved, hashed and recorded BEFORE dispatch.
    # The worker recomputes it from what actually arrives and refuses a
    # mismatch, so a grant mutated in transit or by a later edit cannot run
    # work under authority nobody approved (docs/WIRE.md "Task policy").
    task["grantDigest"] = %grantDigest(%*{
      "profile": profileName(args), "tools": args["tools"],
      "maxRounds": args{"maxRounds"}, "maxCalls": args{"maxCalls"},
      "maxTokens": args{"maxTokens"}})
  else:
    task["mode"] = %"ask"
    task["approvals"] = %"ask"
  let path = receiptPath(args{"profile"}.getStr(""))
  try:
    let previous = c.storeGet("fleetjob", id).value
    if previous["task"] != task or previous{"profile"}.getStr("") != path:
      refuse("requestId already used for different task")
    return publicJob(previous)
  except StoreNotFoundError: discard
  let p = loadReceipt(path)
  if p == nil or getFilePermissions(path) != {fpUserRead, fpUserWrite}:
    refuse("private verified receipt required (0600)")
  let j = %*{"id": id, "sessionId": id, "owner": session, "profile": path,
    "receipt": p, "task": task, "state": "queued", "createdAt": epochTime(),
    "checkedAt": 0, "admission": {"key": admissionKey(id),
      "policyVersion": admissionPolicyVersion}}
  discard c.requestOk("store", "put", %*{"kind": "fleetjob", "id": id, "value": j, "expectRev": -1})
  publicJob(j)

proc summary*(text: string): string =
  ## Bounded UTF-8 prefix, not an assertion that the task succeeded factually.
  var n = min(text.len, 2048)
  while n < text.len and n > 0 and (ord(text[n]) and 0xc0) == 0x80: dec n
  result = text[0..<n]
  if n < text.len: result.add("…")

proc reconcileJob*(c: Component, id: string, run: CommandRunner) =
  var item = c.storeGet("fleetjob", id)
  var j = item.value.copy()
  let wasSettled = j{"state"}.getStr("") == "settled"
  if wasSettled: return
  # Every remotely loaded task is validated again before authority is spent.
  validateTask(j["task"])
  let p = j["receipt"]
  try:
    if j{"state"}.getStr("") == "queued":
      let catalog = remoteCall(run, p, "catalog", %*{"op": "components"})
      let schemas = remoteCall(run, p, "catalog", %*{"op": "schemas", "tools": j["task"]["tools"]})
      validateCapabilities(catalog, schemas, j["task"])
      # Preparing creates an empty header, not a turn. Refuse an occupied id.
      let existing = remoteCall(run, p, "list", %*{"kind": "conversation", "idPrefix": id, "limit": 2})
      if existing{"items"} == nil or existing["items"].kind != JArray:
        refuse("invalid peer conversation listing")
      for entry in existing["items"]:
        if entry{"id"}.getStr("") == id: refuse("remote session id already exists")
      let submitting = j.copy()
      submitting["state"] = %"submitting"
      try:
        item.rev = c.storePut("fleetjob", id, submitting, item.rev)
      except CatchableError:
        # Unknown commit outcome: do not write a stale queued/submitting copy
        # over it. Next read observes the durable truth, never dispatch now.
        raise newException(IOError, "fleet submitting commit not confirmed; no remote turn dispatched")
      j = submitting
      discard remoteCall(run, p, "session_prepare", %*{"sessionId": id})
      var task = j["task"].copy()
      task["sessionId"] = %id
      if taskMode(j["task"]) == "unattended":
        # Unattended: hand the worker the grant (its operator profile ∩ the
        # tools/workspace/budgets this human approved) and let IT resolve the
        # effective policy before any work runs. Deliberately no blanket
        # `approvals: auto` on the wire — that would be a claim, and the
        # worker's own intersection is what actually grants anything.
        task["task"] = %*{"profile": j["task"]{"taskProfile"}.getStr(""),
                          "workspace": j["task"]{"cwd"}.getStr(""),
                          "tools": j["task"]["tools"].copy(),
                          "maxRounds": j["task"]{"maxRounds"},
                          "maxCalls": j["task"]{"maxCalls"},
                          "maxTokens": j["task"]{"maxTokens"},
                          "grantDigest": j["task"]{"grantDigest"}.getStr("")}
        # Deliberately NOT `approvals: auto` or any invented value: the
        # approval gate in the peer accepts only ask/auto, and an unattended
        # task's auto grants come from its task policy, not from this field.
        if task.hasKey("approvals"): task.delete("approvals")
      else:
        task["approvals"] = %"ask"
        if task.hasKey("task"): task.delete("task")
      # The worker-side idempotency key (docs/FLEET.md §4, slice F1): the peer
      # records this key and the birth-settings digest before running a turn,
      # so re-presenting it can only report the existing acceptance/receipt —
      # never run the work twice.
      var admission = newJObject()
      admission["key"] = %admissionKey(id)
      admission["policyVersion"] = %admissionPolicyVersion
      task["admission"] = admission
      # The request timeout is NOT a turn deadline — the remote runner owns
      # the finite round/call/token budgets and there is no supported
      # maxSeconds field. It must still outlive the peer's own runner startup:
      # the first call to a fresh conversation spawns that runner (seconds on a
      # loaded machine), and a timeout shorter than the spawn loses the
      # submission before it is even admitted. A lost reply is recoverable
      # (durable admission + activity receipt); a too-short wait just makes it
      # the common case.
      try: discard remoteCall(run, p, "session", task, 15)
      except CatchableError: discard
    # The worker's durable receipt is read on EVERY reconcile, not only right
    # after a submission: the case it exists for is exactly the one where the
    # submission's own reply was lost (and the job sits in `submitting` or
    # `unknown`). It is a READ, so it can never start, resume or replay a turn,
    # and it turns an unknown activation into an authoritative answer whenever
    # the worker knows one.
    try:
      let admissionDoc = remoteCall(run, p, "admission_get",
        %*{"session": id, "key": admissionKey(id)})
      if admissionDoc{"known"}.getBool(false):
        j["admissionReceipt"] = admissionDoc
      elif j.hasKey("admissionReceipt"):
        j.delete("admissionReceipt")
    except CatchableError:
      discard # the receipt stays an honest unknown; activity may still settle
    let completion = remoteCall(run, p, "list", %*{"kind": "activity", "idPrefix": id, "limit": 2})
    var receipt: JsonNode
    let completions = completion{"items"}
    if completions == nil or completions.kind != JArray: refuse("invalid completion listing")
    for entry in completions:
      if entry{"id"}.getStr("") == id: receipt = entry{"value"}
    # The task owns one activation only. A later human turn can replace the
    # latest-per-session activity receipt; never attribute that to our task.
    # The worker's admission receipt is preferred where it exists: it is bound
    # to this exact activation (key + digest) rather than being the latest turn
    # of a session, and it states whether the transcript is durable.
    let admissionState = j{"admissionReceipt", "admission", "state"}.getStr("")
    if admissionState == "settled":
      let admissionDoc = j{"admissionReceipt", "admission"}
      var after = ""
      var reply = ""
      var transcriptComplete = false
      var userMessages = 0
      for pageNo in 0..<32:
        let page = remoteCall(run, p, "list", %*{"kind": "message", "idPrefix": id & ":", "after": after, "limit": 100})
        let entries = page{"items"}
        if entries == nil or entries.kind != JArray: refuse("invalid transcript")
        for entry in entries:
          if not entry{"id"}.getStr("").startsWith(id & ":"): refuse("foreign transcript")
          let role = entry{"value", "role"}.getStr("")
          if role == "user" and entry{"value", "notice"} == nil and
              entry{"value", "mail"} == nil:
            inc userMessages
          if userMessages > 1:
            transcriptComplete = true
            reply = "[summary unavailable: unmarked user/steer boundary; inspect remote transcript]"
            break
          if role == "assistant":
            reply = summary(entry{"value", "content"}.getStr(""))
        if transcriptComplete: break
        if not page{"hasMore"}.getBool(false):
          transcriptComplete = true
          break
        let next = page{"nextAfter"}.getStr("")
        if next <= after: refuse("invalid transcript cursor")
        after = next
      if not transcriptComplete: reply = summary("[transcript scan capped; report may be partial] " & reply)
      j["state"] = %"settled"
      j["completion"] = %*{"sessionId": id,
        "turnId": admissionDoc{"turnId"}.getStr(""),
        "seq": admissionDoc{"activation"}.getInt(1),
        "outcome": admissionDoc{"outcome"}.getStr("unknown"),
        "source": "worker-admission"}
      j["notice"] = %*{"kind": "fleet-settled", "jobId": id,
        "remoteSession": id, "activation": admissionDoc{"activation"}.getInt(1),
        "status": admissionDoc{"outcome"}.getStr("unknown"),
        "transcriptCommitted": admissionDoc{"transcriptCommitted"}.getBool(false),
        "summary": reply, "summaryLimit": 2048}
      # The authority the work ran under, echoed into the notice so the parent
      # conversation states it instead of assuming it (docs/FLEET.md §5).
      if admissionDoc{"taskPolicy"} != nil and
          admissionDoc{"taskPolicy"}.kind == JObject:
        var notice = newJObject()
        for key, value in j["notice"]: notice[key] = value
        notice["taskPolicyDigest"] =
          %admissionDoc["taskPolicy"]{"digest"}.getStr("")
        notice["confinement"] =
          %admissionDoc["taskPolicy"]{"confinement"}.getStr("")
        # The change itself, not just a description of it (docs/FLEET.md §6):
        # the commit this activation produced against the base it started from,
        # plus a one-line rendering a human can read without opening anything.
        # A prose report beside a SHA is checkable; prose alone is a claim.
        let artifact = admissionDoc{"artifact"}
        if not isNil(artifact):
          notice["artifact"] = artifact
          let oneLine = artifactSummary(artifact)
          if oneLine.len > 0: notice["artifactSummary"] = %oneLine
        j["notice"] = notice
      j["delivered"] = %false
    elif receipt != nil and receipt{"sessionId"}.getStr("") == id and receipt{"seq"}.getInt(0) == 1:
      # Activity certifies a completed turn, not factual task success. Retrieve
      # a bounded reply only from this session, then commit notice WITH job.
      var after = ""
      var reply = ""
      var transcriptComplete = false
      var userMessages = 0
      for pageNo in 0..<32:
        let page = remoteCall(run, p, "list", %*{"kind": "message", "idPrefix": id & ":", "after": after, "limit": 100})
        let entries = page{"items"}
        if entries == nil or entries.kind != JArray: refuse("invalid transcript")
        for entry in entries:
          if not entry{"id"}.getStr("").startsWith(id & ":"): refuse("foreign transcript")
          let role = entry{"value", "role"}.getStr("")
          if role == "user" and entry{"value", "notice"} == nil and
              entry{"value", "mail"} == nil:
            inc userMessages
          if userMessages > 1:
            transcriptComplete = true
            reply = "[summary unavailable: unmarked user/steer boundary; inspect remote transcript]"
            break # unmarked steering and new human turns are indistinguishable
          if role == "assistant":
            reply = summary(entry{"value", "content"}.getStr(""))
        if transcriptComplete: break
        if not page{"hasMore"}.getBool(false):
          transcriptComplete = true
          break
        let next = page{"nextAfter"}.getStr("")
        if next <= after: refuse("invalid transcript cursor")
        after = next
      if not transcriptComplete: reply = summary("[transcript scan capped; report may be partial] " & reply)
      j["state"] = %"settled"
      j["completion"] = receipt
      j["notice"] = %*{"kind": "fleet-settled", "jobId": id,
        "remoteSession": id, "status": receipt{"outcome"}.getStr("unknown"),
        "summary": reply, "summaryLimit": 2048}
      j["delivered"] = %false
    elif admissionState == "running" and epochTime() - j{"admissionReceipt", "ageSeconds"}.getFloat(0) > 3600:
      # A turn may have started, but its receipt is far older than any task
      # budget allows and no activity receipt exists. Still not success or
      # interruption: name it unknown, keep the pointer for a human.
      j["state"] = %"unknown"
    else:
      j["state"] = %"unknown"
    j["reachable"] = %true
    if j.hasKey("diagnostic"): j.delete("diagnostic")
  except CatchableError as e:
    if e.msg.startsWith("fleet submitting commit not confirmed"):
      raise # no diagnostic write may overwrite an uncertain commit
    j["reachable"] = %false
    j["diagnostic"] = %summary(e.msg)
  j["checkedAt"] = %epochTime()
  discard c.storePut("fleetjob", id, j, item.rev)
  # Settle event (docs/FLEET-INBOX.md): a CONNECTED client should be told, not
  # have to poll. Emitted only on a real transition — a settled job returns
  # early above, so re-reads never re-alert — and fire-and-forget: nobody is
  # required to be listening, and a missed event costs nothing because the job
  # record is the durable truth (the inbox reads it later).
  #
  # Carries enough to render a notification without a store round trip, and
  # deliberately no authority: an event never grants anything, and a client
  # that wants to act on it calls a tool like any other caller.
  if not wasSettled and j{"state"}.getStr("") == "settled":
    let notice = j{"notice"}
    var payload = %*{
      "jobId": id,
      "state": "settled",
      "peer": j{"receipt"}{"expect"}{"name"}.getStr(""),
      "peerId": j{"receipt"}{"expect"}{"instanceId"}.getStr(""),
      "objective": summary(j{"task"}{"content"}.getStr("")),
      "status": notice{"status"}.getStr("unknown"),
      "activation": notice{"activation"}.getInt(j{"completion"}{"seq"}.getInt(1)),
      "summary": notice{"summary"}.getStr(""),
      "transcriptCommitted": notice{"transcriptCommitted"}.getBool(false),
      "at": epochTime(),
    }
    if payload{"peer"}.getStr("").len == 0:
      # A removed instance still reports what it did: label the route it ran on.
      payload["peer"] = %j{"receipt"}{"target"}.getStr("")
    if notice{"artifact"} != nil and notice{"artifact"}.kind == JObject:
      # Whole artifact, as above: a toast should be able to say "commit 4a54dee
      # +212/−40 on base 9cba035", which no name/size/digest descriptor can.
      payload["artifact"] = notice{"artifact"}.copy()
    c.emit("ev.fleet.settled", payload)

proc resultPage*(c: Component, args: JsonNode, run: CommandRunner): JsonNode =
  let j = authorized(c, args).value
  let id = j["sessionId"].getStr()
  let after = args{"after"}.getStr("")
  if after.len > 0 and not after.startsWith(id & ":"): refuse("foreign cursor")
  let limit = args{"limit"}.getInt(10)
  if limit notin 1..20: refuse("limit must be 1..20")
  let page = remoteCall(run, j["receipt"], "list", %*{"kind": "message", "idPrefix": id & ":", "after": after, "limit": limit})
  result = %*{"jobId": id, "items": [], "hasMore": page{"hasMore"}.getBool(false), "nextAfter": after}
  let entries = page{"items"}
  if entries == nil or entries.kind != JArray: refuse("invalid transcript")
  for entry in entries:
    if not entry{"id"}.getStr("").startsWith(id & ":"): refuse("foreign transcript")
    result["items"].add(%*{"id": entry["id"], "role": entry{"value", "role"}.getStr(""),
      "content": summary(entry{"value", "content"}.getStr("")), "bounded": true})
    result["nextAfter"] = entry["id"]

proc taskNotices*(c: Component, args: JsonNode): JsonNode =
  let session = args{"session"}.getStr("")
  var notices = newJArray()
  if session.len == 0: refuse("session required")
  for entry in c.storeListAll("fleetjob"):
    let j = entry.value
    if j{"owner"}.getStr("") != session or j{"state"}.getStr("") != "settled" or j{"delivered"}.getBool(false): continue
    notices.add(j["notice"])
    if args{"ack"}.getStr("") == entry.id:
      j["delivered"] = %true
      j["deliveredAt"] = %epochTime()
      discard c.storePut("fleetjob", entry.id, j, entry.rev)
  %*{"count": notices.len, "notices": notices}

var worker: Process
var workerStarted = 0.0
var scanAfter = ""
var lastWake = 0.0
proc reap() =
  if worker != nil and not worker.running():
    worker.close(); worker = nil
proc idleJobs*(c: Component) =
  # Bound one peer's transport occupancy so an unreachable/slow peer cannot
  # starve queued work forever. Killing a worker never changes job outcome;
  # persisted submitting remains uncertain and can only reconcile.
  if worker != nil and epochTime() - workerStarted > 180:
    if worker.running(): worker.kill()
  reap()
  # Notifications use the management process, never the transport worker.
  if epochTime() - lastWake > 10:
    lastWake = epochTime()
    var sessions = initTable[string, bool]()
    for entry in c.storeListAll("fleetjob"):
      let j = entry.value
      if j{"state"}.getStr("") == "settled" and not j{"delivered"}.getBool(false):
        let session = j["owner"].getStr()
        if not sessions.hasKey(session):
          sessions[session] = true
          c.publishCall("svc.core.call", callEnvelope("session", %*{"sessionId": session, "wake": true}, c.name))
  if worker != nil or getEnv("NIF_FLEET_TASK_WORKERS", "1") == "0": return
  let page = c.requestOk("store", "list", %*{"kind": "fleetjob", "after": scanAfter, "limit": 25})
  for entry in page["items"]:
    scanAfter = entry["id"].getStr()
    if entry["value"]{"state"}.getStr("") != "settled" and epochTime() - entry["value"]{"checkedAt"}.getFloat(0) > 15:
      worker = startProcess(getAppFilename(), args = ["--fleet-worker", scanAfter], options = {poParentStreams})
      workerStarted = epochTime()
      return
  if not page{"hasMore"}.getBool(false): scanAfter = ""
proc stopWorker*() =
  if worker != nil:
    if worker.running(): worker.terminate()
    discard worker.waitForExit(2000)
    if worker.running(): worker.kill()
    worker.close(); worker = nil
proc workerMain*() =
  dieWithParent()
  let c = newComponent("fleet-worker", "0.1.0")
  c.nc = connect(getEnv("NIF_NATS_URL"))
  defer: c.nc.close()
  c.reconcileJob(paramStr(2), connectedRunner(c))

# ---------------------------------------------------------------------------
# Human inbox (docs/FLEET-INBOX.md)
#
# A READ VIEW over the `fleetjob` kind, not a new document type. Every job this
# harness submitted already lives here — one record per job, whichever peer ran
# it — carrying its task, lifecycle state and (once settled) a self-contained
# bounded notice. So "an inbox across all remote nifflers" is a query over one
# local kind: nothing is replicated, and no peer needs to be reachable to show
# what happened.
#
# Seen/dismissed state is deliberately NOT here. It is client-local, keyed by
# (instanceId, jobId, activation) — see docs/FLEET-INBOX.md for why: `delivered`
# on the record means "a runner appended the notice to a transcript", which is
# model acknowledgment, and a human's unread count must not be derivable from
# it (FLEET.md §6). Reading this list never acknowledges anything.

const inboxDefaultLimit = 20
const inboxLimitCap = 100

proc inboxEntry(j: JsonNode, peer: string): JsonNode =
  ## One row, bounded. Absent keys are read with explicit defaults: a missing
  ## JsonNode is nil and embedding nil in a `%*` literal crashes (json.nim).
  let state = j{"state"}.getStr("")
  let notice = j{"notice"}
  var row = %*{
    "jobId": j{"sessionId"}.getStr(""),
    "peer": peer,
    "state": state,
    "mode": j{"task"}{"mode"}.getStr(""),
    # The operator's own words, bounded — this is what the row is about.
    "objective": summary(j{"task"}{"content"}.getStr("")),
    "createdAt": j{"createdAt"}.getFloat(0.0),
    "checkedAt": j{"checkedAt"}.getFloat(0.0),
    # Reading a list is not acknowledging it: the runner's delivery flag is
    # reported for transparency, never as a human's seen marker.
    "notified": j{"delivered"}.getBool(false),
  }
  if j{"task"}{"cwd"} != nil: row["cwd"] = %j{"task"}{"cwd"}.getStr("")
  if j{"task"}{"taskProfile"} != nil:
    row["taskProfile"] = %j{"task"}{"taskProfile"}.getStr("")
  if j{"admissionReceipt"}{"outcome"} != nil:
    row["outcome"] = %j{"admissionReceipt"}{"outcome"}.getStr("")
  if state == "settled" and notice != nil and notice.kind == JObject:
    # A settled job's verdict must be answerable from THIS reply: the peer may
    # be down, the remote transcript pruned, the artifact expired. The notice
    # carries a bounded summary for exactly that reason; detail is a separate,
    # on-demand call (fleet_task_result) that needs the peer to answer.
    row["settled"] = %*{
      "activation": notice{"activation"}.getInt(j{"completion"}{"seq"}.getInt(1)),
      "status": notice{"status"}.getStr(j{"completion"}{"outcome"}.getStr("")),
      "summary": notice{"summary"}.getStr(""),
      "transcriptCommitted": notice{"transcriptCommitted"}.getBool(false),
    }
    if notice{"artifact"} != nil and notice{"artifact"}.kind == JObject:
      # The artifact as the peer produced it, carried whole.
      #
      # A whitelist of "descriptor" fields was wrong here and shipped wrong: it
      # listed name/mediaType/size/digest, while a coding artifact carries
      # version/observed/base/head/dirty/untracked/verification/headMoved/
      # onBase/diffstat/producedCommit — none of the four. The row claimed to
      # describe an artifact and described nothing.
      #
      # Carrying it whole is safe because the producer bounds it
      # (codingartifact.nim caps the diffstat and the verification list), and a
      # future field must not need a change here to become visible.
      var desc = notice{"artifact"}.copy()
      if notice{"artifactSummary"} != nil:
        desc["summary"] = %notice{"artifactSummary"}.getStr("")
      row["artifact"] = desc
  row

proc taskInbox*(c: Component, args: JsonNode): JsonNode =
  ## The human inbox: every submitted job, newest state first-class, paged by a
  ## STABLE id cursor. Deliberately not a timestamp watermark: reconnect must be
  ## able to walk the whole kind past any single page, and ids are the only
  ## ordering that cannot shift under a concurrent write.
  let after = args{"after"}.getStr("")
  var limit = args{"limit"}.getInt(inboxDefaultLimit)
  if limit < 1: limit = 1
  if limit > inboxLimitCap: limit = inboxLimitCap
  let wantPeer = args{"peer"}.getStr("")
  let wantState = args{"state"}.getStr("")
  if wantState.len > 0 and wantState notin ["queued", "submitting", "running",
                                            "settled", "failed", "uncertain"]:
    refuse("state must be one of queued|submitting|running|settled|failed|uncertain")

  var items = newJArray()
  var scanned = 0
  var hasMore = false
  var nextAfter = ""
  # Walk by id, filtering after the fact: a filtered `list` cannot page
  # correctly (the cursor must advance over rows the filter rejects, or a page
  # of rejected rows looks like the end).
  var cursor = after
  while true:
    let page = c.requestOk("store", "list",
      %*{"kind": "fleetjob", "after": cursor, "limit": 50})
    let entries = page{"items"}
    if entries == nil or entries.kind != JArray: break
    for entry in entries:
      let j = entry["value"]
      cursor = entry{"id"}.getStr("")
      inc scanned
      if wantState.len > 0 and j{"state"}.getStr("") != wantState: continue
      # The peer is named by its registry identity when the route is still
      # registered; a removed instance still shows what it reported, labelled
      # by the transport target it ran on.
      var peer = j{"receipt"}{"expect"}{"name"}.getStr("")
      if peer.len == 0: peer = j{"receipt"}{"target"}.getStr("")
      if wantPeer.len > 0 and peer != wantPeer and
          j{"receipt"}{"expect"}{"instanceId"}.getStr("") != wantPeer: continue
      if items.len >= limit:
        hasMore = true
        break
      items.add(inboxEntry(j, peer))
    if hasMore or not page{"hasMore"}.getBool(false): break
    if entries.len == 0: break
  if hasMore and items.len > 0:
    nextAfter = items[items.len - 1]{"jobId"}.getStr("")
  %*{"ok": true, "items": items, "count": items.len, "hasMore": hasMore,
     "nextAfter": nextAfter, "scanned": scanned,
     "note": "Reading this list does not acknowledge anything: seen/unread is client state."}
