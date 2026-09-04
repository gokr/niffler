## Conversation loop — the only "product logic" in the harness.
##
## Two drivers:
## - session runners (core/session.nim): one process per conversation,
##   serving svc.session.<sessionId>.call, emitting ev.session.* events
## - svc.core.call "session" (service mode): the system ensures a runner
##   per sessionId and forwards — clients keep one stable address
##
## The interactive admin shell (status commands for the harness itself)
## lives in core/tty.nim — the tty is not a conversation UI.
##
## Conversations and messages persist via the store component (document
## store over the bus); persistence failures degrade gracefully.

import std/[algorithm, json, math, monotimes, os, sequtils, strutils,
    tables, times, unicode]
import natswrapper
import ../sdk/envelope
import ../sdk/niffler/jsonx
import catalog
import dispatch
import supervisor
import retry

## The minimal structural fallback prompt. The real constitution lives in
## the systemprompt component (components/systemprompt/): the session
## runner requests svc.systemprompt.call once per conversation
## (resolveSystemPrompt below, frozen for the conversation's lifetime) and
## uses this only when the component is absent, slow, or broken. Keep this
## tiny — it must teach just enough structure (discover/invoke, session
## persistence) for a degraded-but-usable harness, not the full tutorial.
const systemPromptFmt = """
You are Niffler, a minimal self-extending agent harness (fallback prompt:
the systemprompt component is not answering — components/ or var/bin/ may
be incomplete).
When a task needs a capability your direct tools lack, work down this
ladder before improvising with bash: 1. discover + invoke — live
components may already provide it; 2. skills — skill_list / skill_load;
3. build your own component via builder.build + core.spawn (write source,
invoke builder build {lang, name, source}, invoke core spawn {name,
binary}); 4. only then hand-roll a one-off with bash. The live catalog is
authoritative: never invent or call a tool that is not registered.
Conversations and messages persist automatically via the store.
For routing multi-step work: mechanical, known-shape tasks (fan-out,
search-then-distill, batch edits, polling) belong in a program — discover
and use the `fabric` tool. Exploratory subtasks that need fresh context and
per-step judgment belong in `agent_run` subagents. Single-step requests
stay direct.

Your home is the harness root — the git repo Niffler runs from. Shipped
component sources: components/, SDKs: sdk/, design docs: docs/, build
front door: Makefile. var/ is disposable runtime state — gitignored.
In a session workspace, bash starts inside the repository — no cd/pwd
needed; view and search files with read/grep, not bash cat/sed/grep.
Be concise.
"""

proc systemPrompt(root: string): string =
  ## Minimal degraded fallback (used only when the systemprompt component is
  ## absent/slow). Root is accepted for signature compatibility; the prompt
  ## itself stays path-free for byte stability.
  result = systemPromptFmt

const systemPromptTimeoutMs = 8_000
  ## Generous: the component only reads a few files, but a first-call compile
  ## hiccup on a loaded machine should not degrade every conversation.

proc askSystemPrompt(ct: CoreTools, waitMs: int, sessionId, cwd: string): string =
  ## One request/reply attempt; "" on timeout or any failure.
  try:
    let r = dispatchSubjectCall(ct, "svc.systemprompt.call", "systemprompt",
      %*{"cwd": cwd, "sessionId": sessionId}, waitMs)
    result = r{"systemPrompt"}.getStr("")
  except CatchableError:
    result = ""

proc resolveSystemPrompt*(ct: CoreTools, sessionId: string,
                          cwd = ""): string =
  ## The conversation's system prompt: ask the systemprompt component once
  ## per conversation and freeze the answer for the conversation's lifetime
  ## (the prompt prefix must stay stable so providers reuse it). Falls back
  ## to the minimal baked-in prompt when the component is absent, slow, or
  ## broken — core never hard-depends on a component for boot. Truncates
  ## absurd answers so a runaway generated constitution cannot poison the
  ## context window.
  # Quick probe first: an absent component costs 500ms, not the full
  # timeout. Only when the catalog says the component IS registered do we
  # grant the full budget (covers a boot race or a slow first call).
  let promptCwd = if cwd.len > 0: cwd else: ct.root
  result = askSystemPrompt(ct, 500, sessionId, promptCwd)
  if result.len == 0 and ct.cat.components.hasKey("systemprompt"):
    result = askSystemPrompt(ct, systemPromptTimeoutMs, sessionId, promptCwd)
  if result.len > 200_000:
    result = result[0 ..< 200_000] &
      "\n\n[system prompt truncated at 200000 bytes]\n"
  if result.len == 0:
    echo "core: systemprompt component not answering — using minimal fallback prompt"
    result = systemPrompt(ct.root)

proc formatToolsForLlm(tools: JsonNode): JsonNode =
  result = newJArray()
  for t in tools:
    # the catalog already normalized schemas at registration
    let schema = t{"schema"}
    var description = schema{"description"}.getStr(t{"name"}.getStr())
    # Read-only tools (x-harness.effect = "read") get an explicit batch
    # hint so models group them without waiting on a per-call prompt rule.
    # Inert until a component tags its tools; default is "write".
    if schema{"x-harness"}{"effect"}.getStr("") == "read":
      description &= " — batches safely with other read-only calls"
    # The LLM gets a pure JSON Schema: strip harness-only extensions so
    # approval/timeout/effect metadata never weighs the prompt (the
    # catalog keeps the full schema for gates and validation).
    var parameters = newJObject()
    for key, value in schema:
      if key != "x-harness":
        parameters[key] = value
    result.add(%*{
      "type": "function",
      "function": {
        "name": t{"name"},
        "description": description,
        "parameters": parameters
      }
    })

type
  Persister* = object
    ct: CoreTools
    convId*: string
    seqNo*: int
    promptTokens*: int   ## model-reported prompt tokens of the last chat request
    contextUsed*: int    ## best post-response occupancy (total tokens when available)
    ctxSize*: int        ## effective model context window
    ctxWarned*: bool     ## warned once per session until the next trim
    ## A3 cache economics: cumulative prompt tokens across the conversation,
    ## split by what the provider served from its prompt cache. The miss
    ## ratio (cacheMiss / cachePrompt) is the measurable waste signal —
    ## a healthy session stays well under 50% after the first turns.
    cachePrompt*: int    ## Σ prompt_tokens over responses reporting usage
    cacheRead*: int      ## Σ cached_tokens (provider-served prefix hits)
    failing: bool

  ToolExposure* = object
    direct*: JsonNode
    discovered*: JsonNode
    initializedAt*: float
    rev*: int

  Session* = object
    messages*: seq[JsonNode]
    persister*: Persister
    workspace*: string       ## absolute, immutable after conversation creation
    modelOverride*: string
    thinkingEffort*: string  ## "" (provider default) | low | medium | high | max
    allowlist*: seq[string]  ## frozen tool allowlist (empty = unrestricted)
    maxRounds*: int          ## per-turn tool-round budget (0 = default 20)
    maxCalls*: int           ## per-turn total tool-dispatch budget (0 = unlimited)
    maxTokens*: int          ## per-turn cumulative token budget (0 = unlimited)
    exposure*: ToolExposure

proc newPersister*(ct: CoreTools): Persister =
  ## Create a conversation header in the store and a persister for it.
  result = Persister(ct: ct, convId: "conv-" & newId())
  try:
    discard ct.storePutRev("conversation", result.convId,
      %*{"createdAt": epochTime(),
         "model": getEnv("NIF_OPENAI_MODEL", ""),
         "modelOverride": "", "title": ""})
  except CatchableError:
    discard

proc persistMsg*(p: var Persister, value: JsonNode,
                 telemetry: JsonNode = nil) =
  ## Persist one message; warn once on failure and once on recovery.
  ## Ids are zero-padded so store key order == message order. Storage-only
  ## telemetry is copied onto the persisted value, never into LLM history.
  inc p.seqNo
  let stored = value.copy()
  stored["conversationId"] = %p.convId
  stored["createdAt"] = %epochTime()
  if telemetry != nil and telemetry.kind == JObject:
    for key, fieldValue in telemetry:
      stored[key] = fieldValue
  try:
    discard p.ct.storePutRev("message",
      p.convId & ":" & align($p.seqNo, 6, '0'), stored)
    if p.failing:
      p.failing = false
      echo "core: store reachable again — persistence resumed"
  except CatchableError as e:
    if not p.failing:
      p.failing = true
      echo "core: WARNING persistence down (messages not saved): " & e.msg

