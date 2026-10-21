## Fleet task pointers belong to the requester; transcripts stay on the worker.
## Only queued proves dispatch has never been attempted. Unknown is not replayable.
import std/[json, os, osproc, strutils, times, tables]
import checksums/sha1
import natsnim
import niffler/sdk
import provision

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
proc validateTask*(args: JsonNode) =
  if args{"content"}.getStr("").len notin 1..65536: refuse("content must be 1..65536 bytes")
  validateRoot(args{"cwd"}.getStr(""))
  let tools = args{"tools"}
  if tools == nil or tools.kind != JArray or tools.len notin 1..16:
    refuse("explicit tools required (1..16)")
  for t in tools:
    let name = t.getStr("")
    if name notin ["read", "grep", "git_status", "git_diff", "git_log", "git_show", "git_blame"]:
      refuse("first slice permits only audited file/search/git read tools")
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
    refuse("peer refused call")

proc validateCapabilities*(catalog, schemas, task: JsonNode) =
  if catalog{"taskScopeVersion"}.getInt(0) != 1:
    refuse("peer lacks model-originated tool scope enforcement")
  let comps = catalog{"components"}
  if comps == nil or comps.kind != JObject: refuse("malformed peer catalog")
  var available: seq[string]
  for _, names in comps:
    if names.kind != JArray: refuse("malformed component tool list")
    for name in names:
      if name.kind != JString: refuse("malformed tool name")
      available.add(name.getStr())
  for name in ["session", "session_prepare", "get", "list", "catalog"]:
    if name notin available: refuse("peer lacks " & name)
  let entries = schemas{"tools"}
  if entries == nil or entries.kind != JArray: refuse("malformed schema snapshot")
  for t in task["tools"]:
    let name = t.getStr()
    var found = false
    for entry in entries:
      if entry{"name"}.getStr("") != name: continue
      let schema = entry{"schema"}
      if schema == nil or schema.kind != JObject: refuse("missing tool schema")
      let x = schema{"x-harness"}
      if x == nil or x{"effect"}.getStr("") != "read" or
          x{"sessionContext"}.getBool(false) or x{"noSpawn"}.getBool(false) or
          x{"runner"}.getBool(false) or x{"hidden"}.getBool(false):
        refuse("task tools must be read-only non-orchestrators")
      found = name in available
    if not found: refuse("peer tool unavailable: " & name)

proc publicJob*(j: JsonNode): JsonNode =
  result = j.copy()
  for key in ["task", "receipt", "profile"]: result.delete(key)
proc authorized*(c: Component, args: JsonNode): StoreItem =
  result = c.storeGet("fleetjob", args{"jobId"}.getStr(""))
  if result.value{"owner"}.getStr("") != owner(args): refuse("foreign fleet job")
proc createJob*(c: Component, args: JsonNode): JsonNode =
  let session = owner(args)
  validateTask(args)
  let id = jobId(session, args{"requestId"}.getStr(""))
  var task = newJObject()
  for key in ["content", "cwd", "tools", "maxRounds", "maxCalls", "maxTokens"]:
    task[key] = args[key]
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
    "receipt": p, "task": task, "state": "queued", "createdAt": epochTime(), "checkedAt": 0}
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
  if j{"state"}.getStr("") == "settled": return
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
      task["approvals"] = %"ask"
      # Short request timeout is NOT a turn deadline. The remote runner owns
      # the finite round/call/token budgets; no unsupported maxSeconds field.
      try: discard remoteCall(run, p, "session", task, 1)
      except CatchableError: discard
    let completion = remoteCall(run, p, "list", %*{"kind": "activity", "idPrefix": id, "limit": 2})
    var receipt: JsonNode
    let completions = completion{"items"}
    if completions == nil or completions.kind != JArray: refuse("invalid completion listing")
    for entry in completions:
      if entry{"id"}.getStr("") == id: receipt = entry{"value"}
    # The task owns one activation only. A later human turn can replace the
    # latest-per-session activity receipt; never attribute that to our task.
    if receipt != nil and receipt{"sessionId"}.getStr("") == id and receipt{"seq"}.getInt(0) == 1:
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
