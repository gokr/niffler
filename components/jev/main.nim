## jev — optional advisory decisions. No authority to discover, load, invoke,
## or approve tools. Backends implement the System One JSON HTTP contract;
## Von is the first local runtime. No Python/model dependency in the harness.

import std/[httpclient, json, os, osproc, strutils, tables, times, uri]
import niffler/sdk

let shadowMode = getEnv("NIF_JEV_SHADOW", "1").toLowerAscii() notin
  ["0", "false", "no", "off"]
let shadowKind = getEnv("NIF_JEV_SHADOW_KIND", "both").strip()
let legacyShadowQuery = getEnv("NIF_JEV_SHADOW_QUERY", "").strip()
let shadowSkillQuery = getEnv("NIF_JEV_SHADOW_SKILL_QUERY", legacyShadowQuery).strip()
let shadowToolQuery = getEnv("NIF_JEV_SHADOW_TOOL_QUERY", legacyShadowQuery).strip()

proc taskSearchQuery(task: string): string =
  ## Derive a bounded lexical query when operators have not configured one.
  for word in task.toLowerAscii().splitWhitespace():
    var cleaned = word
    for ch in [',', '.', ':', ';', '!', '?', '"', '\'', '(', ')', '[', ']']:
      cleaned = cleaned.replace($ch, "")
    if cleaned.len > result.len and cleaned.len <= 200:
      result = cleaned

let comp = newComponent("jev", "0.1.0")

const
  MaxStateBytes = 12_000
  MaxOptions = 24  # bounded shortlist, not the full catalog
  MaxBodyBytes = 128_000
  MaxShadowPending = 32  # 16 turn pairs, each with skills + tools
  MaxShadowTaskBytes = 2000
  ShadowHardTimeoutS = 12.0

type ShadowJob = object
  sessionId, turnId, task, kind, query: string
  startedAt, launchedAt: float
  process: Process
  resultPath, inputPath: string
  candidates: JsonNode

var pending: seq[ShadowJob]
var activeTurns = initTable[string, string]()
var running: ShadowJob

proc backend(): string = getEnv("NIF_JEV_BACKEND", "von").strip()

proc endpoint(): string =
  getEnv("NIF_JEV_URL", "http://127.0.0.1:8000/v1/systemone").strip()

proc localEndpoint(url: string): bool =
  ## Decision inputs may contain private repo context. No remote endpoints
  ## in this local-only spike, including via HTTP redirects.
  try:
    let u = parseUri(url)
    u.scheme == "http" and u.hostname in ["127.0.0.1", "localhost", "[::1"] and
      u.path == "/v1/systemone" and u.username.len == 0 and
      u.password.len == 0 and u.query.len == 0 and u.anchor.len == 0
  except CatchableError:
    false

proc askBackend(state, questions: JsonNode): JsonNode =
  let url = endpoint()
  if not localEndpoint(url):
    return errResult("NIF_JEV_URL must be a loopback HTTP /v1/systemone endpoint")
  let body = $(%*{"state": state, "model": getEnv("NIF_JEV_MODEL", "von-1.1"),
                 "questions": questions})
  if body.len > MaxBodyBytes: return errResult("decision request too large")
  try:
    let client = newHttpClient("niffler-jev/0.1", timeout = 5000,
                               maxRedirects = 0)
    defer: client.close()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    let response = client.request(url, httpMethod = HttpPost, body = body)
    if response.code != Http200:
      return errResult("decision backend HTTP " & $response.code)
    if response.body.len > MaxBodyBytes:
      return errResult("decision backend response too large")
    let data = parseJson(response.body)
    if data.kind != JObject or data{"answers"} == nil or
        data{"answers"}.kind != JObject:
      return errResult("decision backend returned no answers")
    return data["answers"]
  except CatchableError as e:
    return errResult("decision backend unavailable: " & e.msg)

proc validCandidates(candidates: JsonNode): string =
  if candidates == nil or candidates.kind != JArray or
      candidates.len == 0 or candidates.len > MaxOptions:
    return "candidates must contain 1..24 entries"
  var seen: seq[string]
  for item in candidates:
    if item.kind != JObject or item{"name"} == nil or
        item{"name"}.kind != JString or item{"description"} == nil or
        item{"description"}.kind != JString:
      return "each candidate needs a name and description string"
    let name = item["name"].getStr("")
    if name.len == 0 or name.len > 128 or name in seen or
        item["description"].getStr("").len > 1000:
      return "candidate names must be unique and descriptions bounded"
    seen.add(name)
  ""