proc loadStoredMessages*(ct: CoreTools, convId: string,
                         promptTokens: var int, contextUsed: var int,
                         ctxSize: var int): seq[JsonNode] =
  ## Rebuild a conversation's message list from the store (resume).
  ## Token/context fields are filled from the last assistant message's
  ## persisted usage so the context meter and guard survive restarts.
  result = @[]
  try:
    # 1000 = the store's list cap: resume must see the full transcript,
    # not the list tool's default 100 (fixed here; was truncating resumes)
    for item in ct.storeListItems("message", convId & ":", 1000):
      let v = item{"value"}
      # Turn errors are audit records, not provider message roles.
      if v{"role"}.getStr("") == "error": continue
      var msg = newJObject()
      msg["role"] = v{"role"}
      msg["content"] = v{"content"}
      for field in ["tool_call_id", "name", "tool_calls", "reasoning"]:
        if v{field} != nil:
          msg[field] = v{field}
      result.add(msg)
      if v{"role"}.getStr("") == "assistant":
        if v{"usage"}{"prompt_tokens"} != nil:
          promptTokens = v{"usage"}{"prompt_tokens"}.getInt(0)
        let total = v{"usage"}{"total_tokens"}.getInt(0)
        let completion = v{"usage"}{"completion_tokens"}.getInt(0)
        if total > 0:
          contextUsed = total
        elif promptTokens > 0:
          contextUsed = promptTokens + completion
        if v{"context"} != nil:
          ctxSize = v{"context"}.getInt(0)
  except CatchableError:
    discard

proc ensureConversationHeader*(ct: CoreTools, convId: string) =
  ## Make sure a conversation header doc exists in the store, creating it
  ## only if missing (idempotent — never clobbers an existing createdAt, so
  ## the sidebar ordering stays stable). Called at runner spawn and on the
  ## first message, so a session shows up as soon as it becomes live.
  try:
    if ct.storeGetItem("conversation", convId).value != nil:
      return  # already present — preserve its createdAt
    discard ct.storePutRev("conversation", convId,
      %*{"createdAt": epochTime(),
         "model": getEnv("NIF_OPENAI_MODEL", ""),
         "modelOverride": "", "title": ""})
  except CatchableError:
    discard

proc loadConversationHeader(ct: CoreTools, convId: string): JsonNode =
  ## Return a mutable conversation header, or an empty header when store is
  ## unavailable. Callers preserve unrelated fields such as the UI title.
  result = newJObject()
  try:
    let value = ct.storeGetItem("conversation", convId).value
    if value != nil and value.kind == JObject:
      result = value
  except CatchableError:
    discard

proc updateConversationHeader(ct: CoreTools, convId: string, fields: JsonNode) =
  ## Merge runtime/session metadata into the header without clobbering title
  ## or creation time. Persistence remains best-effort like message storage.
  try:
    var value = loadConversationHeader(ct, convId)
    if value{"createdAt"} == nil:
      value["createdAt"] = %epochTime()
    if value{"title"} == nil:
      value["title"] = %""
    for key, fieldValue in fields:
      value[key] = fieldValue
    discard ct.storePutRev("conversation", convId, value)
  except CatchableError as e:
    echo "core: WARNING conversation metadata persistence failed: " & e.msg

proc persistConversationRuntime(p: Persister, modelOverride, provider,
                                model: string) =
  var fields = %*{
    "modelOverride": modelOverride,
    "provider": provider,
    "model": model,
    "context": p.ctxSize,
    "contextUsed": p.contextUsed,
    "promptTokens": p.promptTokens,
    "cachePrompt": p.cachePrompt,
    "cacheRead": p.cacheRead
  }
  if p.cachePrompt > 0:
    fields["cacheHitRate"] = %round(float(p.cacheRead) * 100.0 /
                                     float(p.cachePrompt), 1)
  p.ct.updateConversationHeader(p.convId, fields)

proc directToolSnapshot(ct: CoreTools): JsonNode =
  result = newJArray()
  for tool in ct.cat.promptTools():
    let name = tool{"name"}.getStr("")
    result.add(%*{"component": ct.cat.toolIndex.getOrDefault(name),
                  "name": name, "schema": tool{"schema"}})

proc exposureValue(exposure: ToolExposure): JsonNode =
  %*{"version": 1, "direct": exposure.direct,
     "discovered": exposure.discovered,
     "initializedAt": exposure.initializedAt,
     "updatedAt": epochTime()}

proc saveToolExposure(ct: CoreTools, sessionId: string,
                      exposure: var ToolExposure) =
  try:
    # a lost optimistic-concurrency race raises and keeps the old rev —
    # same outcome as the previous ok-flag check, now explicit
    exposure.rev = ct.storePutRev("session", sessionId & ":tools",
      exposureValue(exposure), expectRev = exposure.rev)
  except CatchableError:
    discard

proc loadToolExposure*(ct: CoreTools, sessionId: string): ToolExposure =
  ## Load the immutable direct tool snapshot and durable discovery summary.
  try:
    let (value, rev) = ct.storeGetItem("session", sessionId & ":tools")
    if value != nil and value{"version"}.getInt(0) == 1 and
        value{"direct"} != nil and value{"direct"}.kind == JArray:
      result.direct = value{"direct"}
      result.discovered = value{"discovered"}
      if result.discovered == nil or result.discovered.kind != JArray:
        result.discovered = newJArray()
      result.initializedAt = value{"initializedAt"}.getFloat(epochTime())
      result.rev = rev
      return
  except CatchableError:
    discard

  result = ToolExposure(direct: directToolSnapshot(ct),
                        discovered: newJArray(),
                        initializedAt: epochTime())
  saveToolExposure(ct, sessionId, result)

proc promptTools(exposure: ToolExposure): JsonNode =
  result = newJArray()
  for tool in exposure.direct:
    result.add(%*{"name": tool{"name"}, "schema": tool{"schema"}})

proc recordDiscovery(ct: CoreTools, sessionId: string,
                     exposure: var ToolExposure, response: JsonNode) =
  let component = response{"component"}.getStr("")
  let tools = response{"tools"}
  if component.len == 0 or tools == nil or tools.kind != JArray:
    return
  var changed = false
  for tool in tools:
    let name = tool{"name"}.getStr("")
    if name.len == 0:
      continue
    var known = false
    for item in exposure.discovered:
      if item{"component"}.getStr("") == component and
          item{"name"}.getStr("") == name:
        known = true
        break
    if not known:
      exposure.discovered.add(%*{"component": component, "name": name})
      changed = true
  if not changed:
    return

  var refs: seq[JsonNode] = @[]
  for item in exposure.discovered:
    refs.add(item)
  refs.sort(proc(a, b: JsonNode): int =
    let byComponent = cmp(a{"component"}.getStr(""),
                          b{"component"}.getStr(""))
    if byComponent != 0: byComponent
    else: cmp(a{"name"}.getStr(""), b{"name"}.getStr("")))
  exposure.discovered = newJArray()
  for item in refs:
    exposure.discovered.add(item)
  saveToolExposure(ct, sessionId, exposure)

# ---------------------------------------------------------------------------
# Context window — trivial warning + trim
# ---------------------------------------------------------------------------

const
  ctxWarnRatio = 0.75  ## warn once when this fraction of the window is used
  ctxTrimRatio = 0.9   ## trim whole turns from the front at this fraction
  minKeepTurns = 2     ## never trim below this many user turns
  ctxOutputReserve = 16_384  ## tokens held back for the model's next reply
                             ## (pi compacts at window − reserve); env
                             ## NIF_CTX_RESERVE overrides, 0 disables

