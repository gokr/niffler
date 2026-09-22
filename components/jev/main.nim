## jev — optional advisory decisions. No authority to discover, load, invoke,
## or approve tools. Backends implement the System One JSON HTTP contract;
## Von is the first local runtime. No Python/model dependency in the harness.

import std/[httpclient, json, os, strutils, uri]
import niffler/sdk

let comp = newComponent("jev", "0.1.0")

const
  MaxStateBytes = 12_000
  MaxOptions = 24  # bounded shortlist, not the full catalog
  MaxBodyBytes = 128_000

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
    if response.code != Http200: return errResult("decision backend HTTP " & $response.code)
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

proc recommend(task, kind, query: string): JsonNode =
  ## Pull fresh bus metadata; never persist or cache catalogue state. Core's
  ## discover omits hidden tools. The caller decides whether to discover/load.
  if kind notin ["tools", "skills"]:
    return errResult("kind must be tools or skills")
  if query.strip().len == 0 or query.len > 200:
    return errResult("query must be 1..200 characters")
  if task.strip().len == 0 or task.len > MaxStateBytes:
    return errResult("task must be 1..12000 bytes")
  var candidates = newJArray()
  try:
    if kind == "tools":
      let found = comp.request("core", "discover", %*{"query": query}, 3000)
      let components = found{"components"}
      if components == nil or components.kind != JArray:
        return errResult("discover unavailable")
      for component in components:
        let hints = component{"onDemand"}
        if hints == nil or hints.kind != JArray: continue
        for hint in hints:
          let name = hint{"name"}.getStr("")
          if name in ["jev_recommend", "jev_suggest", "jev_decide"]: continue
          candidates.add(%*{"name": name,
                            "description": hint{"description"}.getStr("")})
    else:
      let found = comp.request("skills", "skill_list", %*{"query": query}, 3000)
      if not found{"ok"}.getBool(false) or found{"skills"} == nil or
          found{"skills"}.kind != JArray:
        return errResult("skill_list unavailable")
      for skill in found["skills"]:
        candidates.add(%*{"name": skill{"name"}.getStr(""),
                          "description": skill{"description"}.getStr("")})
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

comp.run()