proc suggest(task: string, candidates: JsonNode): JsonNode =
  if task.strip().len == 0 or task.len > MaxStateBytes:
    return errResult("task must be 1..12000 bytes")
  let invalid = validCandidates(candidates)
  if invalid.len > 0: return errResult(invalid)
  var criteria = newJObject()
  for item in candidates:
    criteria[item["name"].getStr()] = item["description"]
  let answers = askBackend(%task, %*{
    "needed": {"type": "noul", "instructions":
      "Would any of these capabilities help with this task?"},
    "pick": {"type": "choice", "instructions":
      "Which capability best helps with this task?", "criteria": criteria}
  })
  if answers{"error"} != nil: return answers
  let needed = answers{"needed"}{"noul"}
  let pick = answers{"pick"}{"choice"}
  if needed == nil or needed.kind notin {JFloat, JInt} or
      pick == nil or pick.kind != JString:
    return errResult("decision backend returned malformed answers")
  let probability = needed.getFloat()
  let choice = pick.getStr()
  if probability < 0 or probability > 1 or not criteria.hasKey(choice):
    return errResult("decision backend returned an invalid choice")
  %*{"ok": true, "backend": backend(),
     "suggestion": (if probability >= 0.5: choice else: ""),
     "needsCapability": probability, "answers": answers,
     "note": "advisory only; use discover/skill_list and normal dispatch"}

comp.tool(%*{"onDemand": true, "effect": "read", "timeoutMs": 7000}):
  proc jev_suggest(task: string, candidates: JsonNode): JsonNode =
    ## Suggest which of a SHORTLIST of discoverable tools or skills fits a
    ## task. Pass names/descriptions from discover or skill_list; suggestions
    ## are advisory, never permissions. No tool schemas are loaded or
    ## invoked here. On no-match or backend failure, fall back to ordinary
    ## discover/skill_list. Recheck discovery after any catalogue change.
    ## - task: short user intent (not full private files or secrets)
    ## - candidates: 1..24 {name, description} entries, from discovery
    suggest(task, candidates)

comp.tool(%*{"onDemand": true, "effect": "read", "timeoutMs": 7000}):
  proc jev_decide(state: JsonNode, questions: JsonNode): JsonNode =
    ## Ask the local System One backend typed questions without side effects.
    ## Advisory only. For tool/skill selection prefer jev_suggest, which
    ## pairs a no-match check with a choice. Never use this as an approval gate.
    ## - state: bounded string, object or array
    ## - questions: map of up to 16 choice/noul/score questions
    if state == nil or state.kind notin {JString, JObject, JArray} or
        ($state).len > MaxStateBytes:
      return errResult("state must be a bounded string, object or array")
    if questions == nil or questions.kind != JObject or
        questions.len == 0 or questions.len > 16:
      return errResult("questions must be an object of 1..16 entries")
    for _, q in questions:
      if q.kind != JObject or q{"instructions"} == nil or
          q{"instructions"}.kind != JString or
          q{"type"}.getStr("") notin ["choice", "noul", "score"]:
        return errResult("invalid typed question")
      let kind = q["type"].getStr()
      let criteria = q{"criteria"}
      if (kind == "choice" and (criteria == nil or criteria.kind != JObject or
          criteria.len == 0 or criteria.len > 255)) or
         (kind == "score" and (criteria == nil or criteria.kind != JArray or
          criteria.len == 0 or criteria.len > 255)):
        return errResult("choice/score needs 1..255 criteria")
    let answers = askBackend(state, questions)
    if answers{"error"} != nil: return answers
    %*{"ok": true, "backend": backend(), "answers": answers}

proc addCandidate(candidates: var JsonNode, name, description: string) =
  ## Retain one sentinel past the shortlist cap to detect overflow.
  if candidates.len <= MaxOptions:
    candidates.add(%*{"name": name, "description": description})