proc outputReserve*(): int =
  ## Tokens held back for the model's next reply (NIF_CTX_RESERVE override,
  ## 0 disables). Exported for tests.
  let v = getEnv("NIF_CTX_RESERVE", "").strip()
  if v.len == 0: return ctxOutputReserve
  try:
    let n = parseInt(v)
    return max(n, 0)
  except CatchableError:
    return ctxOutputReserve

proc estimateTokens*(messages: seq[JsonNode]): int =
  ## Rough token proxy used until the model reports real usage (chars/4).
  ## Counts everything the next request will carry: text content, reasoning,
  ## tool-call arguments, and tool-call ids/names — not just `content` —
  ## so a thinking- or tool-heavy conversation is not badly underestimated.
  const overheadPerMessage = 8  ## role/formatting tokens, conservatively
  for m in messages:
    inc result, overheadPerMessage
    result += m{"content"}.getStr("").len div 4
    result += m{"reasoning"}.getStr("").len div 4
    let toolCalls = m{"tool_calls"}
    if toolCalls != nil:  # iterating a nil JArray SIGSEGVs (json.nim trap)
      for tc in toolCalls:
        result += tc{"function"}{"name"}.getStr("").len div 4
        result += tc{"function"}{"arguments"}.getStr("").len div 4 + 4

proc trimThreshold*(p: Persister): int =
  ## The usage level that triggers trimming: the ratio bound, minus an
  ## output reserve so the model's next reply still fits after compaction
  ## (pi compacts at window − reserveTokens rather than a bare ratio).
  let ratioBound = int(p.ctxSize.float * ctxTrimRatio)
  # window − reserve, but never below half the window: a tiny context
  # (window < reserve) would otherwise go negative and never trim
  let reserved = max(p.ctxSize - outputReserve(), p.ctxSize div 2)
  return min(ratioBound, reserved)

proc trimContext*(messages: var seq[JsonNode]): int =
  ## Drop whole turns from the front, keeping the system prompt. A turn is
  ## one user message plus everything up to the next user message (assistant
  ## text, tool calls, tool results) — whole-turn drops keep tool_call_id
  ## pairs intact. Returns the number of dropped messages.
  result = 0
  while messages.len > 2:
    var turns = 0
    for m in messages:
      if m{"role"}.getStr("") == "user": inc turns
    if turns <= minKeepTurns: break
    # find the second user message; drop everything before it
    var second = -1
    var seen = 0
    for i in 1 ..< messages.len:
      if messages[i]{"role"}.getStr("") == "user":
        inc seen
        if seen == 2:
          second = i
          break
    if second < 0: break
    inc result, second - 1
    messages.delete(1 .. second - 1)

proc checkContext*(p: var Persister, messages: var seq[JsonNode],
                   onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
                   turnId = "") =
  ## Called before each chat request: warn once at ctxWarnRatio, trim whole
  ## turns at ctxTrimRatio. Token accounting comes from the model's own
  ## usage (persisted with assistant messages, restored on resume); before
  ## the first response a chars/4 estimate stands in.
  if p.ctxSize <= 0: return
  let used =
    if p.contextUsed > 0: p.contextUsed
    elif p.promptTokens > 0: p.promptTokens
    else: estimateTokens(messages)
  let pct = int(used.float * 100.0 / p.ctxSize.float)
  let trimAt = trimThreshold(p)
  if used >= trimAt:
    let dropped = trimContext(messages)
    if dropped > 0:
      messages.insert(%*{"role": "system", "content":
        "[context trimmed: dropped " & $dropped &
        " earlier messages to fit the model window]"}, 1)
      p.ctxWarned = false
      echo "core: context at " & $pct & "% — trimmed " & $dropped &
           " messages (trim level " & $trimAt & ")"
      if onEvent != nil:
        onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                              "promptTokens": p.promptTokens,
                              "usedTokens": used, "context": p.ctxSize,
                              "trimAt": trimAt,
                              "reserveTokens": outputReserve(),
                              "trimmed": dropped,
                              "reason": "reset:trim",
                              "note": "history reset — the next request rebuilds the provider prompt cache from the remaining prefix"})
  elif pct >= int(ctxWarnRatio * 100) and not p.ctxWarned:
    p.ctxWarned = true
    echo "core: WARNING context at " & $pct & "% — will trim at " &
         $(int(ctxTrimRatio * 100)) & "%"
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "promptTokens": p.promptTokens,
                            "usedTokens": used, "context": p.ctxSize,
                            "warning": true,
                            "reason": "warn:threshold"})

proc startTokenStream*(ct: CoreTools, sessionId: string,
                       cb: proc(sid, content, reasoning: string) {.closure.}) =
  ## Begin forwarding live ev.llm.token deltas for `sessionId` to `cb`. The
  ## subscription is pumped from dispatch's blocking wait, so no thread is
  ## needed. Call stopTokenStream in a finally when the turn ends.
  if ct.tokenStream == nil: return
  if ct.tokenStream.sub != nil:
    natsSubscription_Destroy(ct.tokenStream.sub)
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, ct.nc.conn,
                                                  "ev.llm.token".cstring)):
    ct.tokenStream.sub = nil
    return
  ct.tokenStream.sub = sub
  ct.tokenStream.session = sessionId
  ct.tokenStream.cb = cb

proc stopTokenStream*(ct: CoreTools) =
  if ct.tokenStream == nil: return
  if ct.tokenStream.sub != nil:
    # The last token frame races the chat reply (different NATS subjects,
    # no cross-subject ordering) — drain whatever already arrived before
    # tearing the subscription down. Anything still on the wire is healed
    # by the final assistant event carrying the complete content.
    pumpTokenStream(ct)
    natsSubscription_Destroy(ct.tokenStream.sub)
    ct.tokenStream.sub = nil
  ct.tokenStream.session = ""
  ct.tokenStream.cb = nil

proc resolveTurnConfig(ct: CoreTools, p: var Persister,
                       modelOverride: string): JsonNode =
  ## Resolve the backend once for a turn or an interactive model selection.
  var resolveArgs = newJObject()
  if modelOverride.len > 0:
    resolveArgs["model"] = %modelOverride
  let resolved = ct.dispatchToolCall("llm_resolve", resolveArgs, 10_000)
  let selectedModel = resolved{"model"}.getStr(modelOverride)
  let resolvedContext = resolved{"context"}.getInt(0)
  if resolvedContext > 0 and resolvedContext != p.ctxSize:
    p.ctxSize = resolvedContext
    p.ctxWarned = false
  result = %*{
    "sessionId": p.convId,
    "provider": resolved{"provider"}.getStr(""),
    "providerSource": resolved{"providerSource"}.getStr(""),
    "model": selectedModel,
    "catalog": resolved{"catalog"}.getStr(""),
    "context": p.ctxSize,
    "contextSource": resolved{"contextSource"}.getStr(""),
    "promptTokens": p.promptTokens,
    "usedTokens": p.contextUsed
  }

proc drainSteer(ct: CoreTools, p: var Persister, messages: var seq[JsonNode],
              onEvent: proc(kind: string, data: JsonNode) {.closure.},
              turnId = ""): int =
  ## Pop any steering messages queued by pumpSteer (client typed mid-turn) and
  ## append each as a user message into the running conversation. Returns how
  ## many were folded in; runTurn uses >0 to keep the turn alive on early stop.
  if ct.steerStream == nil: return 0
  let sessionId = p.convId
  for steered in ct.steerStream.queue:
    let steerMsg = %*{"role": "user", "content": "Steer: " & steered}
    messages.add(steerMsg)
    p.persistMsg(steerMsg)
    if onEvent != nil:
      onEvent("steer", %*{"sessionId": sessionId, "turnId": turnId,
                          "content": steered})
    result += 1
  ct.steerStream.queue.setLen(0)

proc drainAdvisories(ct: CoreTools, p: var Persister,
                     messages: var seq[JsonNode],
                     onEvent: proc(kind: string, data: JsonNode) {.closure.},
                     turnId = ""): int =
  ## Pop accepted advisor payloads queued by pumpAdvise (the expert peer,
  ## docs/research/EXPERT.md) and append each as a distinctly marked user message into the
  ## running conversation. Like steer, folding keeps the turn alive on early
  ## stop; the "advice" event carries the structured provenance.
  if ct.adviseStream == nil: return 0
  let sessionId = p.convId
  for adv in ct.adviseStream.queue:
    let content = adv{"content"}.getStr("")
    if content.len == 0: continue
    let source = adv{"source"}.getStr("advisor")
    let advMsg = %*{"role": "user",
                    "content": "[Niffler advisor: " & source & "] " & content}
    messages.add(advMsg)
    p.persistMsg(advMsg)
    if onEvent != nil:
      onEvent("advice", %*{"sessionId": sessionId, "turnId": turnId,
                           "source": source, "content": content,
                           "reason": adv{"reason"}.getStr("")})
    result += 1
  ct.adviseStream.queue.setLen(0)

# A parsed tool call from an assistant message, ready for the wave scheduler.
# parseFailed calls were garbled/truncated at the source and are neutralized
# (never dispatched) — their history entry carries valid {} args for strict
# backends that re-validate assistant tool_calls on every request.
type
  ToolCallItem = tuple
    id, name: string
    args: JsonNode
    parseFailed: bool
    rawArgs: string

proc commitToolItem(ct: CoreTools, p: var Persister,
                    messages: var seq[JsonNode],
                    exposure: var ToolExposure,
                    onEvent: proc(kind: string, data: JsonNode) {.closure.},
                    sessionId, turnId: string,
                    it: ToolCallItem, oc: ToolCallOutcome,
                    toolStartedAt: float, toolDurationMs: int) =
  ## Shared post-processing for one executed tool call (serial or from a
  ## parallel wave): catalog pump, discovery recording, transcript append,
  ## persistence (with lifecycle telemetry), and the "done" toolcall event.
  ct.cat.pump()
  if ct.sup != nil:
    ct.sup.pump(ct.cat)
  if oc.ok and it.name == "discover":
    recordDiscovery(ct, sessionId, exposure, oc.value)
  ## LLM-facing projection (WIRE.md, "Tool results"): a result object with
  ## a string `text` field is rendered verbatim into the tool message —
  ## that is the whole diet; every other field stays machine-readable on
  ## the bus (fabric programs, tests, UIs) and never reaches the transcript.
  let content =
    if oc.ok:
      let t = oc.value{"text"}
      if t.isStr: t.getStr()
      else: jdump(oc.value)
    else:
      ""
  let toolMsg =
    if oc.ok:
      %*{"role": "tool", "tool_call_id": it.id, "name": it.name,
         "content": content}
    else:
      %*{"role": "tool", "tool_call_id": it.id, "name": it.name,
         "content": "ERROR: " & oc.error}
  messages.add(toolMsg)
  p.persistMsg(toolMsg,
    %*{"turnId": turnId, "startedAt": toolStartedAt,
       "durationMs": toolDurationMs})
  if onEvent != nil:
    if oc.ok:
      onEvent("toolcall", %*{"sessionId": sessionId, "turnId": turnId,
                             "callId": it.id, "phase": "done",
                             "tool": it.name, "args": it.args,
                             "result": oc.value,
                             "durationMs": toolDurationMs,
                             "at": epochTime()})
    else:
      onEvent("toolcall", %*{"sessionId": sessionId, "turnId": turnId,
                             "callId": it.id, "phase": "done",
                             "tool": it.name, "args": it.args,
                             "error": oc.error,
                             "durationMs": toolDurationMs,
                             "at": epochTime()})