proc candidatesFor(kind, query, task: string): JsonNode =
  result = newJArray()
  if kind == "tools":
    let effectiveQuery = if query.len > 0: query else: taskSearchQuery(task)
    if effectiveQuery.len == 0: return
    let found = comp.request("core", "discover", %*{"query": effectiveQuery}, 3000)
    let components = found{"components"}
    if components == nil or components.kind != JArray:
      raise newException(IOError, "discover unavailable")
    for component in components:
      let hints = component{"onDemand"}
      if hints == nil or hints.kind != JArray: continue
      for hint in hints:
        let name = hint{"name"}.getStr("")
        if name in ["jev_recommend", "jev_suggest", "jev_decide"]: continue
        addCandidate(result, name, hint{"description"}.getStr(""))
  else:
    let found = comp.request("skills", "skill_list", %*{"query": query}, 3000)
    if not found{"ok"}.getBool(false) or found{"skills"} == nil or
        found["skills"].kind != JArray:
      raise newException(IOError, "skill_list unavailable")
    for skill in found["skills"]:
      addCandidate(result, skill{"name"}.getStr(""), skill{"description"}.getStr(""))

proc recommend(task, kind, query: string): JsonNode =
  ## Pull fresh bus metadata; never persist or cache catalogue state. Core's
  ## discover omits hidden tools. The caller decides whether to discover/load.
  if kind notin ["tools", "skills"]:
    return errResult("kind must be tools or skills")
  if query.strip().len == 0 or query.len > 200:
    return errResult("query must be 1..200 characters")
  if task.strip().len == 0 or task.len > MaxStateBytes:
    return errResult("task must be 1..12000 bytes")
  var candidates: JsonNode
  try:
    candidates = candidatesFor(kind, query, task)
  except CatchableError as e:
    return errResult("discovery unavailable: " & e.msg)
  if candidates.len == 0:
    return %*{"ok": true, "kind": kind, "query": query,
              "candidates": candidates, "suggestion": "",
              "note": "no matching candidates; use ordinary discovery"}
  if candidates.len > MaxOptions:
    return errResult("more than 24 candidates; narrow the query")
  let invalid = validCandidates(candidates)
  if invalid.len > 0: return errResult(invalid)
  let judged = suggest(task, candidates)
  if not judged{"ok"}.getBool(false): return judged
  result = judged
  result["kind"] = %kind
  result["query"] = %query
  result["candidates"] = candidates

comp.tool(%*{"onDemand": true, "effect": "read", "timeoutMs": 12000}):
  proc jev_recommend(task: string, query: string, kind: string = "tools"): JsonNode =
    ## One-call, opt-in advisory discovery: look up current on-demand tools
    ## via core.discover or skills via skill_list, then ask the configured
    ## local decision model which fits. Never loads schemas/skills or invokes
    ## anything. A narrow query is essential (24-candidate limit); an empty
    ## recommendation is valid. Results enter append-only tool history; the
    ## frozen system prompt and direct toolset are unchanged. Backend failure
    ## leaves ordinary discover/skill_list available.
    ## - task: short user intent, not secrets or entire file contents
    ## - query: discovery keyword for the candidate shortlist
    ## - kind: "tools" (on-demand only) or "skills"
    recommend(task, kind, query)

proc persistShadow(job: ShadowJob, status: string, verdict: JsonNode = nil) =
  let id = job.sessionId & ":" & job.turnId & ":" & job.kind
  var doc = %*{"sessionId": job.sessionId, "turnId": job.turnId,
    "kind": job.kind, "query": job.query, "backend": backend(),
    "task": job.task, "candidates": job.candidates,
    "startedAt": job.startedAt, "status": status}
  if verdict != nil:
    let finishedAt = epochTime()
    doc["result"] = verdict
    doc["finishedAt"] = %finishedAt
    doc["turnClosed"] = %(activeTurns.getOrDefault(job.sessionId) != job.turnId)
    if doc["turnClosed"].getBool(false):
      doc["status"] = %"stale"
    if job.launchedAt > 0:
      doc["elapsedMs"] = %int((finishedAt - job.launchedAt) * 1000)
      doc["queueMs"] = %int((job.launchedAt - job.startedAt) * 1000)
    else:
      doc["elapsedMs"] = %int((finishedAt - job.startedAt) * 1000)
  try:
    discard comp.storePut("jevshadow", id, doc, timeoutMs = 1500)
  except CatchableError as e:
    comp.log("warn", "jev shadow persistence failed", %*{"error": e.msg})

proc judgeProcess() =
  try:
    let arg = parseJson(readFile(paramStr(2)))
    removeFile(paramStr(2))
    let resultPath = paramStr(3)
    let judged = suggest(arg{"task"}.getStr(""), arg{"candidates"})
    writeFile(resultPath, $judged)
  except CatchableError as e:
    try: writeFile(paramStr(3), $(errResult("judge failed: " & e.msg)))
    except CatchableError: discard