proc runTurn*(ct: CoreTools, p: var Persister, messages: var seq[JsonNode],
              modelOverride: string,
              exposure: var ToolExposure,
              onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
              thinkingEffort = "", turnContent = "", workspace = "",
              maxRounds = 0, maxCalls = 0, maxTokens = 0,
              allowlist: seq[string] = @[],
              turnError: var string): string =
  ## One user turn: chat → dispatch tool calls → append results.
  ## Returns the final assistant text. onEvent receives
  ## ("turn", {sessionId, turnId, phase: start|done, content?, error?}),
  ## ("assistant", {sessionId, turnId, content}), ("toolcall", {sessionId,
  ## turnId, callId, phase, tool, args, result|error, errorCode?}),
  ## ("token", {sessionId, turnId, content, reasoning} live deltas),
  ## ("status", {...turnId...}), ("advice", {sessionId, turnId, source,
  ## content}) and ("done", {sessionId, turnId, reply}) as they happen.
  ## turnContent is the user request that started this turn (ev.session.turn).
  let sessionId = p.convId
  let turnId = "turn-" & newId()
  # Live turn identity for pumpAdvise: advisor requests are accepted only
  # while this turn is running and only for its turnId.
  if ct.activeTurn != nil:
    ct.activeTurn.session = sessionId
    ct.activeTurn.id = turnId
    ct.activeTurn.advisories = 0
  defer:
    if ct.activeTurn != nil:
      ct.activeTurn.session = ""
      ct.activeTurn.id = ""
  # Every exit path closes the turn event — including exceptions.
  var turnClosed = false
  proc emitTurnDone(err = "") =
    if onEvent != nil and not turnClosed:
      var ev = %*{"sessionId": sessionId, "turnId": turnId, "phase": "done"}
      if err.len > 0: ev["error"] = %err
      onEvent("turn", ev)
    turnClosed = true
  if onEvent != nil:
    onEvent("turn", %*{"sessionId": sessionId, "turnId": turnId,
                       "phase": "start", "content": turnContent})

  # Resolve once before the turn so the context guard sees the selected
  # model's effective window before inference. The resolved model is then
  # pinned across every tool round in this turn.
  var selectedModel = modelOverride
  var resolvedProvider = ""
  try:
    var status = resolveTurnConfig(ct, p, modelOverride)
    status["turnId"] = %turnId
    resolvedProvider = status{"provider"}.getStr("")
    selectedModel = status{"model"}.getStr(selectedModel)
    if onEvent != nil:
      onEvent("status", status)
  except CatchableError:
    discard  # older/replaced llm components can still serve chat

  # Tag approvals raised during this turn with the active session so the UI
  # can offer/apply per-conversation auto-approve. Cleared when the turn ends
  # so a direct (non-session) harness call reads as session "".
  if ct.approval != nil:
    ct.approval.session = sessionId
  defer:
    if ct.approval != nil: ct.approval.session = ""
  # Live lease for session-context tools (fabric, agent): dispatchToolCall
  # injects {session, lease} into their args and pumpNested validates nested
  # calls against it. A ref on CoreTools so the set survives by-value copies.
  # Cleared when the turn ends — a stale lease is worthless.
  if ct.nested != nil:
    ct.nested.session = sessionId
    ct.nested.workspace = workspace
    ct.nested.lease = ""
  defer:
    if ct.nested != nil:
      ct.nested.session = ""
      ct.nested.workspace = ""
      ct.nested.lease = ""
  defer:
    emitTurnDone("aborted")
  # Live LLM token stream: subscribe before the first chat call so no
  # delta is missed, and forward every frame to the caller as a "token"
  # event (the UI renders them as streaming text/thinking). The frames
  # are pumped from dispatch's blocking wait (pumpTokenStream), so no
  # thread is needed.
  startTokenStream(ct, sessionId, proc(sid, content, reasoning: string) {.closure.} =
    if onEvent != nil:
      onEvent("token", %*{"sessionId": sid, "turnId": turnId,
                          "content": content, "reasoning": reasoning}))
  defer: stopTokenStream(ct)
  # A control cancel that arrived while no turn ran is dropped here: only a
  # cancel published during THIS turn aborts it (agent_stop targets a live
  # child turn, never a future conversation turn).
  if ct.steerStream != nil:
    ct.steerStream.cancelRequested = false
  var rounds = 0
  var toolCallsMade = 0
    ## Dispatches this turn, across all rounds: a per-turn call budget is
    ## distinct from the round budget because one LLM round may emit several
    ## tool_calls.
  var turnTokens = 0
    ## Cumulative tokens this turn (total_tokens per round when the provider
    ## reports usage) — the per-job token budget checks this before each new
    ## LLM round, so overshoot is bounded by one round.
  # Effective round budget: a per-session maxRounds (subagent budgets,
  # 1-20) overrides the NIF_MAX_TURN_ROUNDS env default (default 20 —
  # bench lanes raise it so long agentic tasks are not cut off).
  let envMaxRounds =
    block:
      var v = 20
      try:
        v = parseInt(getEnv("NIF_MAX_TURN_ROUNDS", "20"))
      except ValueError:
        discard
      if v < 1: 20 else: v
  let effMaxRounds = if maxRounds > 0: maxRounds else: envMaxRounds
  while rounds < max(effMaxRounds, 1):
    rounds += 1
    # A cancel (agent_stop) ends the turn before the next LLM round: the
    # flag is raised by pumpSteer from dispatch's idle slots, including
    # while this loop was blocked inside a tool call. The in-flight LLM
    # request itself is aborted by the llm.cancel side-channel.
    if ct.steerStream != nil and ct.steerStream.cancelRequested:
      let msg = "cancelled by request"
      turnError = msg
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                           "error": msg})
      emitTurnDone(msg)
      return ""
    # Per-turn token budget (subagent jobs): once the cumulative usage of
    # the completed rounds reaches the cap, no further LLM round starts —
    # the turn ends as budget-exhausted instead of spending more tokens.
    if maxTokens > 0 and turnTokens >= maxTokens:
      let msg = "turn token budget exhausted (" & $turnTokens &
        " tokens; capped at " & $maxTokens & ")"
      turnError = msg
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                           "error": msg})
      emitTurnDone(msg)
      return ""
    checkContext(p, messages, onEvent, turnId)
    # Fold any steering messages the client injected mid-turn into the running
    # conversation before the next LLM call (Pi-style steering), plus any
    # accepted advisor messages (pumpAdvise).
    discard drainSteer(ct, p, messages, onEvent, turnId)
    discard drainAdvisories(ct, p, messages, onEvent, turnId)
    # A conversation's direct schemas are immutable. New live capabilities
    # enter append-only history through discover and are called via invoke.
    # An allowlisted conversation sees only its frozen tools in the prompt;
    # the dispatch gate (sessionAllowlist) enforces the same set.
    var promptToolsJson = exposure.promptTools()
    if allowlist.len > 0:
      var filtered = newJArray()
      for tool in promptToolsJson:
        if tool{"name"}.getStr("") in allowlist:
          filtered.add(tool)
      promptToolsJson = filtered
    let llmArgs = %*{"messages": messages,
                     "tools": promptToolsJson.formatToolsForLlm(),
                     "sessionId": sessionId,
                     "stream": true}
    if selectedModel.len > 0:
      llmArgs["model"] = %selectedModel
    if resolvedProvider.len > 0:
      llmArgs["provider"] = %resolvedProvider
    if thinkingEffort.len > 0:
      llmArgs["reasoning_effort"] = %thinkingEffort
    var resp: JsonNode
    let llmStartedAt = epochTime()
    let llmStarted = getMonoTime()
    var attempt = 0
    let retryPolicy = retryPolicyFromEnv()
    while true:
      try:
        resp = ct.dispatchToolCall("chat", llmArgs, 300000)
        break
      except CatchableError as e:
        # B3: auto-retry transient LLM failures (rate limits, provider
        # outages, dropped connections) with exponential backoff. Auth,
        # quota and bad-request failures fail fast — retrying cannot help.
        # A cancel that landed while the LLM request was in flight reads as
        # cancellation, not an LLM failure, and is never retryable. Each
        # retry is announced so UIs can show the wait.
        let cancelled = e of TurnCancelled
        if cancelled or attempt >= retryPolicy.maxRetries or
            not isRetryableLlmError(e.msg):
          let msg = if cancelled: "cancelled by request"
                    else: "llm error: " & e.msg
          let durationMs = (getMonoTime() - llmStarted).inMilliseconds
          p.persistMsg(%*{"role": "error", "content": msg,
                          "error": "llm", "turnId": turnId},
                       %*{"startedAt": llmStartedAt,
                          "durationMs": durationMs})
          turnError = msg
          if onEvent != nil:
            onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                               "error": msg})
          emitTurnDone(msg)
          return msg
        let delayMs = retryDelayMs(retryPolicy, attempt)
        if onEvent != nil:
          onEvent("retry", %*{"sessionId": sessionId, "turnId": turnId,
                             "attempt": attempt + 1,
                             "maxRetries": retryPolicy.maxRetries,
                             "delayMs": delayMs, "error": e.msg})
        sleep(delayMs)
        attempt += 1
    ct.cat.pump()
    if ct.sup != nil:
      ct.sup.pump(ct.cat)

    let content = resp{"content"}.getStr("")
    let reasoning = resp{"reasoning"}.getStr("")
    # Provider/model + token usage surfaced by the llm component.
    let usedProvider = resp{"provider"}.getStr(resolvedProvider)
    let usedModel = resp{"model"}.getStr(selectedModel)
    let ctxSize = resp{"context"}.getInt(0)
    let usage = resp{"usage"}
    var usageObj = newJObject()
    if usage != nil:
      for k in ["prompt_tokens", "completion_tokens", "total_tokens",
                "prompt_tokens_details"]:
        if usage{k} != nil:
          usageObj[k] = usage{k}
    # token accounting for the context check on the next round
    if usageObj{"prompt_tokens"} != nil:
      p.promptTokens = usageObj{"prompt_tokens"}.getInt(0)
      # A3 cache economics: accumulate the cache-read split when the
      # provider reports it (prompt_tokens_details.cached_tokens). A
      # request with a stable prefix should show most of its prompt served
      # from cache; a high miss ratio flags cache-hostile request churn.
      let cached = usageObj{"prompt_tokens_details"}{"cached_tokens"}
      if cached != nil and cached.kind == JInt:
        p.cachePrompt += p.promptTokens
        p.cacheRead += cached.getInt(0)
    let totalTokens = usageObj{"total_tokens"}.getInt(0)
    let completionTokens = usageObj{"completion_tokens"}.getInt(0)
    if totalTokens > 0:
      p.contextUsed = totalTokens
    elif p.promptTokens > 0:
      p.contextUsed = p.promptTokens + completionTokens
    if p.contextUsed > 0:
      turnTokens += p.contextUsed
    if ctxSize > 0:
      p.ctxSize = ctxSize
    p.persistConversationRuntime(modelOverride, usedProvider, usedModel)
    if onEvent != nil:
      var statusEv = %*{
        "sessionId": sessionId,
        "turnId": turnId,
        "provider": usedProvider,
        "model": usedModel,
        "context": p.ctxSize,
        "promptTokens": p.promptTokens,
        "usedTokens": p.contextUsed,
        "thinkingEffort": thinkingEffort
      }
      if usageObj.len > 0: statusEv["usage"] = usageObj
      # Cache economics (A3/CodeWhale borrow): the frozen prefix means most
      # prompt tokens should be cached after the first request; surface the
      # provider's cached split so a low hit ratio is visible and attributable
      # (ev.session.context carries the reset reason when we know one).
      if p.cachePrompt > 0:
        statusEv["cache"] = %*{"prompt": p.cachePrompt, "read": p.cacheRead,
                               "hitRate": round(float(p.cacheRead) * 100.0 /
                                                float(p.cachePrompt), 1)}
      onEvent("status", statusEv)
    let toolCalls = resp{"tool_calls"}
    let hasToolCalls = toolCalls != nil and toolCalls.kind == JArray and
                       toolCalls.len > 0
    if content.len > 0 or hasToolCalls:
      let assistantMsg = %*{"role": "assistant",
                            "content": (if content.len > 0: %content else: newJNull())}
      if reasoning.len > 0: assistantMsg["reasoning"] = %reasoning
      if hasToolCalls: assistantMsg["tool_calls"] = toolCalls
      if usedProvider.len > 0: assistantMsg["provider"] = %usedProvider
      if usedModel.len > 0: assistantMsg["model"] = %usedModel
      if ctxSize > 0: assistantMsg["context"] = %ctxSize
      if usageObj.len > 0: assistantMsg["usage"] = usageObj
      messages.add(assistantMsg)
      p.persistMsg(assistantMsg,
        %*{"turnId": turnId, "startedAt": llmStartedAt,
           "durationMs": (getMonoTime() - llmStarted).inMilliseconds})
      if content.len > 0 and onEvent != nil:
        var ev = %*{"sessionId": sessionId, "turnId": turnId,
                    "content": content}
        if reasoning.len > 0: ev["reasoning"] = %reasoning
        if usedProvider.len > 0: ev["provider"] = %usedProvider
        if usedModel.len > 0: ev["model"] = %usedModel
        if ctxSize > 0: ev["context"] = %ctxSize
        if usageObj.len > 0: ev["usage"] = usageObj
        onEvent("assistant", ev)

    if not hasToolCalls:
      # Honor a cancel that arrived while this final LLM round ran: the
      # turn is about to end anyway, but the caller asked for cancellation
      # — the record must say "stopped"/"cancelled", not "done".
      if ct.steerStream != nil and ct.steerStream.cancelRequested and
          epochTime() - ct.steerStream.cancelAt <= 30.0:
        let msg = "cancelled by request"
        turnError = msg
        ct.steerStream.cancelRequested = false
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": msg})
        emitTurnDone(msg)
        return ""
      # No tool calls: the model wants to stop. But if the client injected a
      # steering message while this response was in flight, fold it in and keep
      # going rather than ending the turn early (Pi's continuation-on-nudge).
      if drainSteer(ct, p, messages, onEvent, turnId) +
          drainAdvisories(ct, p, messages, onEvent, turnId) > 0:
        continue
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                           "reply": content})
      emitTurnDone()
      return content

    # --- Tool-call execution: parallel-safe calls (x-harness.parallel) fan
    # out over the bus; the rest (approval-gated, session-context, parse
    # failures, unmarked tools) run one at a time, in order. Results always
    # land in tool_calls order so strict backends keep call/result pairing.
    var items: seq[ToolCallItem] = @[]
    for tc in toolCalls:
      # Per-turn call budget (subagent jobs): stop BEFORE dispatching past
      # the cap, so a batch of tool_calls never overshoots it. The turn
      # ends as budget-exhausted; the transcript keeps everything up to
      # here so the caller can see exactly where the budget ran out.
      if maxCalls > 0 and toolCallsMade >= maxCalls:
        let msg = "turn tool-call budget exhausted (" & $maxCalls &
          " tool calls)"
        turnError = msg
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": msg})
        emitTurnDone(msg)
        return ""
      inc toolCallsMade  # every dispatch attempt counts, success or error
      let id = tc{"id"}.getStr("")
      let name = tc{"function"}{"name"}.getStr("")
      let rawArgs = tc{"function"}{"arguments"}.getStr("{}")
      var args = newJObject()
      var parseFailed = false
      try:
        args = parseJson(rawArgs)
      except CatchableError:
        # A truncated or garbled stream can leave tool-call arguments that
        # are not valid JSON. Neutralize the call in the persisted history
        # (strict backends re-validate assistant tool_calls on every
        # request and would 400 the whole turn) and tell the model what
        # happened instead of dispatching an empty args object.
        parseFailed = true
        tc{"function"}["arguments"] = %"{}"
      items.add((id: id, name: name, args: args,
                 parseFailed: parseFailed, rawArgs: rawArgs))
      if onEvent != nil:
        onEvent("toolcall", %*{"sessionId": sessionId, "turnId": turnId,
                               "callId": id, "phase": "start",
                               "tool": name, "args": args,
                               "at": epochTime()})

    var idx = 0
    while idx < items.len:
      # A wave is a maximal run of consecutive parallel-safe calls. Waves fan
      # out; serial calls (or a parse failure) run alone, in order.
      var wave: seq[tuple[id, name: string, args: JsonNode]] = @[]
      while idx < items.len and isParallelSafeTool(ct, items[idx].name) and
          not items[idx].parseFailed:
        wave.add((items[idx].id, items[idx].name, items[idx].args))
        inc idx
      if wave.len > 0:
        let waveStartedAt = epochTime()
        let waveStarted = getMonoTime()
        var calls: seq[tuple[tool: string, args: JsonNode]] = @[]
        for w in wave: calls.add((w.name, w.args))
        var outcomes: seq[ToolCallOutcome] = @[]
        try:
          outcomes = ct.dispatchToolCalls(calls)
        except CatchableError as e:
          for w in wave:
            outcomes.add(ToolCallOutcome(error: e.msg))
        let waveDurationMs = (getMonoTime() - waveStarted).inMilliseconds
        for k, w in wave:
          commitToolItem(ct, p, messages, exposure, onEvent, sessionId,
                         turnId,
                         (id: w.id, name: w.name, args: w.args,
                          parseFailed: false, rawArgs: ""),
                         (if k < outcomes.len: outcomes[k]
                          else: ToolCallOutcome(error: "no outcome")),
                         waveStartedAt, waveDurationMs)
        continue
      let it = items[idx]
      inc idx
      let toolStartedAt = epochTime()
      let toolStarted = getMonoTime()
      var oc: ToolCallOutcome
      if it.parseFailed:
        oc = ToolCallOutcome(error:
          "tool call arguments were not valid JSON (truncated or garbled stream): " &
          it.rawArgs[0 ..< min(it.rawArgs.len, 200)])
      else:
        try:
          oc = ToolCallOutcome(ok: true,
                               value: ct.dispatchToolCall(it.name, it.args))
        except CatchableError as e:
          oc = ToolCallOutcome(error: e.msg)
      let toolDurationMs = (getMonoTime() - toolStarted).inMilliseconds
      commitToolItem(ct, p, messages, exposure, onEvent, sessionId, turnId,
                     it, oc, toolStartedAt, toolDurationMs)

  # The only way out of the round loop without a return is the round budget:
  # end the turn loudly. A silent empty reply here reads exactly like a hang
  # — the transcript just stops after the last tool result with no trace of
  # why (two long authoring turns ended this way and were misdiagnosed as
  # session-runner deadlocks). Same shape as the token/call budget endings,
  # plus a persisted error so the model sees the cutoff on the next turn.
  let msg = "turn round budget exhausted (" & $effMaxRounds &
            " LLM rounds) — send a follow-up message to continue" &
            (if maxRounds > 0: "" else: "; raise NIF_MAX_TURN_ROUNDS for longer turns")
  turnError = msg
  p.persistMsg(%*{"role": "error", "content": msg, "error": "rounds",
                 "turnId": turnId},
               %*{"rounds": rounds})
  if onEvent != nil:
    onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                       "error": msg})
  emitTurnDone(msg)
  return msg

# ---------------------------------------------------------------------------
# Session service — core as a component for UIs (svc.core.call, tool "session")
# ---------------------------------------------------------------------------

proc shortTitle(s: string, max = 48): string =
  ## Rune-safe trim to `max` characters with an ellipsis when cut — used for
  ## conversation titles (session lists render them in a fixed-width column).
  let runes = s.toRunes()
  if runes.len <= max: return s
  $runes[0 ..< max] & "…"

proc deriveTitle(content: string): string =
  ## Auto-title for a fresh conversation: the first non-blank line of the
  ## first user message (a session {title} rename always wins over it).
  for line in content.splitLines():
    let s = line.strip()
    if s.len > 0:
      return shortTitle(s)
  ""

proc resolveWorkspace(root, requested: string): tuple[ok: bool, path, error: string] =
  ## A conversation workspace is immutable and confined to NIF_ROOT. Keeping
  ## it in the header makes resumed runners resolve context and paths exactly
  ## as the original turn did.
  if requested.strip().len == 0:
    return (true, root, "")
  let candidate = normalizedPath(
    if requested.isAbsolute(): requested else: root / requested)
  let cleanRoot = normalizedPath(root)
  if candidate != cleanRoot and not candidate.startsWith(cleanRoot & DirSep):
    return (false, "", "cwd must stay inside the harness root")
  if not dirExists(candidate):
    return (false, "", "cwd is not a directory: " & requested)
  (true, candidate, "")