proc completeShadow() =
  if running.process == nil: return
  if running.process.peekExitCode() == -1:
    if epochTime() - running.launchedAt > ShadowHardTimeoutS:
      let timedOut = running
      running = ShadowJob()
      timedOut.process.terminate()
      sleep(10)
      if timedOut.process.running(): timedOut.process.kill()
      timedOut.process.close()
      if fileExists(timedOut.inputPath): removeFile(timedOut.inputPath)
      if fileExists(timedOut.resultPath): removeFile(timedOut.resultPath)
      persistShadow(timedOut, "error", errResult("judge timed out"))
    return
  let job = running
  running = ShadowJob()
  let exitCode = job.process.peekExitCode()
  job.process.close()
  var verdict = errResult("judge exited " & $exitCode)
  try:
    if exitCode == 0 and fileExists(job.resultPath): verdict = parseFile(job.resultPath)
  except CatchableError as e:
    verdict = errResult("judge output unreadable: " & e.msg)
  if fileExists(job.resultPath): removeFile(job.resultPath)
  if fileExists(job.inputPath): removeFile(job.inputPath)
  let failed = not verdict{"ok"}.getBool(false)
  persistShadow(job, if failed: "error" else: "done", verdict)

proc startShadow(job: ShadowJob) =
  var task = job
  task.launchedAt = epochTime()
  let dir = rootVarDir("jev-shadow")
  createDir(dir)
  let key = newId()
  task.inputPath = dir / (key & ".input.json")
  task.resultPath = dir / (key & ".result.json")
  try:
    writeFile(task.inputPath, $(%*{"task": task.task, "candidates": task.candidates}))
    task.process = startProcess(getAppFilename(), args = ["--judge", task.inputPath,
      task.resultPath], options = {poParentStreams})
    running = task
  except CatchableError as e:
    if fileExists(task.inputPath): removeFile(task.inputPath)
    persistShadow(task, "error", errResult("judge start failed: " & e.msg))

proc onTurn(comp: Component, subject, raw: string) =
  if not shadowMode or not subject.endsWith(".turn"): return
  var env: Envelope
  try: env = decode(raw)
  except CatchableError: return
  if env.kind != ekEvent: return
  let p = env.payload
  let sid = p{"sessionId"}.getStr("")
  let tid = p{"turnId"}.getStr("")
  if sid.len == 0 or tid.len == 0 or subject != "ev.session." & sid & ".turn": return
  let phase = p{"phase"}.getStr("")
  if phase == "done":
    if activeTurns.getOrDefault(sid) == tid: activeTurns.del(sid)
    return
  if phase != "start": return
  activeTurns[sid] = tid
  let task = p{"content"}.getStr("").strip()
  if task.len == 0 or task.len > MaxShadowTaskBytes or
      shadowKind notin ["tools", "skills", "both"] or
      shadowSkillQuery.len > 200 or shadowToolQuery.len > 200:
    return
  let kinds = if shadowKind == "both": @[("skills", shadowSkillQuery),
                                            ("tools", shadowToolQuery)]
              else: @[(shadowKind, if shadowKind == "skills": shadowSkillQuery
                                    else: shadowToolQuery)]
  if pending.len + kinds.len > MaxShadowPending: return
  for (kind, query) in kinds:
    pending.add(ShadowJob(sessionId: sid, turnId: tid, task: task,
      kind: kind, query: query, startedAt: epochTime()))

discard comp.tap("ev.session.>", onTurn)
discard comp.onIdle(250) do (c: Component):
  completeShadow()
  if running.process != nil or pending.len == 0: return
  let job = pending[0]
  pending.delete(0)
  if activeTurns.getOrDefault(job.sessionId) != job.turnId:
    persistShadow(job, "stale")
    return
  try:
    let query = if job.kind == "tools" and job.query.len == 0:
      taskSearchQuery(job.task)
      else: job.query
    var completed = job
    completed.query = query
    completed.candidates = candidatesFor(completed.kind, query, completed.task)
    if completed.candidates.len == 0 or completed.candidates.len > MaxOptions or
        validCandidates(completed.candidates).len > 0:
      persistShadow(completed, "no-candidates")
      return
    persistShadow(completed, "pending")
    startShadow(completed)
  except CatchableError as e:
    persistShadow(job, "error", errResult("discovery failed: " & e.msg))

when isMainModule:
  if paramCount() == 3 and paramStr(1) == "--judge": judgeProcess()
  else: comp.run()