proc handleSessionCall*(ct: CoreTools, args: JsonNode,
                         sessions: var Table[string, Session],
                         caller = ""): JsonNode =
  ## session {sessionId, content?, model?}: run one turn or persist a model
  ## selection, emitting ev.session.* events. Session state is rebuilt from
  ## the store on first use (resume). caller is the self-declared component
  ## name from the call envelope — the interactive component driving this
  ## session; approvals raised by the turn are routed to it.
  let sessionId = args{"sessionId"}.getStr("")
  let content = args{"content"}.getStr("")
  let hasModel = args.kind == JObject and args.hasKey("model")
  let hasThinking = args.kind == JObject and args.hasKey("thinking")
  let hasTitle = args.kind == JObject and args.hasKey("title")
  let hasCwd = args.kind == JObject and args.hasKey("cwd")
  if sessionId.len == 0 or
      (content.len == 0 and not hasModel and not hasThinking and not hasTitle and
       not hasCwd):
    return %*{"error": "session needs sessionId and content, model, thinking, title or cwd"}

  var entry: Session
  if sessions.hasKey(sessionId):
    entry = sessions[sessionId]
    if hasCwd:
      let requested = resolveWorkspace(ct.root, args{"cwd"}.getStr(""))
      if not requested.ok: return %*{"error": requested.error}
      if requested.path != entry.workspace:
        return %*{"error": "conversation cwd is immutable (currently " &
                              entry.workspace & ")"}
  else:
    # The runner normally creates this at startup; keep the call idempotent
    # for direct/unit paths and load the persisted model selection from it.
    ensureConversationHeader(ct, sessionId)
    let header = loadConversationHeader(ct, sessionId)
    # The conversation's constitution, frozen at first turn: resolved once
    # from the systemprompt component (or taken from the caller's prefetch,
    # e.g. the agent component's subagent children) and persisted in the
    # header. Resumes — in this or a later runner process — reuse the stored
    # value verbatim: the prompt prefix must stay stable so providers reuse
    # it, and a component that dies or changes mid-conversation must not
    # rewrite a running conversation's instructions.
    let requestedCwd = if header{"cwd"}.getStr("").len > 0:
                         header{"cwd"}.getStr("")
                       else: args{"cwd"}.getStr("")
    let workspace = resolveWorkspace(ct.root, requestedCwd)
    if not workspace.ok: return %*{"error": workspace.error}
    entry.workspace = workspace.path
    var sp = header{"systemPrompt"}.getStr("")
    if sp.len == 0:
      sp = args{"systemPrompt"}.getStr("")
    if sp.len == 0:
      sp = resolveSystemPrompt(ct, sessionId, entry.workspace)
    try:
      ct.updateConversationHeader(sessionId,
        %*{"systemPrompt": sp, "cwd": entry.workspace})
    except CatchableError as e:
      echo "core: WARNING cannot persist system prompt (store down?): " & e.msg
    entry.messages = @[%*{"role": "system", "content": sp}]
    entry.modelOverride = header{"modelOverride"}.getStr("")
    entry.thinkingEffort = header{"thinkingEffort"}.getStr("")
    # Frozen per-session controls (subagent scoping): the header carries
    # them across runner resumes; the first session call's args win while
    # the header is unset. The allowlist is enforced at the dispatch gate
    # (ct.sessionAllowlist), the round budget at runTurn's loop bound.
    let headerAllow = header{"toolAllowlist"}
    if headerAllow != nil:
      for t in headerAllow:
        if t.getStr("").len > 0: entry.allowlist.add(t.getStr(""))
    entry.maxRounds = header{"maxRounds"}.getInt(0)
    entry.maxCalls = header{"maxCalls"}.getInt(0)
    entry.maxTokens = header{"maxTokens"}.getInt(0)
    if args.kind == JObject and args.hasKey("tools") and
        args{"tools"}.kind == JArray and entry.allowlist.len == 0:
      for t in args{"tools"}:
        let name = t.getStr("")
        if name.len > 0 and entry.allowlist.len < 32:
          entry.allowlist.add(name)
      if entry.allowlist.len > 0:
        var arr = newJArray()
        for name in entry.allowlist: arr.add(%name)
        ct.updateConversationHeader(sessionId, %*{"toolAllowlist": arr})
    if args.kind == JObject and args.hasKey("maxRounds") and
        entry.maxRounds == 0:
      let mr = args{"maxRounds"}.getInt(0)
      if mr >= 1 and mr <= 20:
        entry.maxRounds = mr
        ct.updateConversationHeader(sessionId, %*{"maxRounds": %mr})
    # Per-job budgets (subagent scoping), frozen the same way: first call
    # wins while the header is unset, then the header carries them across
    # runner resumes.
    if args.kind == JObject and args.hasKey("maxCalls") and
        entry.maxCalls == 0:
      let mc = args{"maxCalls"}.getInt(0)
      if mc >= 1 and mc <= 500:
        entry.maxCalls = mc
        ct.updateConversationHeader(sessionId, %*{"maxCalls": %mc})
    if args.kind == JObject and args.hasKey("maxTokens") and
        entry.maxTokens == 0:
      let mt = args{"maxTokens"}.getInt(0)
      if mt >= 1:
        entry.maxTokens = mt
        ct.updateConversationHeader(sessionId, %*{"maxTokens": %mt})
    if entry.allowlist.len > 0:
      # the runner allocated the ref at startup; mutating through it makes
      # the frozen allowlist visible to every dispatch on this session
      ct.sessionAllowlist[] = entry.allowlist
    var pt = 0
    var used = 0
    var cs = 0
    let stored = loadStoredMessages(ct, sessionId, pt, used, cs)
    for m in stored:
      entry.messages.add(m)
    # A2/A3: usage and cumulative cache counters persist in the header
    # (written by persistConversationRuntime), so the context meter and
    # cache metrics survive a runner restart.
    entry.persister = Persister(
      ct: ct, convId: sessionId, seqNo: stored.len,
      promptTokens: pt, contextUsed: used, ctxSize: cs,
      cachePrompt: header{"cachePrompt"}.getInt(0),
      cacheRead: header{"cacheRead"}.getInt(0))
    entry.exposure = loadToolExposure(ct, sessionId)

  # Presence of the key means "set/clear the override"; omission preserves
  # the conversation's previous selection.
  if args.kind == JObject and args.hasKey("model"):
    entry.modelOverride = args{"model"}.getStr("").strip()
    ct.updateConversationHeader(sessionId,
      %*{"modelOverride": entry.modelOverride})
  if args.kind == JObject and args.hasKey("thinking"):
    entry.thinkingEffort = args{"thinking"}.getStr("").strip()
    if entry.thinkingEffort notin ["", "low", "medium", "high", "max"]:
      return %*{"error": "thinking must be low, medium or high (empty clears)"}
    ct.updateConversationHeader(sessionId,
      %*{"thinkingEffort": entry.thinkingEffort})
  if hasTitle:
    var title = args{"title"}.getStr("").strip()
    if title.len > 0:
      ct.updateConversationHeader(sessionId, %*{"title": shortTitle(title)})

  proc onEvent(kind: string, data: JsonNode) {.closure.} =
    let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: data)
    ct.nc.publish("ev.session." & kind, env.encode())

  if content.len == 0:
    var status = %*{
      "sessionId": sessionId,
      "model": entry.modelOverride,
      "thinkingEffort": entry.thinkingEffort,
      "cwd": entry.workspace,
      "context": entry.persister.ctxSize,
      "promptTokens": entry.persister.promptTokens,
      "usedTokens": entry.persister.contextUsed
    }
    try:
      # overlay the resolved config onto the literal — do NOT reassign, or
      # session-local fields (sessionId, thinkingEffort, token counters) are lost
      let resolved = resolveTurnConfig(ct, entry.persister, entry.modelOverride)
      for key, fieldValue in resolved:
        status[key] = fieldValue
      entry.persister.persistConversationRuntime(
        entry.modelOverride, status{"provider"}.getStr(""),
        status{"model"}.getStr(entry.modelOverride))
    except CatchableError as e:
      status["warning"] = %e.msg
    onEvent("status", status)
    sessions[sessionId] = entry
    status["ok"] = %true
    status["modelOverride"] = %entry.modelOverride
    return status

  let userMsg = %*{"role": "user", "content": content}
  entry.messages.add(userMsg)
  entry.persister.persistMsg(userMsg)
  if entry.persister.seqNo == 1 and not hasTitle:
    # first message of a fresh conversation: title it from the message so
    # session lists are descriptive instead of conv-<epoch>. An explicit
    # title on the same call wins; a later rename always overwrites.
    let auto = deriveTitle(content)
    if auto.len > 0:
      ct.updateConversationHeader(sessionId, %*{"title": auto})

  # Tag approvals raised during this turn with the driving component so they
  # are routed to its private approval subject. Cleared when the turn ends.
  if ct.approval != nil:
    ct.approval.caller = caller
  defer:
    if ct.approval != nil: ct.approval.caller = ""

  var turnError = ""
  let reply = runTurn(ct, entry.persister, entry.messages,
                      entry.modelOverride, entry.exposure, onEvent,
                      entry.thinkingEffort, content, entry.workspace,
                      entry.maxRounds, entry.maxCalls, entry.maxTokens,
                      entry.allowlist, turnError)
  sessions[sessionId] = entry
  # turnError distinguishes "the turn failed" from "the model said this" so
  # drivers (agent_run) report child LLM failures as failures, not text.
  var sessionResult = %*{"ok": true, "sessionId": sessionId, "reply": reply,
                  "modelOverride": entry.modelOverride,
                  "thinkingEffort": entry.thinkingEffort,
                  "cwd": entry.workspace}
  if turnError.len > 0:
    sessionResult["turnError"] = %turnError
  return sessionResult

# ---------------------------------------------------------------------------
# Session runners — one process per conversation (system side: ensure/forward)
# ---------------------------------------------------------------------------

import ../sdk/subjects

proc sanitizeSessionId*(s: string): string =
  ## Session ids become a NATS subject token (svc.session.<id>.call) and a
  ## catalog component name; keep alnum/-/_ and replace everything else.
  subjects.sanitizeSessionId(s)

proc sessionSubject*(sessionId: string): string =
  "svc.session." & sanitizeSessionId(sessionId) & ".call"

func steerSubject*(sessionId: string): string =
  ## Fire-and-forget channel a client publishes to in order to inject a message
  ## (or a __cancel control message — agent_stop's turn abort; see pumpSteer).
  "svc.session." & sanitizeSessionId(sessionId) & ".steer"

func adviseSubject*(sessionId: string): string =
  ## Turn-bound advisory requests from the expert peer (docs/research/EXPERT.md): answered
  ## by the runner's pumpAdvise with {accepted, reason}; advice never leaks
  ## past the named turn.
  "svc.session." & sanitizeSessionId(sessionId) & ".advise"

func toolSubject*(sessionId: string): string =
  ## Nested-call proxy for session-context tools (fabric, agent): generated
  ## programs route every tool call here; the runner's pump validates the
  ## live lease and re-enters the one dispatch gate (see dispatch.nim).
  "svc.session." & sanitizeSessionId(sessionId) & ".tool"

proc ensureRunner*(ct: CoreTools, sessionId: string): string =
  ## Return the scoped call subject for `sessionId`, spawning its session
  ## runner (a supervised child, policy never) if it is not alive. The
  ## runner announces itself as component "session-<id>" with 0 tools —
  ## presence in the catalog is the readiness signal.
  let rname = runnerName(sessionId)
  if not ct.cat.components.hasKey(rname):
    var spawning = false
    for c in ct.sup.children:
      if c.name == rname: spawning = true
    if not spawning:
      let bin = ct.root / "var" / "bin" / "session"
      if not fileExists(bin):
        raise newException(IOError,
          "session runner binary missing: " & bin & " — run `make build`")
      discard ct.sup.addChild(rname, bin, rpNever)
      ct.sup.startChild(ct.sup.children[^1], @[sessionId])
  let deadline = epochTime() + 10
  while epochTime() < deadline:
    # Serve svc.core.call while waiting: the fresh runner seeds its catalog
    # via catalog {op: snapshot} and would deadlock us without this pump.
    # Also pump the supervisor: a runner that exited just before we looked
    # (idle retirement race) leaves a dead "spawning" entry until sup.pump
    # reaps it — without reaping, this wait would stare at a corpse for
    # 10s while nobody spawns the replacement.
    pumpCoreWhileBusy(ct)
    ct.cat.pump()
    if ct.sup != nil:
      ct.sup.pump(ct.cat)
      var spawning = false
      for c in ct.sup.children:
        if c.name == rname: spawning = true
      if not spawning and not ct.cat.components.hasKey(rname):
        # the entry was reaped mid-wait: spawn the replacement now
        let bin = ct.root / "var" / "bin" / "session"
        if fileExists(bin):
          discard ct.sup.addChild(rname, bin, rpNever)
          ct.sup.startChild(ct.sup.children[^1], @[sessionId])
    if ct.cat.components.hasKey(rname): break
    sleep(100)
  if not ct.cat.components.hasKey(rname):
    raise newException(IOError,
      "session runner for " & sessionId & " did not come up")
  sessionSubject(sessionId)

proc callSession*(ct: CoreTools, args: JsonNode, caller = ""): JsonNode =
  ## Service-mode path for the "session" tool: ensure the runner for this
  ## sessionId, forward the turn, return its result. Core tools and other
  ## svc.core.call traffic stay responsive during the wait
  ## (dispatchSubjectCall pumps them); concurrent session calls are stashed
  ## (pumpCoreWhileBusy) — turns never nest, but they must not be lost.
  ## caller is forwarded so the runner can route approvals to the driver.
  let sessionId = args{"sessionId"}.getStr("")
  if sessionId.len == 0:
    return %*{"error": "session needs sessionId"}
  let subject = ensureRunner(ct, sessionId)
  dispatchSubjectCall(ct, subject, "session", args, 1800_000, caller)

proc pumpCoreCalls*(ct: CoreTools, sub: ptr natsSubscription) =
  ## Serve pending svc.core.call messages (session/spawn/catalog).
  ## Session requests stashed while a forward was busy are drained first.
  ## Pop one at a time: callSession can pump and append to pending while
  ## we work, so a plain `for` over items would trip the seq-mutation assert.
  while ct.pending.items.len > 0:
    let pend = ct.pending.items[0]
    ct.pending.items.delete(0)
    var resp: Envelope
    try:
      let r = callSession(ct, pend.env.args, pend.env.caller)
      if r{"error"} != nil:
        raise newException(ValueError, r{"error"}.getStr("session error"))
      resp = resultEnvelope(pend.env.id, r)
    except CatchableError as e:
      resp = errorEnvelope(pend.env.id, "boom", e.msg)
    ct.nc.publish(pend.reply, resp.encode())
  ct.pending.items = @[]
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekCall or reply.len == 0: continue
    var resp: Envelope
    try:
      case env.tool
      of "session":
        let r = callSession(ct, env.args, env.caller)
        if r{"error"} != nil:
          raise newException(ValueError, r{"error"}.getStr("session error"))
        resp = resultEnvelope(env.id, r)
      of "spawn", "catalog", "kill", "remove", "status", "discover",
          "session_prepare", "session_info", "prompt_preview", "doctor",
          "conversation_delete":
        let r = ct.handleCoreTool(env.tool, env.args)
        if r{"error"} != nil:
          raise newException(ValueError, r{"error"}.getStr("core tool error"))
        resp = resultEnvelope(env.id, r)
      of "invoke":
        let r = ct.dispatchToolCall(env.tool, env.args)
        resp = resultEnvelope(env.id, r)
      else:
        resp = errorEnvelope(env.id, "no-tool",
          "core has no tool '" & env.tool & "'")
    except CatchableError as e:
      resp = errorEnvelope(env.id, "boom", e.msg)
    ct.nc.publish(reply, resp.encode())
