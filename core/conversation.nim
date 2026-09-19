## Conversation loop — the only "product logic" in the harness.
##
## Two drivers:
## - session runners (core/session.nim): one process per conversation,
##   serving svc.session.<sessionId>.call, emitting ev.session.<id>.* events
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
import checksums/sha2
import natsnim
import ../sdk/envelope
import ../sdk/niffler/jsonx
import catalog
import compaction
import dispatch
import approval
import supervisor
import retry

proc sanitizeSessionId*(s: string): string
  ## Forward declaration: the per-session event publisher (ev.session.<id>.*)
  ## above the definition site needs the sanitized subject token; the
  ## implementation (wrapping sdk/subjects) is further down.

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
    # The tool's top-level description is promoted to function.description
    # and stripped from parameters — leaving it in both serialized every
    # description twice (25% of the frozen toolset's wire size).
    let description = schema{"description"}.getStr(t{"name"}.getStr())
    # The LLM gets a pure JSON Schema: strip harness-only extensions so
    # approval/timeout/effect metadata never weighs the prompt (the
    # catalog keeps the full schema for gates and validation).
    var parameters = newJObject()
    for key, value in schema:
      if key != "x-harness" and key != "description":
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
  NodeSource* = enum
    ## What a context node stands in for (docs/research/COMPACTION.md §4.2).
    nsCanonical   ## a persisted store message; id = "<convId>:<6-digit seq>"
    nsCheckpoint  ## a rendered projection checkpoint; id = "<convId>#ck<gen>"
    nsNotice      ## an omission/prune notice; synthetic #omit id; its body
                  ## names the canonical ids it replaced
    nsSystem      ## the frozen system prompt — rebuilt from the conversation
                  ## header, never store-resolvable, never cut or covered

  CtxNode* = object
    ## One entry of the runner's context identity ledger, 1:1 with
    ## Session.messages: nodes[i] describes messages[i]. Cuts and coverage
    ## are expressed in these ids, never in array positions — positions
    ## shift when a checkpoint replaces a canonical range; ids do not.
    source*: NodeSource
    id*: string            ## store key when canonical; synthetic checkpoint/
                           ## notice ref; empty only for the system node
    canonicalSeq*: int     ## seq number when canonical (0 otherwise)
    projectionIndex*: int  ## index into Session.messages of the entry this node describes

  PruneRec* = object
    ## §5.2: a prune is a projection edit, never a canonical rewrite. The
    ## record feeds the projection record's `prunes` list (§6.2) once the
    ## projection exists; until then the ledger is in-memory and a restart
    ## simply reloads un-pruned canonical content (safe: admission
    ## re-prunes when the next request needs it).
    id*: string          ## canonical id of the pruned message
    bytesBefore*: int
    bytesAfter*: int

  Persister* = object
    ct: CoreTools
    convId*: string
    seqNo*: int
    promptTokens*: int   ## model-reported prompt tokens of the last chat request
    contextUsed*: int    ## best post-response occupancy (total tokens when available)
    ctxSize*: int        ## catalog model context window
    ctxOutput*: int      ## catalog model output cap (0 = unknown): what the
                         ## next request asks the provider to reserve. Held
                         ## back from the window by admission and trim because
                         ## providers count max_tokens against the window at
                         ## admission (deepseek declared 384000 over a
                         ## 736803-token prompt and overflowed its 1048576
                         ## limit while the prompt alone fit the 1000000
                         ## harness window)
    calib*: int          ## provider-vs-estimate calibration (tokens): each
                         ## successful response re-measures it as the
                         ## reported prompt_tokens minus the local chars/4
                         ## estimate of the same request, so admission and
                         ## trim measure what the provider counts, not what
                         ## chars/4 guesses (DeepSeek-class models pack
                         ## denser; the raw estimate lagged ~22k tokens on
                         ## a 524k window). Cleared on model change; seeded
                         ## from stored usage on resume; clamped to [0, ctxSize].
    calibModel*: string  ## model the offset was learned for
    trimThrough*: int    ## highest canonical seqNo dropped by a lossy trim
                         ## (the watermark the resume honors — §6.3)
    ctxWarned*: bool     ## warned once per session until the next trim
    ## A3 cache economics: cumulative prompt tokens across the conversation,
    ## split by what the provider served from its prompt cache. The miss
    ## ratio (cacheMiss / cachePrompt) is the measurable waste signal —
    ## a healthy session stays well under 50% after the first turns.
    cachePrompt*: int    ## Σ prompt_tokens over responses reporting usage
    cacheRead*: int      ## Σ cached_tokens (provider-served prefix hits)
    failing: bool
    ## Context identity (docs/research/COMPACTION.md §4.2): the node ledger
    ## is 1:1 with the projection (Session.messages) and canonicalHigh is
    ## the highest canonical seq represented in context — appends continue
    ## after it, and a projection's covered range never reaches past it.
    ## The persister owns both because it allocates the ids the ledger
    ## records. `generation` mirrors the durable projection record so each
    ## snapshot can bind itself to the projection it read (§4.2/§6.2).
    nodes*: seq[CtxNode]
    canonicalHigh*: int
    generation*: int
    prunes*: seq[PruneRec]

  ToolExposure* = object
    direct*: JsonNode
    discovered*: JsonNode
    initializedAt*: float
    rev*: int
    profile*: string          ## profile name this direct set was resolved from ("" = fundamental)
    profileMissing*: JsonNode ## selectors that resolved to nothing (unknown or hidden)

  Session* = object
    messages*: seq[JsonNode]
    persister*: Persister
    workspace*: string       ## absolute, immutable after conversation creation
    modelOverride*: string
    thinkingEffort*: string  ## "" (provider default) | low | medium | high | max
    allowlist*: seq[string]  ## frozen tool allowlist (empty = unrestricted)
    maxRounds*: int          ## per-turn tool-round budget (0 = env default)
    maxCalls*: int           ## per-turn total tool-dispatch budget (0 = unlimited)
    maxTokens*: int          ## per-turn cumulative token budget (0 = unlimited)
    approvalMode*: string    ## this conversation's gate mode (/approvals):
                             ## "" or "ask" gates every x-harness.approval
                             ## tool, "auto" grants them without asking
    limitRounds*: int        ## the human's SOFT turn limits (/limit): when one
    limitTokens*: int        ## is reached the turn ASKS whether it may keep
    limitSeconds*: int       ## going (0 = unset). The scoping budgets above
                             ## stay hard — a job cannot negotiate its budget
    exposure*: ToolExposure

const defaultMaxTurnRounds = 1000

proc configuredMaxTurnRounds(): int =
  ## Read the hard per-turn round ceiling shared by sessions and subagents.
  result = defaultMaxTurnRounds
  try:
    result = parseInt(getEnv("NIF_MAX_TURN_ROUNDS", $defaultMaxTurnRounds))
  except ValueError:
    discard
  if result < 1:
    result = defaultMaxTurnRounds

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
                 telemetry: JsonNode = nil): string {.discardable.} =
  ## Persist one message; warn once on failure and once on recovery.
  ## Ids are zero-padded so store key order == message order. Storage-only
  ## telemetry is copied onto the persisted value, never into LLM history.
  ## Returns the allocated store key — the canonical id callers record in
  ## the node ledger (ctxAppend). Best-effort: on a store failure the id is
  ## still consumed and returned, but the record will not be there on
  ## resume (same semantics as before; the ledger just records intent).
  inc p.seqNo
  result = p.convId & ":" & align($p.seqNo, 6, '0')
  let stored = value.copy()
  stored["conversationId"] = %p.convId
  stored["createdAt"] = %epochTime()
  if telemetry != nil and telemetry.kind == JObject:
    for key, fieldValue in telemetry:
      stored[key] = fieldValue
  try:
    discard p.ct.storePutRev("message", result, stored)
    if p.failing:
      p.failing = false
      echo "core: store reachable again — persistence resumed"
  except CatchableError as e:
    if not p.failing:
      p.failing = true
      echo "core: WARNING persistence down (messages not saved): " & e.msg

proc ctxAppend*(p: var Persister, messages: var seq[JsonNode],
                msg: JsonNode, telemetry: JsonNode = nil) =
  ## Grow the in-memory context — the one way (docs/research/COMPACTION.md
  ## §4.2). Persists the message, appends it to the projection, and records
  ## the node identity so the ledger stays 1:1 with the projection. Every
  ## append site must go through here; a bare messages.add is how the
  ## ledger and the projection drift apart.
  let key = p.persistMsg(msg, telemetry)
  messages.add(msg)
  p.nodes.add(CtxNode(source: nsCanonical, id: key,
                      canonicalSeq: p.seqNo, projectionIndex: messages.high))
  p.canonicalHigh = p.seqNo

proc writeContextReceipt*(p: var Persister, requestId, failureClass, outcome,
                          detail: string) =
  ## §6.5 request-scoped receipt (kind contextreceipt, id
  ## <convId>:<requestId>): written BEFORE the overflow-recovery attempt is
  ## spent, so a crash mid-recovery stays consumed on restart, and updated
  ## with the outcome. Best-effort: an unreachable store must not block the
  ## recovery itself — the transcript's error records are the second line.
  try:
    discard p.ct.storePutRev("contextreceipt", p.convId & ":" & requestId,
      %*{"requestId": requestId, "failureClass": failureClass,
         "outcome": outcome, "detail": detail,
         "generation": p.generation,
         "canonicalHigh": p.canonicalHigh, "at": epochTime()})
  except CatchableError as e:
    echo "core: WARNING context receipt not persisted: " & e.msg

proc ctxDigest*(nodes: openArray[CtxNode], messages: openArray[JsonNode],
                fromIdx, toIdxIncl: int): string =
  ## §4.2 digest: sha256 over the covered nodes' ids and per-message
  ## content hashes, "sha256:"-prefixed. The runner recomputes this and
  ## compares it to a compaction candidate's claim, which is what makes
  ## "the surface changed under you" detectable without keeping a second
  ## copy of the covered content. Checkpoint and notice nodes contribute
  ## their rendered message body (their id may be empty — the content
  ## hash still binds them).
  doAssert nodes.len == messages.len,
    "node ledger out of sync with the projection"
  doAssert fromIdx >= 0 and toIdxIncl < nodes.len and fromIdx <= toIdxIncl + 1,
    "digest range out of bounds"
  var st = initSha_256()
  for i in fromIdx .. toIdxIncl:
    var ch = initSha_256()
    ch.update($messages[i])
    st.update($nodes[i].source)
    st.update("\x1f")
    st.update(nodes[i].id)
    st.update("\x1f")
    st.update($ch.digest())
    st.update("\x1e")
  result = "sha256:" & $st.digest()

proc canonicalSeqOf(id: string): int =
  let colon = id.rfind(':')
  if colon >= 0:
    try: return parseInt(id[colon + 1 .. ^1])
    except ValueError: discard

proc providerMessage(v: JsonNode): JsonNode =
  ## Strip storage-only telemetry from a canonical message before replay.
  result = newJObject()
  result["role"] = v{"role"}
  result["content"] = v{"content"}
  for field in ["tool_call_id", "name", "tool_calls", "reasoning"]:
    if v{field} != nil: result[field] = v{field}

proc recoverUsage(v: JsonNode, promptTokens: var int,
                  contextUsed: var int, ctxSize: var int) =
  if v{"role"}.getStr("") != "assistant": return
  if v{"usage"}{"prompt_tokens"} != nil:
    promptTokens = v{"usage"}{"prompt_tokens"}.getInt(0)
  let total = v{"usage"}{"total_tokens"}.getInt(0)
  let completion = v{"usage"}{"completion_tokens"}.getInt(0)
  if total > 0:
    contextUsed = total
  elif promptTokens > 0:
    contextUsed = promptTokens + completion
  if v{"context"} != nil: ctxSize = v{"context"}.getInt(0)

proc loadStoredMessagesEx*(ct: CoreTools, convId: string,
                           promptTokens: var int, contextUsed: var int,
                           ctxSize: var int,
                           after = ""): tuple[messages: seq[JsonNode],
                                              nodes: seq[CtxNode],
                                              lastSeqNo: int] =
  ## Rebuild a conversation's message list from the store (resume).
  ## Token/context fields are filled from the last assistant message's
  ## persisted usage so the context meter and guard survive restarts.
  ## lastSeqNo is the highest stored message id (all roles, including the
  ## error-role audit records the returned list excludes) — the next
  ## persistMsg must continue AFTER it, never reuse its id.
  ##
  ## The returned nodes carry each message's canonical id (§4.2) so the
  ## rebuilt context knows what it holds. A projection reload starts the
  ## read at `after` (exclusive id cursor): everything up to and including
  ## a projection's covered range is already represented by the checkpoint
  ## node, so the reader resumes at covered.to. projectionIndex values are
  ## relative to the RETURNED list — a caller that composes system or
  ## checkpoint nodes ahead of them re-indexes to stay 1:1 with its own
  ## projection. canonicalHigh derives from the last canonical node.
  ##
  ## A store failure here is FATAL, not silently empty: resuming with an
  ## empty list would restart seqNo at 0 and overwrite the transcript
  ## (observed once as a whole conversation clobbered after a store reply
  ## outgrew the bus max payload and the list reply never arrived).
  result.messages = @[]
  result.nodes = @[]
  result.lastSeqNo = 0
  # Page the whole transcript (storeListAll): a single capped `list` saw
  # only the first 1000 messages, so a long conversation resumed TRUNCATED
  # and — because lastSeqNo is derived from the ids actually seen — the
  # next persist targeted an id that already held history, overwriting it.
  # tests/t_resume_long.nim demonstrates both failures against the capped
  # read and asserts completeness here.
  for item in ct.storeListAll("message", convId & ":", after = after):
    let v = item{"value"}
    # Continuation id: the highest stored id number wins — covers
    # error-role records too (the loaded list excludes them, so its length
    # would collide with their ids).
    let id = item{"id"}.getStr("")
    let seqNo = canonicalSeqOf(id)
    result.lastSeqNo = max(result.lastSeqNo, seqNo)
    # Turn errors are audit records, not provider message roles.
    if v{"role"}.getStr("") == "error": continue
    result.nodes.add(CtxNode(source: nsCanonical, id: id,
                             canonicalSeq: seqNo,
                             projectionIndex: result.messages.len))
    result.messages.add(providerMessage(v))
    recoverUsage(v, promptTokens, contextUsed, ctxSize)
  if result.lastSeqNo == 0 and result.messages.len > 0:
    result.lastSeqNo = result.messages.len

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
     "profile": exposure.profile,
     "profileMissing": (if exposure.profileMissing == nil: newJArray() else: exposure.profileMissing),
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

proc loadToolExposure*(ct: CoreTools, sessionId: string,
                       profile = ""): ToolExposure =
  ## Load the immutable direct tool snapshot and durable discovery summary.
  ## On first build (no stored doc), `profile` names a stored tool profile
  ## (store kind "profile") whose selectors are resolved against the live
  ## catalog ONCE — the resolved set is persisted and the profile argument
  ## is ignored on every resume, so the request prefix stays byte-stable
  ## for the conversation's lifetime. A named profile that does not exist
  ## raises: explicit selection must not silently fall back.
  try:
    let (value, rev) = ct.storeGetItem("session", sessionId & ":tools")
    if value != nil and value{"version"}.getInt(0) == 1 and
        value{"direct"} != nil and value{"direct"}.kind == JArray:
      result.direct = value{"direct"}
      result.discovered = value{"discovered"}
      if result.discovered == nil or result.discovered.kind != JArray:
        result.discovered = newJArray()
      result.initializedAt = value{"initializedAt"}.getFloat(epochTime())
      result.profile = value{"profile"}.getStr("")
      result.profileMissing = value{"profileMissing"}
      if result.profileMissing == nil or result.profileMissing.kind != JArray:
        result.profileMissing = newJArray()
      result.rev = rev
      return
  except CatchableError:
    discard

  result = ToolExposure(direct: directToolSnapshot(ct),
                        discovered: newJArray(),
                        initializedAt: epochTime())
  if profile.len > 0:
    let (doc, _) = ct.storeGetItem("profile", profile)
    if doc == nil:
      raise newException(ValueError,
        "profile '" & profile & "' not found — profile {\"op\": \"list\"} lists saved profiles")
    var selectors: seq[string]
    if doc{"tools"} != nil and doc{"tools"}.kind == JArray:
      for sel in doc{"tools"}:
        let s = sel.getStr("")
        if s.len > 0: selectors.add(s)
    let (direct, missing) = ct.cat.resolveProfile(result.direct, selectors)
    result.direct = direct
    result.profile = profile
    result.profileMissing = missing
    for m in missing:
      stderr.writeLine("session: profile '" & profile & "': selector skipped (unknown or hidden): " &
                       m.getStr(""))
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
  ctxWarnRatio = 0.75  ## warn once this far along the way to the trim rung
  ctxTrimRatio = 0.9   ## trim whole turns from the front at this fraction
  minKeepTurns* = 2    ## never trim below this many user turns
  pruneThreshold = 8192   ## chars — tool results over this get pruned (§5.2)
  pruneHead = 4096        ## chars kept from the head
  pruneTail = 1024        ## chars kept from the tail
  ctxOutputReserve = 16_384  ## tokens held back for the model's next reply
                             ## (pi compacts at window − reserve); env
                             ## NIF_CTX_RESERVE overrides, 0 disables

proc outputReserve*(p: Persister): int =
  ## Tokens held back for the model's next reply: the model's declared output
  ## cap when the catalog resolved one (the provider counts the requested
  ## max_tokens against its window at admission — reserving the fixed 16K
  ## while asking for 384K let a 736,803-token prompt overflow a 1,048,576
  ## limit the prompt alone fit), else the fixed default. NIF_CTX_RESERVE
  ## overrides either; 0 disables. Exported for tests.
  let v = getEnv("NIF_CTX_RESERVE", "").strip()
  if v.len > 0:
    try:
      return max(parseInt(v), 0)
    except CatchableError:
      discard
  if p.ctxOutput > 0: return p.ctxOutput
  return ctxOutputReserve

proc wakeBudget*(): int =
  ## Consecutive autonomous wake turns a conversation may run before a real
  ## user message must reset the budget (dsh's maxConsecutiveWakes). A wake
  ## turn is a session call with `wake: true` that exists only to fold
  ## pending background-settlement notices into an idle conversation. 0
  ## disables wakes entirely. Exported for tests.
  try: result = max(0, getEnv("NIF_AGENT_WAKES", "3").parseInt())
  except CatchableError: result = 3

proc noticeHoldEnabled*(): bool =
  ## Whether a settlement that lands during a live turn holds that turn open
  ## for one more step (docs/WIRE.md "Busy-parent inbox"): the would-stop
  ## point drains notices exactly as it drains steer and advisories, so the
  ## turn cannot close over a child that just finished. On by default;
  ## `NIF_AGENT_NOTICE_HOLD=0` restores the plain next-turn pull (the
  ## scripted bus-contract suites pin it off for deterministic round counts).
  ## Exported for tests.
  case getEnv("NIF_AGENT_NOTICE_HOLD", "1").strip()
  of "0", "false", "no": false
  else: true

proc consecutiveWakeTurns*(messages: seq[JsonNode]): int =
  ## How many wake-marked user messages trail the last real user input.
  ## Machinery (subagent/process notices, mails) is skipped; the first
  ## user message without a notice marker resets the count. Derived from
  ## history rather than stored state, so it survives runner restarts and
  ## needs no counter to lose. Exported for tests.
  for i in countdown(messages.high, 0):
    let m = messages[i]
    if m{"role"}.getStr("") != "user": continue
    if m{"notice"} == nil: return result
    if m{"notice"}{"kind"}.getStr("") == "wake": inc result

proc consecutiveWakeTurnsFromStore(ct: CoreTools, sessionId: string): int =
  ## The wake budget derived from the STORED records: the in-memory
  ## projection goes through providerMessage(), which strips storage-only
  ## markers exactly so strict backends never see them — so it cannot be
  ## asked whether a message was a wake. One bounded store page is enough
  ## for the trailing run; an overflowing page only ever undercounts
  ## (conservative: at worst one extra wake is admitted).
  try:
    var records: seq[JsonNode] = @[]
    for item in ct.storeListItems("message", sessionId & ":", 1000, 10_000):
      records.add(item{"value"})
    result = consecutiveWakeTurns(records)
  except CatchableError:
    result = 0

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
  let reserved = max(p.ctxSize - outputReserve(p), p.ctxSize div 2)
  return min(ratioBound, reserved)

proc reindexNodes(p: var Persister) =
  ## After any structural edit, restore the ledger invariant nodes[i] describes
  ## messages[i]. Live appends set the index at insert; this is for deletes.
  for i in 0 ..< p.nodes.len:
    p.nodes[i].projectionIndex = i

proc pruneNode(p: var Persister, messages: var seq[JsonNode], i: int,
               record = true): int =
  ## Apply the deterministic §5.2 projection edit to one canonical tool
  ## result. Shared by live admission and projection reload so recorded
  ## prunes reproduce byte-identically after a runner restart.
  if i < 0 or i >= p.nodes.len or i >= messages.len: return 0
  let n = p.nodes[i]
  if n.source != nsCanonical: return 0
  let m = messages[i]
  if m{"role"}.getStr("") != "tool": return 0
  let content = m{"content"}.getStr("")
  if content.len <= pruneThreshold or
      content.contains("[tool result middle pruned"):
    return 0
  # §5.3 gate — failure is never worse than the status quo. A result
  # carrying a spill pointer depends on its durable spill document for the
  # full capture; storage failure keeps the original un-pruned.
  var spillBacked = false
  if content.contains("[full output:"):
    try:
      let item = p.ct.storeGetItem("spill", n.id, 5_000)
      if item.value == nil or item.value{"text"}.getStr("").len == 0:
        return 0
      spillBacked = true
    except CatchableError:
      return 0
  let head = content[0 ..< pruneHead]
  let tail = content[^pruneTail .. ^1]
  let omitted = content.len - pruneHead - pruneTail
  let refJson = if spillBacked:
    "{\"ref\": {\"source\": \"spill\", \"id\": \"" & n.id & "\"}}"
  else:
    "{\"ref\": {\"source\": \"canonical\", \"id\": \"" & n.id & "\"}}"
  let body = head & "\n[tool result middle pruned: " & $omitted &
    " bytes omitted — recall the original with context_recall " & refJson &
    "]\n" & tail
  if body.len >= content.len: return 0
  messages[i]["content"] = %body
  if record:
    p.prunes.add(PruneRec(id: n.id, bytesBefore: content.len,
                          bytesAfter: body.len))
  content.len - body.len

proc pruneContext*(p: var Persister, messages: var seq[JsonNode]): int =
  ## §5.2 model-free prune: tool results only, whole-result boundaries.
  ## Role, pairing and machine fields stay intact; canonical history is never
  ## rewritten. Returns measured bytes saved and is idempotent.
  for i in 0 ..< p.nodes.len:
    result += p.pruneNode(messages, i)

proc latestUserIndex(p: Persister, messages: seq[JsonNode]): int =
  ## Message index of the newest canonical user request — the turn being
  ## worked on. A cut/trim must always keep it visible (§4.3).
  for i in countdown(p.nodes.len - 1, 0):
    if p.nodes[i].source == nsCanonical and i < messages.len and
        messages[i]{"role"}.getStr("") == "user":
      return i
  -1

proc trimTurns*(p: var Persister, messages: var seq[JsonNode],
                keepTurns: int): int =
  ## §6.3 trim: drop the oldest complete turns from the projection, keeping
  ## the system node, the newest `keepTurns` user requests and everything
  ## after them (whole-turn drops keep tool_call_id pairs intact), with an
  ## explicit "history omitted without summary" notice naming the covered
  ## ids. Messages and the node ledger move in lockstep; canonicalHigh is
  ## untouched (canonical docs are unaffected — the notice is a projection
  ## edit, and recall-canonical still reaches what was dropped).
  ## The cut is DURABLE: the highest dropped canonical seqNo is recorded in
  ## the header (trimThrough) and the ordinary resume path honors it, so a
  ## restart rebuilds the trimmed projection instead of re-inflating to the
  ## full pre-trim context while the meter reports post-trim usage.
  ## Returns the number of dropped messages.
  result = 0
  var users: seq[int]
  for i, n in p.nodes:
    if n.source == nsCanonical and i < messages.len and
        messages[i]{"role"}.getStr("") == "user":
      users.add(i)
  if users.len <= keepTurns: return 0
  let dropEnd = users[users.len - keepTurns]   # first kept user request
  # A committed checkpoint is the durable summary of an earlier range and
  # must survive the no-summary fallback rung (§6.3). Trim only the retained
  # canonical span after it; without a checkpoint the removable span begins
  # immediately after the system node as before.
  let dropStart = if p.nodes.len > 1 and
                       p.nodes[1].source == nsCheckpoint: 2 else: 1
  if dropEnd <= dropStart: return 0
  let coveredFrom = p.nodes[dropStart].id
  let coveredTo = p.nodes[dropEnd - 1].id
  messages.delete(dropStart ..< dropEnd)
  p.nodes.delete(dropStart ..< dropEnd)
  result = dropEnd - dropStart
  # Persist the cut immediately (not at turn end): the whole point of the
  # watermark is surviving a restart, whenever it comes.
  let cutSeq = canonicalSeqOf(coveredTo)
  if cutSeq > p.trimThrough:
    p.trimThrough = cutSeq
    p.ct.updateConversationHeader(p.convId,
                                 %*{"trimThrough": %p.trimThrough})
  let notice = %*{"role": "system", "content":
    "[history omitted without summary: dropped " & $result &
    " earlier messages (" & coveredFrom & " .. " & coveredTo &
    ") to fit the model window — the originals remain in canonical history]"}
  messages.insert(notice, dropStart)
  p.nodes.insert(CtxNode(source: nsNotice,
                         id: p.convId & "#omit-" & $p.canonicalHigh &
                             "-" & $dropEnd,
                         projectionIndex: dropStart), dropStart)
  p.reindexNodes()

proc contextTarget*(p: Persister): int =
  ## The hard admission line (§6.1): the whole candidate request plus the
  ## output reserve must fit the window. 0 when capacity is unknown —
  ## admission then stands down and overflow recovery owns the failure.
  if p.ctxSize <= 0: return 0
  # Floor at half the window (mirrors trimThreshold): a declared output cap
  # past half the window must not drive the retained context to nothing —
  # dispatch's fitOutput clamps the completion to the headroom the prompt
  # actually leaves.
  max(p.ctxSize - outputReserve(p), p.ctxSize div 2)

proc runFallbackLadder*(p: var Persister, messages: var seq[JsonNode],
                        toolTokens: int,
                        onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
                        turnId = ""): bool =
  ## §6.3 deterministic fallback ladder, no component required:
  ## prune (tool results) → trim (oldest complete turns, down to keeping
  ## only the latest user request). Returns true when the candidate now
  ## fits the hard target. Reductions are re-measured, never claimed.
  let target = p.contextTarget()
  if target <= 0: return false
  var used = estimateTokens(messages) + toolTokens + p.calib
  if used <= target: return true
  # 1. prune — cheapest first: no history is lost, only bulk
  let saved = p.pruneContext(messages)
  if saved > 0:
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "reset:prune", "bytesSaved": saved,
                            "pruned": p.prunes.len})
    used = estimateTokens(messages) + toolTokens + p.calib
    if used <= target: return true
  # 2. trim — oldest complete turns first, then down to the latest request
  for keep in [minKeepTurns, 1]:
    if used <= target: break
    let dropped = p.trimTurns(messages, keep)
    if dropped == 0: continue
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "promptTokens": p.promptTokens,
                            "usedTokens": used, "context": p.ctxSize,
                            "trimAt": trimThreshold(p),
                            "reserveTokens": outputReserve(p),
                            "trimmed": dropped,
                            "reason": "reset:trim",
                            "note": "history reset — the next request rebuilds the provider prompt cache from the remaining prefix"})
    used = estimateTokens(messages) + toolTokens + p.calib
  return used <= target

proc contextPressureDetail(p: Persister, messages: seq[JsonNode],
                           used, target, toolTokens: int): string =
  ## Stable explanation used only after every configured recovery rung has
  ## had a chance. Pressure itself is not an error: the runner may still
  ## summarize or trim before it emits context-recovery-required.
  let sysTokens = (if messages.len > 0: estimateTokens(@[messages[0]]) else: 0) +
                  toolTokens
  let lu = p.latestUserIndex(messages)
  let tailTokens = if lu >= 0: estimateTokens(messages[lu .. ^1]) else: 0
  var cause = "retained history does not fit"
  if sysTokens > target:
    cause = "frozen prefix (system prompt + tools) alone exceeds the window"
  elif sysTokens + tailTokens > target:
    cause = "newest indivisible tool group alone exceeds the window"
  cause & " — request ~" & $used & " tokens vs target " & $target &
    " (window " & $p.ctxSize & "); enlarge the model context, compact " &
    "explicitly, or continue from selected history"

proc checkContext*(p: var Persister, messages: var seq[JsonNode],
                   onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
                   turnId = "", toolTokens = 0): string =
  ## Admission (§6.1): runs before EVERY provider request, not just at
  ## user-turn entry. It performs the lossless prune rung, then returns ""
  ## when the candidate fits or "pressure:<detail>" when the runner must try
  ## summarization and/or lossy trim. Keeping those later rungs outside this
  ## proc establishes the required order (§6.3): prune → configured
  ## compactor → trim → explicit context-recovery-required.
  if p.ctxSize <= 0: return ""   # unknown capacity — overflow recovery owns it
  # One measure for everything below — warning percentage, prune trigger,
  # pressure line: the local estimate, shifted into the provider's scale by
  # the calibration offset measured from the last response. Before the
  # first response (calib 0) this is the raw chars/4 proxy — conservative
  # only when the provider counts less than the estimate.
  template measured(toolTokens: int): int =
    estimateTokens(messages) + toolTokens + p.calib
  let used0 = measured(toolTokens)
  let pct = int(used0.float * 100.0 / p.ctxSize.float)
  let trimAt = trimThreshold(p)
  # The warning tracks the EFFECTIVE rung, not the bare ratio bound: a large
  # declared output cap lowers the trim line (deepseek: 384000 output against
  # a 1M window compacts at 62%), so a fixed 75%-of-window check would fire
  # after compaction or, when the cap pushes the line below it, never.
  let warnAt = int(trimAt.float * ctxWarnRatio)
  if used0 >= warnAt and not p.ctxWarned:
    p.ctxWarned = true
    echo "core: WARNING context at " & $pct & "% — will compact/trim at " &
         $(int(trimAt.float * 100.0 / p.ctxSize.float)) & "%"
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "promptTokens": p.promptTokens,
                            "usedTokens": used0, "context": p.ctxSize,
                            "warning": true,
                            "reason": "warn:threshold"})
  var used = measured(toolTokens)
  if used >= trimAt:
    let saved = p.pruneContext(messages)
    if saved > 0 and onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "reset:prune", "bytesSaved": saved,
                            "pruned": p.prunes.len})
    used = measured(toolTokens)
  let target = p.contextTarget()
  if used <= target: return ""
  "pressure:" & contextPressureDetail(p, messages, used, target, toolTokens)

proc runTrimRung*(p: var Persister, messages: var seq[JsonNode],
                  toolTokens: int,
                  onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
                  turnId = "") =
  ## The final lossy rung (§6.3), deliberately separate from admission so a
  ## replaceable compactor always gets the first chance after lossless prune.
  let target = p.contextTarget()
  var used = estimateTokens(messages) + toolTokens + p.calib
  for keep in [minKeepTurns, 1]:
    if used <= target: break
    let dropped = p.trimTurns(messages, keep)
    if dropped == 0: continue
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "promptTokens": p.promptTokens,
                            "usedTokens": used, "context": p.ctxSize,
                            "trimAt": trimThreshold(p),
                            "reserveTokens": outputReserve(p),
                            "trimmed": dropped,
                            "reason": "reset:trim",
                            "note": "history reset — the next request rebuilds the provider prompt cache from the remaining prefix"})
    used = estimateTokens(messages) + toolTokens + p.calib

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
  # The declared output cap is the admission reserve (outputReserve): the
  # provider counts the requested max_tokens against the window, so it must
  # be known before the first checkContext of the turn (this runs first).
  let resolvedOutput = resolved{"output"}.getInt(0)
  if resolvedOutput > 0:
    p.ctxOutput = resolvedOutput
  # The calibration offset is model-specific: switching models (or their
  # provider) changes the tokenizer — drop the stale offset and re-learn
  # from the next response.
  if p.calibModel.len > 0 and p.calibModel != selectedModel:
    p.calib = 0
  if p.calibModel != selectedModel:
    p.calibModel = selectedModel
  result = %*{
    "sessionId": p.convId,
    "provider": resolved{"provider"}.getStr(""),
    "providerSource": resolved{"providerSource"}.getStr(""),
    "model": selectedModel,
    "catalog": resolved{"catalog"}.getStr(""),
    "context": p.ctxSize,
    "contextSource": resolved{"contextSource"}.getStr(""),
    "output": p.ctxOutput,
    "outputSource": resolved{"outputSource"}.getStr(""),
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
    ctxAppend(p, messages, steerMsg)
    if onEvent != nil:
      onEvent("steer", %*{"sessionId": sessionId, "turnId": turnId,
                          "content": steered})
    result += 1
  ct.steerStream.queue.setLen(0)

proc drainMap(ct: CoreTools, p: var Persister,
              messages: var seq[JsonNode],
              onEvent: proc(kind: string, data: JsonNode) {.closure.}) =
  ## Append the conversation's repo map once (docs/research/REPOMAP.md):
  ## a user-role message carrying the ranked workspace snapshot. One per
  ## conversation; append-only history, never the frozen prefix. If the
  ## compaction trims it away later, the repo_map tool re-creates it.
  if ct.mapStream == nil: return
  if ct.mapStream.appended: return
  for (ws, map) in ct.mapStream.queue:
    ct.mapStream.appended = true
    let msg = %*{"role": "user",
                 "content": "[repo map of " & ws & " — a ranked snapshot of " &
                   "this workspace when the conversation started. Edits you " &
                   "make are not in it; call repo_map for a fresh one.]\n" & map}
    ctxAppend(p, messages, msg)
    if onEvent != nil:
      onEvent("map", %*{"sessionId": p.convId, "workspace": ws,
                        "bytes": map.len})
    break
  ct.diagStream.queue.setLen(0)

proc drainDiagnostics(ct: CoreTools, p: var Persister,
                      messages: var seq[JsonNode],
                      onEvent: proc(kind: string, data: JsonNode) {.closure.}) =
  ## Append LSP diagnostics that arrived asynchronously for files edited this
  ## turn. The edit tool no longer waits for a cold server (the Multilingual-10
  ## run paid 39 such waits, ~16 minutes, for no information); the lsp
  ## component publishes the rendered result on svc.session.<id>.diag when the
  ## server answers and the runner folds it in here. Append-only history,
  ## never the frozen prefix — the drainMap doctrine. Newest text per path
  ## wins, so five edits to one file cost one message instead of five.
  if ct.diagStream == nil or ct.diagStream.queue.len == 0: return
  var latest: seq[tuple[path, text: string]]
  for (path, text) in ct.diagStream.queue:
    var replaced = false
    for i in 0 ..< latest.len:
      if latest[i].path == path:
        latest[i] = (path, text)
        replaced = true
        break
    if not replaced: latest.add((path, text))
  ct.diagStream.queue.setLen(0)
  for (path, text) in latest:
    ctxAppend(p, messages, %*{"role": "user",
      "content": "[lsp diagnostics for " & path & " — asynchronously " &
                 "delivered after your edit, when the server answered]\n" & text})
    if onEvent != nil:
      onEvent("diagnostics", %*{"sessionId": p.convId, "path": path,
                                "bytes": text.len})

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
    ctxAppend(p, messages, advMsg)
    if onEvent != nil:
      onEvent("advice", %*{"sessionId": sessionId, "turnId": turnId,
                           "source": source, "content": content,
                           "reason": adv{"reason"}.getStr("")})
    result += 1
  ct.adviseStream.queue.setLen(0)

proc drainNotices(ct: CoreTools, p: var Persister,
                  messages: var seq[JsonNode],
                  onEvent: proc(kind: string, data: JsonNode) {.closure.},
                  turnId = ""): int =
  ## Fold pending background-settlement notices into the running conversation
  ## (docs/research/SUBAGENTS-PLAN.md P0.1). A background child that settled
  ## while this conversation was idle left an `agentnotice` record; without
  ## this drain the parent would have to poll agent_status to learn about it.
  ## The same lane carries the processes component's exit notices
  ## (kind "process-exited", docs/WIRE.md "Settlement notices"), so one drain
  ## covers every background thing the conversation started.
  ##
  ## Fetched at the top of every turn (like steer and advisories) so the
  ## pull lane is invisible to the model — it never has to remember to ask.
  ## The notice is written as a structurally marked user message: the
  ## `notice` field is the provenance, so rendering, trimming and compaction
  ## can treat it as runtime machinery rather than something the user said
  ## (the lesson from OpenHands' prefix-matched goal prompts).
  ##
  ## Best-effort: a missing/unreachable agent component costs a notice, not
  ## the turn.
  ##
  ## TWO lanes, one place: notices pushed over the steer channel while this
  ## turn was running (the parent was mid-turn when the child settled) are
  ## consumed from the queue first; anything still pending in the store is
  ## then pulled (the child settled while this conversation was idle).
  ## Taking the queue first is what keeps a wake-delivered notice from being
  ## delivered twice.
  let sessionId = p.convId
  # Fold the two lanes in order: what the steer channel pushed while this
  # turn was live (Lane 1), then whatever is still pending in the store
  # (Lane 2, the idle parent). Lane 1 first is what keeps a wake-delivered
  # notice from also arriving through the pull drain.
  var inbound = newJArray()
  if ct.steerStream != nil and ct.steerStream.notices.len > 0:
    for n in ct.steerStream.notices: inbound.add(n)
    ct.steerStream.notices.setLen(0)
  var pending: JsonNode
  try:
    pending = ct.dispatchToolCall("agent_notices",
      %*{"session": sessionId, "peek": false}, 5_000)
  except CatchableError:
    pending = nil
  let pulled = if pending != nil: pending{"notices"} else: nil
  if pulled != nil and pulled.kind == JArray:
    for n in pulled: inbound.add(n)
  for n in inbound:
    # Two directions share the agentnotice kind (P3.9): child-settled
    # notices (a background job reached a terminal state) and parent-mail
    # (steering/questions queued while the child was between turns or
    # mid-turn). Both fold as structurally marked user messages — runtime
    # machinery, never something the user typed.
    var noticeMsg: JsonNode
    var eventId = %*{"sessionId": sessionId, "turnId": turnId}
    if n{"direction"}.getStr("") == "parent-mail":
      let mailFrom = n{"from"}.getStr("")
      let text = n{"text"}.getStr("")
      let content = "[mail from the parent conversation]\n" & text
      noticeMsg = %*{"role": "user", "content": content,
                     "mail": {"kind": "parent-mail", "from": mailFrom}}
      eventId["kind"] = %"mail"
      eventId["from"] = %mailFrom
      eventId["content"] = %content
    elif n{"kind"}.getStr("") == "process-exited":
      # A background process this conversation owns (components/processes)
      # reached a terminal state. Pointer, not payload: the id, the status and
      # how much output exists — the text itself stays in the spool, where the
      # conversation's own process_poll can read it. Without this the model
      # only learned of an exit by polling.
      let pid = n{"processId"}.getStr("")
      if pid.len == 0: continue
      let label = n{"label"}.getStr("")
      let pstatus = n{"status"}.getStr("")
      let bytes = n{"outputBytes"}.getInt(0)
      let secs = max(0, int(n{"endedAt"}.getFloat(0) -
                            n{"startedAt"}.getFloat(0)))
      var content = "[background process " & pid &
                    (if label.len > 0: " (" & label & ")" else: "") &
                    " " & pstatus & "]"
      content.add("\nran " & $secs & "s, " & $bytes & " bytes of output — " &
                  "read it with process_poll {id: \"" & pid & "\"}")
      noticeMsg = %*{"role": "user", "content": content,
                     "notice": {"kind": "process-exited",
                                "processId": pid, "status": pstatus}}
      eventId["kind"] = %"process"
      eventId["processId"] = %pid
      eventId["status"] = %pstatus
      eventId["content"] = %content
    else:
      let status = n{"status"}.getStr("")
      if status.len == 0: continue
      let jobId = n{"jobId"}.getStr("")
      let child = n{"child"}.getStr("")
      let summary = n{"summary"}.getStr("")
      let replyBytes = n{"replyBytes"}.getInt(0)
      var content = "[subagent " & child & " " & status & "]"
      if summary.len > 0:
        content.add("\n" & summary)
      if replyBytes > summary.len:
        content.add("\n(full reply: " & $replyBytes & " bytes — " &
                    n{"fullReplyIn"}.getStr("agent_status") &
                    " {jobId: \"" & jobId & "\"})")
      noticeMsg = %*{"role": "user", "content": content,
                     "notice": {"kind": "subagent-settled",
                                "jobId": jobId, "child": child,
                                "status": status}}
      eventId["kind"] = %"subagent-settled"
      eventId["jobId"] = %jobId
      eventId["child"] = %child
      eventId["status"] = %status
      eventId["content"] = %content
    # ctxAppend, not a bare messages.add: compaction's node ledger must stay
    # 1:1 with the projection, and notices are runtime machinery it may
    # compact away like any other appended history (docs/research/COMPACTION.md §4.2)
    ctxAppend(p, messages, noticeMsg)
    if onEvent != nil:
      onEvent("notice", eventId)
    result += 1

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

proc promoteSticky(ct: CoreTools, sessionId: string,
                   exposure: var ToolExposure, args: JsonNode,
                   oc: ToolCallOutcome) =
  ## invoke {sticky: true}: after a successful call, append the target's
  ## schema to the session's direct set (persisted with the exposure doc).
  ## Later calls can use the tool's own schema/name; this changes the
  ## request prefix, not the number of tool-call rounds. Capped by NIF_MAX_DIRECT_TOKENS
  ## (default 4000) and inert under a session allowlist: subagent scoping
  ## is frozen by design and promotion must not widen it. The target uses
  ## the same name tolerance as invokeTool; hidden tools are never promoted.
  if not args{"sticky"}.getBool(false): return
  var name = args{"tool"}.getStr("")
  if name.len == 0: return
  if ct.cat.toolSchema(name) == nil and name.contains('.'):
    name = name.split('.')[^1]
  let schema = ct.cat.toolSchema(name)
  if schema == nil or schema.isHidden(): return
  if ct.sessionAllowlist != nil and ct.sessionAllowlist[].len > 0:
    if oc.value != nil and oc.value.kind == JObject:
      oc.value["sticky"] = %"deferred: session tool allowlist is active"
    return
  for tool in exposure.direct:
    if tool{"name"}.getStr("") == name: return   # already direct
  var cap = 4000
  try: cap = getEnv("NIF_MAX_DIRECT_TOKENS", "4000").parseInt()
  except CatchableError: discard
  let cost = ($(schema)).len div 4 + 16
  if profileTokens(exposure.direct) + cost > cap:
    if oc.value != nil and oc.value.kind == JObject:
      oc.value["sticky"] = %("deferred: direct-toolset cap reached (" & $cap & " tokens)")
    return
  var candidate = exposure
  candidate.direct = exposure.direct.copy()
  candidate.direct.add(%*{"component": ct.cat.toolIndex.getOrDefault(name),
                          "name": name, "schema": normalizeToolSchema(schema)})
  try:
    candidate.rev = ct.storePutRev("session", sessionId & ":tools",
      exposureValue(candidate), expectRev = exposure.rev)
    exposure = candidate
  except CatchableError:
    if oc.value != nil and oc.value.kind == JObject:
      oc.value["sticky"] = %"deferred: could not persist toolset promotion"

proc nextMsgKey(p: Persister): string =
  ## Peek the key persistMsg will allocate next — spill promotion needs the
  ## canonical id BEFORE the tool message is persisted, so the notice naming
  ## the ref is part of the stored body from birth (no rewrite).
  p.convId & ":" & align($(p.seqNo + 1), 6, '0')

proc promoteSpill(ct: CoreTools, p: Persister, sessionId: string,
                  value: JsonNode, content: var string) =
  ## §5.1 execution-time spill promotion: a tool that capped its transcript
  ## body (bash's transcriptCapBytes) leaves a spill pointer naming a temp
  ## file. v1 promotes the full capture into a store document (kind: spill,
  ## id = the tool result's canonical key) so it survives runner restarts
  ## and is addressable by context_recall, not only by file path. Best-
  ## effort: a failed promotion keeps today's behavior (file pointer + read
  ## paging) and no ref line is added — a missing ref never lies.
  if value == nil or value.kind != JObject: return
  let path = value{"spill"}{"path"}.getStr("")
  if path.len == 0 or not fileExists(path): return
  try:
    let full = readFile(path)
    if full.len == 0: return
    let key = p.nextMsgKey()
    discard ct.storePutRev("spill", key,
      %*{"text": full, "bytes": full.len,
         "path": path, "session": sessionId,
         "tool": value{"tool"}.getStr(""), "createdAt": epochTime()})
    content &= "\n[recall: the full " & $full.len & "-byte output is " &
      "retrievable with context_recall {\"ref\": {\"source\": \"spill\", " &
      "\"id\": \"" & key & "\"}} — this transcript holds a capped copy]"
  except CatchableError as e:
    echo "core: WARNING spill promotion failed (keeping the file pointer): " &
         e.msg

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
  elif oc.ok and it.name == "invoke" and oc.value{"error"} == nil and
      oc.value{"ok"}.getBool(true):
    let before = exposure.direct.len
    promoteSticky(ct, sessionId, exposure, it.args, oc)
    if exposure.direct.len > before and onEvent != nil:
      onEvent("status", %*{"sessionId": sessionId, "turnId": turnId,
        "reason": "reset:tools", "directToolCount": exposure.direct.len,
        "estimatedToolTokens": profileTokens(exposure.direct)})
  ## LLM-facing projection (WIRE.md, "Tool results"): a result object with
  ## a string `text` field is rendered verbatim into the tool message —
  ## that is the whole diet; every other field stays machine-readable on
  ## the bus (fabric programs, tests, UIs) and never reaches the transcript.
  let partialFailure = not oc.ok and oc.value != nil and
                       oc.value{"__partial"}.getBool(false)
  let content =
    if oc.ok or partialFailure:
      let t = oc.value{"text"}
      if t.isStr: t.getStr()
      else: jdump(oc.value)
    else:
      ""
  let toolMsg =
    if oc.ok or partialFailure:
      var body = content
      promoteSpill(ct, p, sessionId, oc.value, body)
      if oc.value{"__partial"}.getBool(false):
        let reason = oc.value{"__partialReason"}.getStr("cancelled")
        let wording = if reason == "timed_out":
                        "timed out"
                      else:
                        "cancelled by user"
        body.add("\n\n[tool output above is partial; " & wording &
                 "; retry may be useful]")
      if partialFailure:
        body = "ERROR: " & oc.error & "\n\n" & body
      %*{"role": "tool", "tool_call_id": it.id, "name": it.name,
         "content": body}
    else:
      %*{"role": "tool", "tool_call_id": it.id, "name": it.name,
         "content": "ERROR: " & oc.error}
  ctxAppend(p, messages, toolMsg,
    %*{"turnId": turnId, "startedAt": toolStartedAt,
       "durationMs": toolDurationMs})
  if onEvent != nil:
    if oc.ok or partialFailure:
      var event = %*{"sessionId": sessionId, "turnId": turnId,
                      "callId": it.id, "phase": "done",
                      "tool": it.name, "args": it.args,
                      "result": oc.value,
                      "durationMs": toolDurationMs,
                      "at": epochTime()}
      if partialFailure: event["error"] = %oc.error
      onEvent("toolcall", event)
    else:
      onEvent("toolcall", %*{"sessionId": sessionId, "turnId": turnId,
                             "callId": it.id, "phase": "done",
                             "tool": it.name, "args": it.args,
                             "error": oc.error,
                             "durationMs": toolDurationMs,
                             "at": epochTime()})

proc sourceName(source: NodeSource): string =
  case source
  of nsCanonical: "canonical"
  of nsCheckpoint: "checkpoint"
  of nsNotice: "notice"
  of nsSystem: "system"

proc snapshotManifestDigest(manifest: JsonNode): string =
  ## Bind the ordered node ids and the exact message bodies the component
  ## read. Per-node contentHash fields also let commit validate exactly the
  ## covered span chosen by the candidate.
  var body = ""
  if manifest != nil and manifest.kind == JArray:
    for n in manifest:
      body.add(n{"source"}.getStr("") & "\x1f" & n{"id"}.getStr("") &
               "\x1f" & n{"contentHash"}.getStr("") & "\x1e")
  contentDigest(body)

proc cleanupSnapshot(ct: CoreTools, metaId: string, pageCount: int) =
  try: ct.storeDel("compaction_input", metaId)
  except CatchableError: discard
  for i in 0 ..< pageCount:
    try:
      ct.storeDel("compaction_input",
        metaId & ":p" & align($i, 6, '0'))
    except CatchableError:
      discard

proc sweepCompactionSnapshots(ct: CoreTools, convId: string) =
  ## Settle orphaned inputs from crashed/timed-out attempts after a grace
  ## period. Snapshot pages are temporary inputs, never canonical history.
  try:
    let items = ct.storeListAll("compaction_input", convId & ":")
    for item in items:
      let id = item{"id"}.getStr("")
      if ":p" in id: continue
      let value = item{"value"}
      if value != nil and epochTime() - value{"createdAt"}.getFloat(epochTime()) >
          snapshotSweepSecs:
        cleanupSnapshot(ct, id, value{"pageCount"}.getInt(0))
  except CatchableError:
    discard

proc attemptCompaction*(ct: CoreTools, p: var Persister,
                        messages: var seq[JsonNode],
                        frozenTools: JsonNode,
                        onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
                        turnId = "", trigger = "pressure",
                        provider = "", model = "",
                        cfg = compactionConfigFromEnv()): CompactionAttempt =
  ## One bounded replacement attempt (§4.4–§6.3): persist and reference a
  ## verified snapshot, ask the selected replaceable component for a
  ## candidate, validate it, atomically install one context_projection with
  ## expectRev, then and only then replace the in-memory covered span. A
  ## timeout, decline, malformed answer or conflict returns a structured
  ## failure and leaves the old projection installed; automatic callers
  ## proceed to lossy trim while manual callers surface the precise reason.
  result = CompactionAttempt(status: casFailed,
    reason: "compaction failed before a candidate could be installed")
  if cfg.tool.len == 0 or ct.cat.toolSchema(cfg.tool) == nil:
    result.status = casUnavailable
    result.reason = "no compaction component available"
    return
  if messages.len != p.nodes.len:
    result.reason = "live context/node ledger mismatch"
    return
  sweepCompactionSnapshots(ct, p.convId)

  var ids, sources, roles, callIds, answerIds: seq[string]
  var manifest = newJArray()
  for i, n in p.nodes:
    let m = messages[i]
    ids.add(n.id)
    sources.add(sourceName(n.source))
    roles.add(m{"role"}.getStr(""))
    var declared: seq[string]
    let calls = m{"tool_calls"}
    if calls != nil and calls.kind == JArray:
      for tc in calls:
        let id = tc{"id"}.getStr("")
        if id.len > 0: declared.add(id)
    callIds.add(declared.join("\x1f"))
    answerIds.add(if m{"role"}.getStr("") == "tool":
                    m{"tool_call_id"}.getStr("") else: "")
    var mn = %*{"index": i, "source": sourceName(n.source), "id": n.id,
                "role": m{"role"}.getStr(""),
                "tokens": estimateTokens(@[m]),
                "contentHash": contentDigest($m)}
    if n.source == nsCanonical: mn["canonicalSeq"] = %n.canonicalSeq
    manifest.add(mn)
  let cuts = permittedCuts(ids, sources, roles, callIds, answerIds)
  if cuts.len == 0:
    result.status = casDeclined
    result.reason = "no permitted cut exists yet"
    return
  var lastCovered = 1
  for c in cuts: lastCovered = max(lastCovered, c.index - 1)
  var contentRows = newJArray()
  for i in 1 .. lastCovered:
    contentRows.add(%*{"index": i, "source": sources[i], "id": ids[i],
                       "message": messages[i]})
  let contentJson = $contentRows
  let pages = chunkSnapshotContent(contentJson)
  let attemptId = newId()
  let metaId = p.convId & ":" & attemptId
  let digest = snapshotManifestDigest(manifest)
  var cutsJson = newJArray()
  for c in cuts:
    var retainedTokens = estimateTokens(messages[c.index .. ^1])
    if c.fromIndex > 1:
      retainedTokens += estimateTokens(messages[1 ..< c.fromIndex])
    cutsJson.add(%*{
      "fromIndex": c.fromIndex, "index": c.index,
      "cutBefore": {"source": c.source, "id": c.id},
      "covered": {
        "from": {"source": sources[c.fromIndex], "id": ids[c.fromIndex]},
        "to": {"source": sources[c.index - 1], "id": ids[c.index - 1]}
      },
      "tailTokens": retainedTokens
    })
  let target = p.contextTarget()
  let fixedPrefix = estimateTokens(@[messages[0]]) + ($frozenTools).len div 4
  let preferredTail = if target > 0: max(target div 5, 1) else: 0
  var meta = %*{
    "version": 1, "attemptId": attemptId, "sessionId": p.convId,
    "trigger": trigger, "createdAt": epochTime(),
    "generation": p.generation, "canonicalHigh": p.canonicalHigh,
    "digest": digest, "manifest": manifest,
    "systemPrompt": messages[0], "tools": frozenTools,
    "permittedCuts": cutsJson, "pageCount": pages.len,
    "contentBytes": contentJson.len,
    "target": {"targetInputTokens": target,
               "fixedPrefixTokens": fixedPrefix,
               "preferredTailTokens": preferredTail}
  }
  # The previously normalized checkpoint is repeated explicitly for
  # replacement components; it is also present in page content as the
  # rendered checkpoint node. This makes merge intent unambiguous.
  var previousProjection: JsonNode
  if p.generation > 0:
    try:
      let old = ct.storeGetItem("context_projection", p.convId)
      if old.value == nil or
          old.value{"generation"}.getInt(-1) != p.generation or
          old.value{"checkpoint"} == nil:
        result.reason = "previous checkpoint projection is missing or stale"
        return
      previousProjection = old.value
      meta["previousCheckpoint"] = old.value{"checkpoint"}
    except CatchableError as e:
      result.reason = "previous checkpoint projection is unavailable"
      result.detail = e.msg
      return
  try:
    discard ct.storePutRev("compaction_input", metaId, meta)
    for i, page in pages:
      discard ct.storePutRev("compaction_input",
        metaId & ":p" & align($i, 6, '0'),
        %*{"index": i, "bytes": page.len, "digest": contentDigest(page),
           "content": page, "createdAt": epochTime()})
  except CatchableError as e:
    cleanupSnapshot(ct, metaId, pages.len)
    echo "core: WARNING compaction snapshot not persisted: " & e.msg
    result.reason = "compaction snapshot could not be persisted"
    result.detail = e.msg
    return
  var settled = false
  defer:
    if settled: cleanupSnapshot(ct, metaId, pages.len)

  let request = %*{
    "version": 1, "sessionId": p.convId, "attemptId": attemptId,
    "trigger": trigger,
    "snapshot": {
      "ref": {"kind": "compaction_input", "id": metaId},
      "generation": p.generation, "canonicalHigh": p.canonicalHigh,
      "digest": digest
    },
    "budget": {
      "targetInputTokens": target, "fixedPrefixTokens": fixedPrefix,
      "preferredTailTokens": preferredTail,
      "maxSummaryTokens": cfg.maxSummaryTokens,
      "maxLlmCalls": cfg.maxLlmCalls,
      "maxTotalInputTokens": (if target > 0: %(target * cfg.maxLlmCalls)
                               else: newJNull()),
      "maxTotalOutputTokens": cfg.maxSummaryTokens * cfg.maxLlmCalls,
      "timeoutMs": cfg.timeoutMs
    }
  }
  if provider.len > 0: request["provider"] = %provider
  if model.len > 0: request["model"] = %model
  var cand: JsonNode
  try:
    cand = ct.dispatchToolCall(cfg.tool, request, cfg.timeoutMs)
  except CatchableError as e:
    # The component can still be unwinding after our request deadline. Leave
    # its pages for the startup/next-attempt grace-period sweep rather than
    # deleting input under a timed-out reader.
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "compact:failed", "error": e.msg})
    result.reason = "compactor call failed"
    result.detail = e.msg
    return
  settled = true
  # Resolve the claimed boundary first; the pure validator then checks that
  # the candidate names the exact implied covered range.
  var cutIdx = -1
  var coveredFrom = -1
  let cb = cand{"cutBefore"}
  if cb != nil:
    for c in cuts:
      if c.id == cb{"id"}.getStr("") and
          c.source == cb{"source"}.getStr(""):
        cutIdx = c.index
        coveredFrom = c.fromIndex
        break
  let coveredTo = if cutIdx >= 2: cutIdx - 1 else: 1
  let checked = validateCandidate(cand, attemptId, p.generation, digest,
    cuts, coveredFrom, coveredTo, ids, sources, roles)
  case checked.status
  of csDeclined:
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "compact:declined",
                            "detail": checked.declineReason})
    result.status = casDeclined
    result.reason = checked.declineReason
    return
  of csInvalid:
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "compact:invalid",
                            "detail": checked.detail})
    result.reason = "compactor returned an invalid candidate"
    result.detail = checked.detail
    return
  of csCandidate:
    discard
  # The granted auxiliary budget is part of the snapshot contract (§4.7):
  # a candidate claiming more LLM calls than maxLlmCalls is invalid. The
  # runner cannot observe the component's calls directly: this rejects an
  # over-budget report but cannot prevent unreported provider spending.
  let claimedCalls = cand{"provenance"}{"llmCalls"}.getInt(0)
  if claimedCalls > cfg.maxLlmCalls:
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "compact:invalid",
                            "detail": "auxiliary call budget exceeded: " &
                              $claimedCalls & " claimed > " &
                              $cfg.maxLlmCalls & " granted"})
    result.reason = "compactor exceeded its auxiliary LLM-call budget"
    result.detail = $claimedCalls & " claimed > " &
      $cfg.maxLlmCalls & " granted"
    return
  if coveredFrom < 1 or cutIdx <= coveredFrom:
    result.reason = "compactor selected an invalid covered range"
    return
  # Covered nodes must still be byte-identical to the persisted snapshot.
  # A concurrent steer may append outside the cut, but replacement never
  # installs over a changed covered span (§6.1).
  for i in coveredFrom ..< cutIdx:
    if manifest[i]{"contentHash"}.getStr("") != contentDigest($messages[i]):
      if onEvent != nil:
        onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                              "reason": "compact:stale"})
      result.reason = "compaction snapshot became stale"
      return

  # Candidate boundaries name projection nodes; durable coverage must name
  # canonical messages. In particular, a legal checkpoint-only cut cannot
  # persist #ckN as covered.to: that checkpoint is superseded by this put.
  let recordFrom = if p.nodes[coveredFrom].source == nsCheckpoint:
                     previousProjection{"covered"}{"from"}.getStr("")
                   else: ids[coveredFrom]
  let recordTo = if p.nodes[cutIdx - 1].source == nsCheckpoint:
                   previousProjection{"covered"}{"to"}.getStr("")
                 else: ids[cutIdx - 1]
  if not recordFrom.startsWith(p.convId & ":") or
      not recordTo.startsWith(p.convId & ":"):
    result.reason = "compactor boundary does not resolve to canonical history"
    return
  let newGeneration = p.generation + 1
  let rendered = renderCheckpoint(checked.checkpoint, newGeneration,
                                  recordFrom, recordTo)
  let coveredTokens = estimateTokens(messages[coveredFrom ..< cutIdx])
  let renderedTokens = estimateTokens(@[%*{"role": "user", "content": rendered}])
  if not strictlyReduces(coveredTokens, renderedTokens):
    if onEvent != nil:
      onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                            "reason": "compact:invalid",
                            "detail": "checkpoint does not strictly reduce the covered span"})
    result.reason = "checkpoint does not strictly reduce the covered span"
    return

  var retained: seq[string]
  for i in 1 ..< p.nodes.len:
    if (i < coveredFrom or i >= cutIdx) and
        p.nodes[i].source == nsCanonical:
      retained.add(p.nodes[i].id)
  var pruneJson = newJArray()
  for pr in p.prunes:
    if pr.id in retained:
      var refSource = "canonical"
      for i, n in p.nodes:
        if n.id == pr.id and i < messages.len and
            messages[i]{"content"}.getStr("").contains(
              "\"source\": \"spill\""):
          refSource = "spill"
          break
      pruneJson.add(%*{"ref": {"source": refSource, "id": pr.id},
                       "bytesBefore": pr.bytesBefore,
                       "bytesAfter": pr.bytesAfter})
  let record = buildProjectionRecord(newGeneration, p.canonicalHigh,
    checked.checkpoint, recordFrom, recordTo, retained, pruneJson,
    %*{"promptTokensBefore": estimateTokens(messages),
       "promptTokensAfter": estimateTokens(messages) - coveredTokens + renderedTokens,
       "coveredTokens": coveredTokens, "checkpointTokens": renderedTokens},
    %*{"tool": cfg.tool, "attemptId": attemptId, "trigger": trigger,
       "llmCalls": cand{"provenance"}{"llmCalls"}.getInt(0),
       "model": cand{"provenance"}{"model"}.getStr("")})
  try:
    let old = ct.storeGetItem("context_projection", p.convId)
    if old.value != nil and old.value{"generation"}.getInt(-1) != p.generation:
      result.reason = "projection generation changed before commit"
      return
    if old.value == nil and p.generation != 0:
      result.reason = "projection disappeared before commit"
      return
    discard ct.storePutRev("context_projection", p.convId, record,
                           expectRev = old.rev)
  except CatchableError as e:
    echo "core: WARNING compaction projection commit failed: " & e.msg
    result.reason = "compaction projection commit failed"
    result.detail = e.msg
    return

  # Commit order matters: only an acknowledged projection put authorizes the
  # in-memory replacement. A crash before the put reloads canonical; a crash
  # after it reloads this checkpoint (§8 durability fixture).
  var retainedMessages: seq[JsonNode] = @[messages[0]]
  var retainedNodes: seq[CtxNode] = @[
    CtxNode(source: nsSystem, id: "", projectionIndex: 0)]
  retainedMessages.add(%*{"role": "user", "content": rendered})
  retainedNodes.add(CtxNode(source: nsCheckpoint,
    id: p.convId & "#ck" & $newGeneration, projectionIndex: 1))
  for i in 1 ..< p.nodes.len:
    if i >= coveredFrom and i < cutIdx: continue
    # An older checkpoint is merged by the component and superseded by the
    # new generation. Canonical retained entries remain in canonical order.
    if p.nodes[i].source == nsCheckpoint: continue
    retainedMessages.add(messages[i])
    var n = p.nodes[i]
    n.projectionIndex = retainedMessages.high
    retainedNodes.add(n)
  messages = retainedMessages
  p.nodes = retainedNodes
  p.prunes = p.prunes.filterIt(it.id in retained)
  p.generation = newGeneration
  p.reindexNodes()
  p.contextUsed = 0
  p.promptTokens = 0
  p.ctxWarned = false
  if onEvent != nil:
    onEvent("context", %*{"sessionId": p.convId, "turnId": turnId,
                          "reason": "reset:compact",
                          "generation": newGeneration,
                          "covered": record{"covered"},
                          "beforeTokens": record{"measurements"}{"promptTokensBefore"},
                          "afterTokens": record{"measurements"}{"promptTokensAfter"}})
  result.status = casCompacted
  result.reason = "compacted"

proc runTurn*(ct: CoreTools, p: var Persister, messages: var seq[JsonNode],
              modelOverride: string,
              exposure: var ToolExposure,
              onEvent: proc(kind: string, data: JsonNode) {.closure.} = nil,
              thinkingEffort = "", turnContent = "", workspace = "",
              maxRounds = 0, maxCalls = 0, maxTokens = 0,
              limitRounds = 0, limitTokens = 0, limitSeconds = 0,
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
  ## turnContent is the user request that started this turn
  ## (ev.session.<id>.turn).
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
    ct.nested.leases = initTable[string, NestedLease]()
  defer:
    if ct.nested != nil:
      ct.nested.session = ""
      ct.nested.workspace = ""
      # clear ALL leases: when the turn ends, every session-context call it
      # started is over, and a stale lease is worthless (a leaked lease would
      # keep the nested proxy answerable with it)
      ct.nested.leases = initTable[string, NestedLease]()
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
  var emptyRounds = 0
    ## Consecutive rounds whose reply carried neither content nor tool calls
    ## (the guard at the end of the round loop below): re-asked a bounded
    ## number of times, then reported as a turn error.
  var toolCallsMade = 0
    ## Dispatches this turn, across all rounds: a per-turn call budget is
    ## distinct from the round budget because one LLM round may emit several
    ## tool_calls.
  var turnTokens = 0
    ## Cumulative tokens this turn (total_tokens per round when the provider
    ## reports usage) — the per-job token budget checks this before each new
    ## LLM round, so overshoot is bounded by one round.
  # Effective round budget: an explicit per-session maxRounds (1 through the
  # configured NIF_MAX_TURN_ROUNDS) may narrow the hard ceiling, but can never
  # raise it. The default is intentionally high enough that ordinary turns
  # are not shaped by it; it remains a final runaway/cost guard.
  let envMaxRounds = configuredMaxTurnRounds()
  let effMaxRounds = if maxRounds > 0: min(maxRounds, envMaxRounds)
                      else: envMaxRounds
  # An empty completion (no content, no tool calls) is not an answer — it is
  # re-asked this many times before the turn fails as an explicit error.
  # NIF_EMPTY_REPLY_RETRIES=0 disables the re-ask (fail immediately).
  let emptyReplyRetries = block:
    try: parseInt(getEnv("NIF_EMPTY_REPLY_RETRIES", "2"))
    except CatchableError: 2
  # ---- conversation controls: the human's soft turn limits (/limit) --------
  # A soft limit is different in kind from the budgets above: reaching it asks
  # the human over the approval transport (tool "turn-limit", purpose
  # "continue") instead of ending the turn, and a yes extends THAT limit by one
  # more step so the question can come back later. The job-scoped and env caps
  # stay hard and never ask — a subagent cannot negotiate its own budget, and
  # NIF_MAX_TURN_ROUNDS is a runaway guard, not a conversation setting. Denied,
  # unanswered or unreachable resolves to the same turn end the limit would have
  # caused anyway (fail closed; see docs/WIRE.md "Conversation controls").
  let turnStarted = epochTime()
  var softRounds = limitRounds
  var softTokens = limitTokens
  var softSeconds = limitSeconds
  var humanContinues = 0
    ## How often the human extended a limit this turn (diagnostics only).

  proc limitExhausted(dimension, detail: string): bool =
    ## One soft-limit breach: ask whether the turn may keep going. Granted →
    ## raise that limit by one step and return false (keep going); denied,
    ## unanswered or no client reachable → true, so the caller ends the turn.
    if ct.approval == nil: return true
    if not ct.approval.askContinue(dimension, detail): return true
    inc humanContinues
    case dimension
    of "rounds": softRounds += max(limitRounds, 1)
    of "tokens": softTokens += max(limitTokens, 1)
    of "seconds": softSeconds += max(limitSeconds, 1)
    else: discard
    echo "core: turn " & dimension & " limit continued by the human (" &
         detail & ")"
    false

  proc limitMessage(dimension, detail: string): string =
    ## The transcript record when a human limit ended the turn: which limit,
    ## where it stood, and the one command that raises it. The dimension is
    ## named as /limit names it, inside the detail.
    "turn limit reached (" & detail & ") — the human declined to continue; " &
      "raise it with /limit " & dimension & "=<n> and send a follow-up message"

  proc endTurnOnLimit(p: var Persister, turnError: var string,
                      dimension, detail, msg: string) =
    ## End the turn at a human limit the human declined to extend — the same
    ## shape as the hard budget endings, with a distinct error kind so the
    ## model and a driver can tell a limit from a failure. `p`/`turnError` are
    ## passed in rather than captured: both are `var` parameters of runTurn,
    ## which a closure may not capture (memory safety).
    turnError = msg
    p.persistMsg(%*{"role": "error", "content": msg,
                    "error": "limit-" & dimension, "turnId": turnId},
                 %*{"limit": detail})
    if onEvent != nil:
      onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                         "error": msg})
    emitTurnDone(msg)

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
    # The human's soft limits (rounds/tokens/seconds), checked before the next
    # LLM round for exactly the reason the hard caps are: no further round
    # starts on a limit the human is not going to extend.
    if softRounds > 0 and rounds > softRounds:
      let detail = $rounds & " LLM rounds (limit " & $softRounds & ")"
      if limitExhausted("rounds", detail):
        let msg = limitMessage("rounds", detail)
        endTurnOnLimit(p, turnError, "rounds", detail, msg)
        return ""
    if softTokens > 0 and turnTokens >= softTokens:
      let detail = $turnTokens & " tokens (limit " & $softTokens & ")"
      if limitExhausted("tokens", detail):
        let msg = limitMessage("tokens", detail)
        endTurnOnLimit(p, turnError, "tokens", detail, msg)
        return ""
    if softSeconds > 0 and epochTime() - turnStarted >= softSeconds.float:
      let detail = $int(epochTime() - turnStarted) & "s (limit " &
                   $softSeconds & "s)"
      if limitExhausted("seconds", detail):
        let msg = limitMessage("seconds", detail)
        endTurnOnLimit(p, turnError, "seconds", detail, msg)
        return ""
    # Fold any steering messages the client injected mid-turn into the running
    # conversation before the next LLM call (Pi-style steering), plus any
    # accepted advisor messages (pumpAdvise). Admission runs AFTER the drains:
    # it must measure the whole candidate request, steering included (§6.1).
    discard drainSteer(ct, p, messages, onEvent, turnId)
    drainMap(ct, p, messages, onEvent)
    drainDiagnostics(ct, p, messages, onEvent)
    discard drainAdvisories(ct, p, messages, onEvent, turnId)
    discard drainNotices(ct, p, messages, onEvent, turnId)
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
    let toolsJson = promptToolsJson.formatToolsForLlm()
    let toolTokens = ($toolsJson).len div 4
    # Admission (§6.1/§6.3): lossless prune runs first. At pressure a
    # configured replaceable compactor gets the next chance; only a decline,
    # invalid answer, timeout or still-oversized checkpoint falls through to
    # lossy trim. Never send a request the measured target cannot hold.
    var verdict = checkContext(p, messages, onEvent, turnId, toolTokens)
    if verdict.startsWith("pressure:"):
      let ccfg = compactionConfigFromEnv()
      if ccfg.tool.len > 0 and ct.cat.toolSchema(ccfg.tool) != nil:
        discard attemptCompaction(ct, p, messages, promptToolsJson, onEvent,
                                  turnId, "pressure", resolvedProvider,
                                  selectedModel, ccfg)
        # Steering/advice received while the auxiliary call was in flight is
        # append-only history. Fold it in after settlement and re-admit the
        # complete candidate before either trim or provider dispatch (§6.1).
        discard drainSteer(ct, p, messages, onEvent, turnId)
        drainMap(ct, p, messages, onEvent)
        drainDiagnostics(ct, p, messages, onEvent)
        discard drainAdvisories(ct, p, messages, onEvent, turnId)
        verdict = checkContext(p, messages, onEvent, turnId, toolTokens)
      if verdict.startsWith("pressure:"):
        runTrimRung(p, messages, toolTokens, onEvent, turnId)
        verdict = checkContext(p, messages, onEvent, turnId, toolTokens)
    if verdict.len > 0:
      let detail = if verdict.startsWith("pressure:"):
                     verdict["pressure:".len .. ^1]
                   else: verdict
      let recovery = if detail.startsWith("context-recovery-required:"):
                       detail
                     else: "context-recovery-required: " & detail
      p.persistMsg(%*{"role": "error", "content": recovery,
                      "error": "context-recovery-required", "turnId": turnId})
      turnError = recovery
      if onEvent != nil:
        onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                           "error": recovery})
      emitTurnDone(recovery)
      return recovery
    var llmArgs = %*{"messages": messages,
                     "tools": toolsJson,
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
    # §6.5: one logical request = one provider call target (transient backoff
    # retries stay inside it). The overflow-recovery attempt is per logical
    # request, independent of the transient budget.
    let requestId = newId()
    var overflowRecovered = false
    let retryPolicy = retryPolicyFromEnv()
    while true:
      var failMsg = ""
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
        let klass = classifyLlmError(e.msg)
        if cancelled:
          failMsg = "cancelled by request"
        elif klass == lfcOverflow and not overflowRecovered:
          # §6.5 bounded overflow recovery: the adapter normalized the
          # failure to a stable class (no substring guessing here); write
          # the receipt, reduce, and retry the same logical request exactly
          # once. dsh's rule: durable progress authorizes the retry.
          overflowRecovered = true
          writeContextReceipt(p, requestId, "context-overflow", "attempted",
                              e.msg)
          let beforeOverflow = estimateTokens(messages) + toolTokens
          if p.ctxSize <= 0:
            let window = windowFromOverflow(e.msg)
            if window > 0:
              p.ctxSize = window
              p.ctxWarned = false
          # Unknown capacity and a refusal that carries no parseable window:
          # admission stands down, so checkContext below would pass the
          # candidate unchanged and the retry would be byte-identical — a
          # wasted call against a provider that just refused it. Reduce
          # blind instead: lossless prune, then trim to the newest request.
          # The single retry only goes out if the candidate actually shrank;
          # an irreducible candidate (frozen prefix over an unknown window)
          # ends terminal — never resend what was refused unchanged.
          if p.ctxSize <= 0:
            let before = estimateTokens(messages) + toolTokens
            discard p.pruneContext(messages)
            discard p.trimTurns(messages, 1)
            if estimateTokens(messages) + toolTokens >= before:
              writeContextReceipt(p, requestId, "context-overflow", "terminal",
                                  e.msg)
              failMsg = "context-recovery-required: provider refused the request (" &
                        e.msg & ") and the candidate cannot be reduced " &
                        "(capacity unknown, no parseable window)"
          var overflowVerdict =
            checkContext(p, messages, onEvent, turnId, toolTokens)
          if overflowVerdict.startsWith("pressure:"):
            let ccfg = compactionConfigFromEnv()
            if ccfg.tool.len > 0 and ct.cat.toolSchema(ccfg.tool) != nil:
              discard attemptCompaction(ct, p, messages, promptToolsJson,
                                        onEvent, turnId, "overflow",
                                        resolvedProvider, selectedModel, ccfg)
              discard drainSteer(ct, p, messages, onEvent, turnId)
              drainMap(ct, p, messages, onEvent)
              drainDiagnostics(ct, p, messages, onEvent)
              discard drainAdvisories(ct, p, messages, onEvent, turnId)
              overflowVerdict =
                checkContext(p, messages, onEvent, turnId, toolTokens)
            if overflowVerdict.startsWith("pressure:"):
              runTrimRung(p, messages, toolTokens, onEvent, turnId)
              overflowVerdict =
                checkContext(p, messages, onEvent, turnId, toolTokens)
          if overflowVerdict.len == 0:
            if failMsg.len == 0 and
                estimateTokens(messages) + toolTokens >= beforeOverflow:
              # The candidate fits the known window yet the provider refused
              # it: the refusal cannot come from the message size alone (a
              # counted completion budget, a stricter real limit than the
              # declared window). Never resend what was refused unchanged —
              # the retry would be byte-identical and refuse again.
              writeContextReceipt(p, requestId, "context-overflow", "terminal",
                                  e.msg)
              failMsg = "context-recovery-required: provider refused the request (" &
                        e.msg & ") and the candidate could not be reduced " &
                        "below the window"
            elif failMsg.len == 0:
              if onEvent != nil:
                onEvent("retry", %*{"sessionId": sessionId, "turnId": turnId,
                                   "reason": "context-overflow",
                                   "error": e.msg})
              # the projection changed under the snapshot — rebuild the body
              llmArgs["messages"] = %messages
              llmArgs["tools"] = promptToolsJson.formatToolsForLlm()
              continue
          if failMsg.len == 0:
            writeContextReceipt(p, requestId, "context-overflow", "terminal",
                                e.msg)
            failMsg = "context-recovery-required: provider refused the request (" &
                      e.msg & ") and the fallback ladder could not reduce it " &
                      "below the window"
        elif klass == lfcTransient and canRetry(retryPolicy, e.msg, attempt):
          # Retry budgets are independent: hinted rate limits wait exactly as
          # requested (up to the local cap), while stream timeouts and refused
          # connections consume their own bounded counters. A hinted 429 has
          # no attempt cap; the retry event exposes that fact as -1.
          let hintMs = retryAfterMs(e.msg)
          let delayMs = retryDelayMs(retryPolicy, attempt, hintMs)
          let failureKind = retryKind(e.msg)
          let budget = case failureKind
                       of rkRateLimitHint: -1
                       of rkStreamTimeout: retryPolicy.maxStreamRetries
                       of rkConnectRefused: retryPolicy.maxConnectRetries
                       else: retryPolicy.maxRetries
          if onEvent != nil:
            onEvent("retry", %*{"sessionId": sessionId, "turnId": turnId,
                               "attempt": attempt + 1,
                               "maxRetries": budget,
                               "delayMs": delayMs,
                               "retryAfterMs": hintMs,
                               "budget": $failureKind,
                               "error": e.msg})
          sleep(delayMs)
          attempt += 1
          continue
        else:
          if klass == lfcOverflow:
            # the recovery retry itself overflowed again — terminal, persisted
            writeContextReceipt(p, requestId, "context-overflow", "terminal",
                                e.msg)
          failMsg = "llm error: " & e.msg
      if failMsg.len > 0:
        let durationMs = (getMonoTime() - llmStarted).inMilliseconds
        p.persistMsg(%*{"role": "error", "content": failMsg,
                        "error": "llm", "turnId": turnId},
                     %*{"startedAt": llmStartedAt,
                        "durationMs": durationMs})
        turnError = failMsg
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": failMsg})
        emitTurnDone(failMsg)
        return failMsg
    if overflowRecovered:
      # the retried logical request succeeded — close out the receipt (§6.5)
      writeContextReceipt(p, requestId, "context-overflow", "recovered", "")
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
      # Re-measure the calibration offset on every response: what the
      # provider counted for THIS request minus what chars/4 estimated for
      # it. `messages` is still exactly the sent projection here, so the
      # pair is honest. The next admission then measures the candidate as
      # estimate + calib — the provider's own scale — instead of the raw
      # proxy that lagged a DeepSeek-class tokenizer by ~22k tokens on a
      # 524k window (observed: the 90% trim line silently became a ~99%
      # line and a request the core called 86% was refused at 400).
      # Clamped to [0, ctxSize]: never negative (the raw estimate stays
      # the conservative fallback), never past the window itself.
      block:
        let sentEst = estimateTokens(messages) + toolTokens
        p.calib = max(0, min(p.promptTokens - sentEst, max(p.ctxSize, 1)))
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
      # (ev.session.<id>.context carries the reset reason when we know one).
      if p.cachePrompt > 0:
        statusEv["cache"] = %*{"prompt": p.cachePrompt, "read": p.cacheRead,
                               "hitRate": round(float(p.cacheRead) * 100.0 /
                                                float(p.cachePrompt), 1)}
      onEvent("status", statusEv)
    let toolCalls = resp{"tool_calls"}
    let hasToolCalls = toolCalls != nil and toolCalls.kind == JArray and
                       toolCalls.len > 0
    if content.len > 0 or hasToolCalls:
      emptyRounds = 0   # a real round: the empty-reply streak is broken
      let assistantMsg = %*{"role": "assistant",
                            "content": (if content.len > 0: %content else: newJNull())}
      if reasoning.len > 0: assistantMsg["reasoning"] = %reasoning
      if hasToolCalls: assistantMsg["tool_calls"] = toolCalls
      if usedProvider.len > 0: assistantMsg["provider"] = %usedProvider
      if usedModel.len > 0: assistantMsg["model"] = %usedModel
      if ctxSize > 0: assistantMsg["context"] = %ctxSize
      if usageObj.len > 0: assistantMsg["usage"] = usageObj
      ctxAppend(p, messages, assistantMsg,
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
      # Settlement notices do the same by default (dsh's inbox semantics): a
      # child that finished during this step is folded as the turn's next step
      # — the turn cannot close over it — and every notice waiting in the two
      # lanes folds in ONE drain, so a burst of settlements costs one extra
      # step, not one per child. NIF_AGENT_NOTICE_HOLD=0 disables only this
      # hold; the notices stay pending for the next turn's opening drain.
      var noticesFolded = 0
      if noticeHoldEnabled():
        noticesFolded = drainNotices(ct, p, messages, onEvent, turnId)
      if drainSteer(ct, p, messages, onEvent, turnId) +
          drainAdvisories(ct, p, messages, onEvent, turnId) +
          noticesFolded > 0:
        continue
      # An empty completion is not an answer, and accepting one as the final
      # reply ends the turn silently — a real bench cell (vuejs/core-11739)
      # spent 29 minutes and then reported "candidate patch is empty", as if
      # the model had patched badly. Two shapes reach here:
      #   * the provider cut the reply at its output cap before producing any
      #     content (finish_reason "length" — a thinking model can spend the
      #     whole budget on reasoning): re-asking repeats it, so the turn ends
      #     with an explicit error instead;
      #   * a 200 whose generation produced nothing (DeepSeek's "aborted" and
      #     "insufficient_system_resource" already arrive as transient stream
      #     errors from the llm component, but a bare empty stop exists too):
      #     re-ask the same request.
      # The re-ask appends nothing — the frozen prefix and its cache are
      # untouched — and nothing is said to the model: a provider hiccup is not
      # the model's mistake.
      let emptyFinish = resp{"finish_reason"}.getStr("")
      if content.len == 0 and emptyFinish == "length":
        let msg = "the provider cut the reply at the output cap before any " &
                  "content (finish_reason=length)"
        p.persistMsg(%*{"role": "error", "content": msg,
                        "error": "empty-reply", "turnId": turnId},
                     %*{"startedAt": llmStartedAt,
                        "durationMs": (getMonoTime() - llmStarted).inMilliseconds})
        turnError = msg
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": msg})
        emitTurnDone(msg)
        return ""
      if content.len == 0 and emptyRounds < emptyReplyRetries:
        inc emptyRounds
        if onEvent != nil:
          onEvent("status", %*{"sessionId": sessionId, "turnId": turnId,
                               "emptyReply": emptyRounds,
                               "finishReason": emptyFinish})
        continue
      if content.len == 0:
        let msg = "the provider returned " & $(emptyRounds + 1) &
                  " empty responses in a row (no content, no tool calls" &
                  (if emptyFinish.len > 0: ", finish_reason=" & emptyFinish
                   else: "") & ")"
        p.persistMsg(%*{"role": "error", "content": msg,
                        "error": "empty-reply", "turnId": turnId},
                     %*{"startedAt": llmStartedAt,
                        "durationMs": (getMonoTime() - llmStarted).inMilliseconds})
        turnError = msg
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": msg})
        emitTurnDone(msg)
        return ""
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
      # The human's time limit is checked before every dispatch, not only at
      # round boundaries: one bash call can outlast a whole round, and the
      # point of the limit is to put the question at the moment it is reached.
      if softSeconds > 0 and epochTime() - turnStarted >= softSeconds.float:
        let detail = $int(epochTime() - turnStarted) & "s (limit " &
                     $softSeconds & "s)"
        if limitExhausted("seconds", detail):
          let msg = limitMessage("seconds", detail)
          # The assistant batch is already persisted: pair every unexecuted
          # call with an error result so the history stays provider-valid.
          for k in idx ..< items.len:
            commitToolItem(ct, p, messages, exposure, onEvent, sessionId,
              turnId, items[k], ToolCallOutcome(error: msg), epochTime(), 0)
          endTurnOnLimit(p, turnError, "seconds", detail, msg)
          return ""
      if maxCalls > 0 and toolCallsMade >= maxCalls:
        let msg = "turn tool-call budget exhausted (" & $maxCalls &
          " tool calls)"
        # The assistant batch is already persisted. Pair every unexecuted
        # call with an error result so follow-up turns and resumes remain
        # valid for providers that require complete tool-call pairing.
        for k in idx ..< items.len:
          commitToolItem(ct, p, messages, exposure, onEvent, sessionId,
            turnId, items[k], ToolCallOutcome(error: msg), epochTime(), 0)
        turnError = msg
        if onEvent != nil:
          onEvent("done", %*{"sessionId": sessionId, "turnId": turnId,
                             "error": msg})
        emitTurnDone(msg)
        return ""
      # A wave is a maximal run of consecutive parallel-safe calls, bounded
      # by the remaining budget. Serial calls and parse failures run alone.
      var wave: seq[tuple[id, name: string, args: JsonNode]] = @[]
      while idx < items.len and isParallelSafeTool(ct, items[idx].name) and
          not items[idx].parseFailed and
          (maxCalls <= 0 or toolCallsMade < maxCalls):
        wave.add((items[idx].id, items[idx].name, items[idx].args))
        inc idx
        inc toolCallsMade
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
      inc toolCallsMade  # every dispatch attempt counts, success or error
      let toolStartedAt = epochTime()
      let toolStarted = getMonoTime()
      var oc: ToolCallOutcome
      if it.parseFailed:
        oc = ToolCallOutcome(error:
          "tool call arguments were not valid JSON (truncated or garbled stream): " &
          it.rawArgs[0 ..< min(it.rawArgs.len, 200)])
      else:
        try:
          let value = ct.dispatchToolCall(it.name, it.args)
          if value != nil and value{"__toolError"}.getBool(false):
            oc = ToolCallOutcome(ok: false, value: value,
                                 error: value{"error"}.getStr("tool failed"))
          else:
            oc = ToolCallOutcome(ok: true, value: value)
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
  ## A conversation workspace is immutable and persisted in the header so
  ## resumed runners resolve context and paths exactly as the original turn
  ## did. Any existing directory on the machine is allowed: NIF_ROOT is only
  ## the default (and the base for relative requests). The harness root is
  ## the installation/runtime home, not a sandbox for conversation workspaces.
  if requested.strip().len == 0:
    return (true, root, "")
  let candidate = normalizedPath(
    if requested.isAbsolute(): requested else: root / requested)
  if not dirExists(candidate):
    return (false, "", "cwd is not a directory: " & requested)
  (true, candidate, "")

proc handleSessionCall*(ct: CoreTools, args: JsonNode,
                         sessions: var Table[string, Session],
                         caller = ""): JsonNode =
  ## session {sessionId, content?, model?}: run one turn or persist a model
  ## selection, emitting ev.session.<id>.* events. Session state is rebuilt from
  ## the store on first use (resume). caller is the self-declared component
  ## name from the call envelope — the interactive component driving this
  ## session; approvals raised by the turn are routed to it.
  let sessionId = args{"sessionId"}.getStr("")
  let content = args{"content"}.getStr("")
  # Autonomous wake (components/agent settle path): a session call with
  # `wake: true` runs a turn whose only purpose is folding pending
  # background-settlement notices into an IDLE conversation — the parent
  # learns subagents finished without the human having to ask. Admission
  # happens below once entry.messages is loaded; a declined wake runs no
  # turn and persists nothing.
  let isWake = args{"wake"}.getBool(false)
  var turnContent = content
  let hasModel = args.kind == JObject and args.hasKey("model")
  let hasThinking = args.kind == JObject and args.hasKey("thinking")
  let hasTitle = args.kind == JObject and args.hasKey("title")
  let hasCwd = args.kind == JObject and args.hasKey("cwd")
  let hasProfile = args.kind == JObject and args.hasKey("profile")
  let hasDiscovery = args{"discovery"} != nil and args{"discovery"}.kind == JObject
  let hasExport = args.kind == JObject and args.hasKey("export") and
                  args{"export"}.getBool(false)
  # Conversation controls (docs/WIRE.md "Conversation controls"): the human's
  # gate mode and soft turn limits. Both are mutable per conversation — unlike
  # the frozen job-scoping args below — and both are accepted on a call with no
  # content (a control call runs no inference).
  let hasApprovals = args.kind == JObject and args.hasKey("approvals")
  let hasLimits = args.kind == JObject and args.hasKey("limits")
  # Manual compaction (/compact): the human's explicit request for the same
  # replaceable-compactor rung the automatic ladder runs at pressure. Rides a
  # content-less control call like the other conversation controls.
  let hasCompact = args.kind == JObject and args.hasKey("compact") and
                   args{"compact"}.getBool(false)
  # A call carrying only a sessionId is the read-only status readback — how a
  # UI shows a conversation's model/thinking/approvals/limits without running
  # a turn. Anything else without content needs one of the keys above.
  if sessionId.len == 0:
    return %*{"error": "session needs sessionId"}

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
    # Announce the workspace (any directory — a conversation workspace need
    # not be a git repo) so components can pre-warm against it; e.g. the lsp
    # component starts servers for the languages present at bootstrap, not
    # mid-turn. Fire-and-forget: warmup failures must never fail discovery.
    try:
      ct.nc.publish("ev.workspace.opened",
        Envelope(v: 1, id: newId(), kind: ekEvent,
                 payload: %*{"workspace": entry.workspace,
                             "conversationId": sessionId}).encode())
    except CatchableError as e:
      echo "core: WARNING workspace.opened publish failed: " & e.msg
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
    # Conversation controls ride the same header: they are mutable (the human
    # may change them at any point) but must survive a runner resume, so a
    # restarted runner re-applies exactly what the human last chose.
    entry.approvalMode = header{"approvals"}.getStr("")
    let storedLimits = header{"limits"}
    if storedLimits != nil and storedLimits.kind == JObject:
      entry.limitRounds = storedLimits{"rounds"}.getInt(0)
      entry.limitTokens = storedLimits{"tokens"}.getInt(0)
      entry.limitSeconds = storedLimits{"seconds"}.getInt(0)
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
      if mr >= 1 and mr <= configuredMaxTurnRounds():
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
    # §6.2 reload: a valid projection is the durable source of truth for
    # the provider view. Read it before paging canonical history so the
    # covered span can be skipped at the store cursor rather than loaded and
    # heuristically re-trimmed. A malformed/dangling projection is explicit
    # recovery-required — silently falling back would resurrect covered
    # history and can overflow immediately after restart.
    sweepCompactionSnapshots(ct, sessionId)
    var projection: JsonNode
    try:
      projection = ct.storeGetItem("context_projection", sessionId).value
    except CatchableError as e:
      return %*{"error": "context-recovery-required: cannot read context projection: " & e.msg}
    var stored: seq[JsonNode]
    var storedNodes: seq[CtxNode]
    var lastSeqNo = 0
    let projectedHigh = if projection != nil:
                          projection{"canonicalHigh"}.getInt(0)
                        else: 0
    if projection != nil:
      if projection.kind != JObject or projection{"version"}.getInt(0) != 1 or
          projection{"renderer"}.getStr("") != rendererId or
          projection{"generation"}.getInt(0) < 1 or projectedHigh < 1 or
          projection{"checkpoint"} == nil or
          projection{"checkpoint"}.kind != JObject:
        return %*{"error": "context-recovery-required: context projection is malformed or uses an unsupported renderer"}
      let coveredTo = projection{"covered"}{"to"}.getStr("")
      if coveredTo.len == 0 or ct.storeGetItem("message", coveredTo).value == nil:
        return %*{"error": "context-recovery-required: context projection covered.to does not resolve: " & coveredTo}
      let coveredSeq = canonicalSeqOf(coveredTo)
      if coveredSeq <= 0 or coveredSeq > projectedHigh:
        return %*{"error": "context-recovery-required: context projection canonicalHigh is inconsistent with covered.to"}
      # Retained is authoritative and may include canonical prefix nodes
      # before a middle-span autonomous cut. Resolve it exactly, in canonical
      # order, without reading the covered range into provider context.
      let retainedNode = projection{"retained"}
      if retainedNode == nil or retainedNode.kind != JArray or retainedNode.len == 0:
        return %*{"error": "context-recovery-required: context projection has no retained canonical tail"}
      var previousSeq = 0
      for idNode in retainedNode:
        let id = idNode.getStr("")
        let seqNo = canonicalSeqOf(id)
        if id.len == 0 or seqNo <= previousSeq or seqNo > projectedHigh:
          return %*{"error": "context-recovery-required: context projection has an invalid or unordered retained ref"}
        let v = ct.storeGetItem("message", id).value
        if v == nil or v{"role"}.getStr("") == "error":
          return %*{"error": "context-recovery-required: retained projection ref does not resolve to a provider message: " & id}
        storedNodes.add(CtxNode(source: nsCanonical, id: id,
          canonicalSeq: seqNo, projectionIndex: stored.len))
        stored.add(providerMessage(v))
        recoverUsage(v, pt, used, cs)
        previousSeq = seqNo
      # A legal cut keeps a non-empty tail, so the final retained canonical
      # id is the commit's high-water mark. This proves canonicalHigh does
      # not point beyond stored history without replaying covered documents.
      if previousSeq != projectedHigh:
        return %*{"error": "context-recovery-required: context projection canonicalHigh is beyond its retained history"}
      # Canonical appends after the projection commit are a separate paged
      # range (§6.2/§6.4); they are not part of the retained checksum/list.
      let highKey = sessionId & ":" & align($projectedHigh, 6, '0')
      let appended = loadStoredMessagesEx(ct, sessionId, pt, used, cs,
                                           after = highKey)
      let base = stored.len
      for m in appended.messages: stored.add(m)
      for i, node0 in appended.nodes:
        var node = node0
        node.projectionIndex = base + i
        storedNodes.add(node)
      lastSeqNo = max(projectedHigh, appended.lastSeqNo)
      let generation = projection{"generation"}.getInt(0)
      let rendered = renderCheckpoint(projection{"checkpoint"}, generation,
        projection{"covered"}{"from"}.getStr(""), coveredTo)
      entry.messages.add(%*{"role": "user", "content": rendered})
    else:
      let ordinary = loadStoredMessagesEx(ct, sessionId, pt, used, cs)
      stored = ordinary.messages
      storedNodes = ordinary.nodes
      lastSeqNo = ordinary.lastSeqNo
      # §6.3 durable trim: a lossy trim records the canonical seqNo it cut
      # through (header trimThrough). The dropped turns remain in canonical
      # history (recall-canonical still reaches them) but are not part of
      # the live projection — without this, a restart would rebuild the
      # full pre-trim context while the meter restores the post-trim
      # usage, and admission would wave the re-inflated request straight
      # through to the provider.
      let trimThrough = header{"trimThrough"}.getInt(0)
      if trimThrough > 0:
        var keptM: seq[JsonNode] = @[]
        var keptN: seq[CtxNode] = @[]
        for i, m in stored:
          let n = storedNodes[i]
          # The system node has no canonical id and is never trimmed.
          if n.source == nsCanonical and n.canonicalSeq <= trimThrough:
            continue
          keptM.add(m)
          keptN.add(n)
        if keptM.len < stored.len:
          stored = keptM
          storedNodes = keptN
    for m in stored: entry.messages.add(m)
    # A2/A3: usage and cumulative cache counters persist in the header
    # (written by persistConversationRuntime), so the context meter and
    # cache metrics survive a runner restart. seqNo continues after the
    # highest stored id (not the loaded count — error-role records are
    # excluded from the list but own ids the next persist must not reuse).
    var p = Persister(
      ct: ct, convId: sessionId, seqNo: max(lastSeqNo, projectedHigh),
      promptTokens: pt, contextUsed: used, ctxSize: cs,
      cachePrompt: header{"cachePrompt"}.getInt(0),
      cacheRead: header{"cacheRead"}.getInt(0),
      generation: (if projection != nil:
                     projection{"generation"}.getInt(0) else: 0))
    # Seed the calibration offset from stored usage: the last assistant
    # message's prompt_tokens measures what the provider counted for the
    # retained projection, so estimate-vs-provider lag is known BEFORE the
    # first response of the session (a restart at 91% context must not
    # re-walk into the overflow blind spot). The first response re-measures
    # it exactly. 0 when nothing is stored (fresh conversation).
    if pt > 0:
      # stored excludes the system prompt (it lives in the header), so add
      # its estimate back — the seed leans conservative, never under.
      p.calib = max(0, min(pt - estimateTokens(stored) -
        header{"systemPrompt"}.getStr("").len div 4, cs))
    # Context identity (§4.2): system, optional durable checkpoint, exact
    # retained canonical ids, then paged canonical appends after canonicalHigh.
    # projectionIndex is rebuilt from this actual provider projection, not
    # inferred from store offsets. The record's canonicalHigh validates its committed surface;
    # canonical messages appended after that commit are also represented and
    # advance the in-memory high-water mark before the next snapshot.
    p.nodes = @[CtxNode(source: nsSystem, id: "", projectionIndex: 0)]
    var storedOffset = 1
    if projection != nil:
      p.nodes.add(CtxNode(source: nsCheckpoint,
        id: sessionId & "#ck" & $p.generation, projectionIndex: 1))
      storedOffset = 2
    for i, n in storedNodes:
      var node = n
      node.projectionIndex = i + storedOffset
      p.nodes.add(node)
    if projection != nil:
      p.canonicalHigh = projectedHigh
      if storedNodes.len > 0:
        p.canonicalHigh = max(p.canonicalHigh, storedNodes[^1].canonicalSeq)
      let prunes = projection{"prunes"}
      if prunes != nil and prunes.kind == JArray:
        for pr in prunes:
          p.prunes.add(PruneRec(
            id: pr{"ref"}{"id"}.getStr(pr{"id"}.getStr("")),
            bytesBefore: pr{"bytesBefore"}.getInt(0),
            bytesAfter: pr{"bytesAfter"}.getInt(0)))
      # Reapply exactly the recorded projection edits. The same deterministic
      # routine verifies spill durability again; any missing ref or byte drift
      # makes the projection explicitly unrecoverable rather than quietly
      # sending a different prompt after restart.
      for pr in p.prunes:
        var idx = -1
        for i, n in p.nodes:
          if n.id == pr.id: idx = i; break
        if idx < 0 or entry.messages[idx]{"content"}.getStr("").len !=
            pr.bytesBefore or p.pruneNode(entry.messages, idx,
                                         record = false) <= 0 or
            entry.messages[idx]{"content"}.getStr("").len != pr.bytesAfter:
          return %*{"error": "context-recovery-required: projection prune ref cannot be reproduced: " & pr.id}
    elif storedNodes.len > 0:
      p.canonicalHigh = storedNodes[^1].canonicalSeq
    entry.persister = p
    # Tool profile (optional, first call only): resolved into the direct
    # toolset once, here, and frozen with the exposure doc. Resumes ignore
    # the argument entirely. An unknown profile name fails the call —
    # explicit selection must not silently fall back to the base set.
    let profileName = args{"profile"}.getStr(getEnv("NIF_PROFILE", ""))
    entry.exposure = loadToolExposure(ct, sessionId, profileName)
    ct.updateConversationHeader(sessionId, %*{"profile": entry.exposure.profile})

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
  # Conversation controls: presence of the key means set (empty `approvals`
  # clears to ask, an all-zero `limits` object clears all three). They apply
  # from the NEXT turn on and are persisted before the turn runs, so a crash
  # mid-turn cannot lose a human's choice.
  if hasApprovals:
    let mode = args{"approvals"}.getStr("").strip().toLowerAscii()
    if mode notin ["", "ask", "auto"]:
      return %*{"error": "approvals must be ask or auto (empty clears)"}
    entry.approvalMode = if mode == "auto": "auto" else: ""
    ct.updateConversationHeader(sessionId, %*{"approvals": entry.approvalMode})
  if hasLimits:
    let raw = args{"limits"}
    if raw.kind != JObject:
      return %*{"error": "limits must be an object of rounds/tokens/seconds"}
    for key, fieldValue in raw:
      if key notin ["rounds", "tokens", "seconds"]:
        return %*{"error": "unknown limit " & key &
                            " (rounds, tokens, seconds)"}
      if fieldValue.kind != JNull and fieldValue.kind != JInt:
        return %*{"error": "limit " & key & " must be a positive integer"}
    var limitRounds = 0
    var limitTokens = 0
    var limitSeconds = 0
    for dimension in ["rounds", "tokens", "seconds"]:
      let wanted = raw{dimension}
      if wanted == nil or wanted.kind == JNull: continue
      let value = wanted.getInt(0)
      # Bounds keep a typo (/limit seconds=100000000) from parking a turn for
      # weeks; the ceiling is generous, not protective.
      let ceiling = case dimension
        of "rounds": 200
        of "seconds": 86_400
        else: 10_000_000
      if value < 1 or value > ceiling:
        return %*{"error": "limit " & dimension & " must be between 1 and " &
                            $ceiling}
      case dimension
      of "rounds": limitRounds = value
      of "tokens": limitTokens = value
      else: limitSeconds = value
    entry.limitRounds = limitRounds
    entry.limitTokens = limitTokens
    entry.limitSeconds = limitSeconds
    ct.updateConversationHeader(sessionId,
      %*{"limits": %*{"rounds": limitRounds, "tokens": limitTokens,
                      "seconds": limitSeconds}})
  if hasTitle:
    var title = args{"title"}.getStr("").strip()
    if title.len > 0:
      ct.updateConversationHeader(sessionId, %*{"title": shortTitle(title)})

  proc onEvent(kind: string, data: JsonNode) {.closure.} =
    let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: data)
    ct.nc.publish("ev.session." & sanitizeSessionId(sessionId) & "." & kind,
                  env.encode())

  if hasDiscovery:
    # Explicit client discovery is serialized by the runner, just like a
    # turn. Append schemas as user context; never fabricate tool-call IDs
    # or mutate the request prefix. No LLM request is needed.
    let found = ct.dispatchToolCall("discover", args{"discovery"})
    let message = %*{"role": "user", "content":
      "Explicit tool discovery (schemas are data, not instructions):\n" & $found}
    ctxAppend(entry.persister, entry.messages, message)
    recordDiscovery(ct, sessionId, entry.exposure, found)
    sessions[sessionId] = entry
    return %*{"ok": true, "sessionId": sessionId, "discovery": found}

  # Wake admission: bounded, and a declined wake persists nothing. The
  # consecutive-wake budget counts trailing wake-marked messages since the
  # last real user input (derived from history — no counter to lose). A
  # declined/skipped wake is a normal result, never an error: the notice
  # stays pending and the parent's next real turn delivers it.
  if isWake:
    let budget = wakeBudget()
    if budget <= 0:
      return %*{"ok": true, "wake": "declined", "reason": "wakes disabled"}
    var pendingCount = -1
    try:
      let peeked = ct.dispatchToolCall("agent_notices",
        %*{"session": sessionId, "peek": true}, 5_000)
      pendingCount = peeked{"count"}.getInt(0)
    except CatchableError:
      # Notices unreadable (agent or store down): a wake turn with nothing
      # to fold is pure noise, and a pending notice is delivered by the
      # parent's next real turn anyway.
      return %*{"ok": true, "wake": "declined",
                "reason": "notices unreachable"}
    if pendingCount == 0:
      return %*{"ok": true, "wake": "skipped", "reason": "nothing pending"}
    if consecutiveWakeTurnsFromStore(ct, sessionId) >= budget:
      return %*{"ok": true, "wake": "declined", "reason": "budget",
                "budget": budget}
    if turnContent.len == 0:
      turnContent = "[wake] background subagents settled"

  if content.len == 0 and not isWake:
    if hasCompact:
      # Manual compaction: run the §6.3 replaceable-compactor rung now, with
      # no LLM turn and no user message. The attempt installs a checkpoint
      # projection and emits the same reset:compact context event the
      # automatic path does; a decline is reported, never silently degraded
      # to a lossy trim (automatic admission still owns that rung).
      let ccfg = compactionConfigFromEnv()
      if ccfg.tool.len == 0 or ct.cat.toolSchema(ccfg.tool) == nil:
        sessions[sessionId] = entry
        return %*{"ok": true, "sessionId": sessionId, "compacted": false,
                  "reason": "no compaction component available (" &
                            "NIF_COMPACTION_TOOL=" & ccfg.tool & ")"}
      var promptToolsJson = entry.exposure.promptTools()
      if entry.allowlist.len > 0:
        var filtered = newJArray()
        for tool in promptToolsJson:
          if tool{"name"}.getStr("") in entry.allowlist:
            filtered.add(tool)
        promptToolsJson = filtered
      var compactProvider = ""
      var compactModel = entry.modelOverride
      try:
        let resolved = resolveTurnConfig(ct, entry.persister,
                                         entry.modelOverride)
        compactProvider = resolved{"provider"}.getStr("")
        compactModel = resolved{"model"}.getStr(compactModel)
      except CatchableError:
        discard # older/replaced llm components still resolve chat defaults
      let beforeTokens = estimateTokens(entry.messages)
      let attempt = attemptCompaction(ct, entry.persister, entry.messages,
                                      promptToolsJson, onEvent, "", "manual",
                                      compactProvider, compactModel, ccfg)
      let afterTokens = estimateTokens(entry.messages)
      sessions[sessionId] = entry
      if attempt.status == casCompacted:
        return %*{"ok": true, "sessionId": sessionId, "compacted": true,
                  "beforeTokens": beforeTokens, "afterTokens": afterTokens,
                  "generation": entry.persister.generation}
      var reason = attempt.reason
      if attempt.detail.len > 0:
        reason &= ": " & attempt.detail
      return %*{"ok": true, "sessionId": sessionId, "compacted": false,
                "reason": reason,
                "status": $attempt.status,
                "beforeTokens": beforeTokens}
    if hasExport:
      # Export the exact provider request assembled from the current context.
      # This is deliberately read-only: no user message, LLM call, or store
      # history entry is created. Keep this shape in lockstep with llmArgs
      # below so `/export` is useful for reproducing a provider request.
      var promptToolsJson = entry.exposure.promptTools()
      if entry.allowlist.len > 0:
        var filtered = newJArray()
        for tool in promptToolsJson:
          if tool{"name"}.getStr("") in entry.allowlist:
            filtered.add(tool)
        promptToolsJson = filtered
      let exportTools = promptToolsJson.formatToolsForLlm()
      var request = %*{"messages": entry.messages,
                       "tools": exportTools,
                       "sessionId": sessionId,
                       "stream": true}
      let resolved = resolveTurnConfig(ct, entry.persister, entry.modelOverride)
      let selectedModel = resolved{"model"}.getStr(entry.modelOverride)
      let provider = resolved{"provider"}.getStr("")
      if selectedModel.len > 0:
        request["model"] = %selectedModel
      if provider.len > 0:
        request["provider"] = %provider
      if entry.thinkingEffort.len > 0:
        request["reasoning_effort"] = %entry.thinkingEffort
      sessions[sessionId] = entry
      return %*{"ok": true, "sessionId": sessionId, "request": request}
    var status = %*{
      "sessionId": sessionId,
      "model": entry.modelOverride,
      "thinkingEffort": entry.thinkingEffort,
      "approvals": entry.approvalMode,
      "limits": %*{"rounds": entry.limitRounds, "tokens": entry.limitTokens,
                     "seconds": entry.limitSeconds},
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

  let userMsg =
    if isWake:
      # Marked as runtime machinery so rendering, trimming and compaction
      # treat it like the notices it accompanies — never as something the
      # human typed (the same structural lane as subagent-settled notices).
      %*{"role": "user", "content": turnContent,
         "notice": {"kind": "wake"}}
    else:
      %*{"role": "user", "content": turnContent}
  ctxAppend(entry.persister, entry.messages, userMsg)
  if entry.persister.seqNo == 1 and not hasTitle and not isWake:
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
    # The conversation's gate mode rides the same lifecycle as caller/session:
    # set for this turn, cleared when it ends, so a direct (non-session)
    # harness call still reads as "" (ask).
    ct.approval.approvalMode = entry.approvalMode
  defer:
    if ct.approval != nil:
      ct.approval.caller = ""
      ct.approval.approvalMode = ""

  var turnError = ""
  let reply = runTurn(ct, entry.persister, entry.messages,
                      entry.modelOverride, entry.exposure, onEvent,
                      entry.thinkingEffort, turnContent, entry.workspace,
                      entry.maxRounds, entry.maxCalls, entry.maxTokens,
                      entry.limitRounds, entry.limitTokens, entry.limitSeconds,
                      entry.allowlist, turnError)
  sessions[sessionId] = entry
  # turnError distinguishes "the turn failed" from "the model said this" so
  # drivers (agent_run) report child LLM failures as failures, not text.
  var sessionResult = %*{"ok": true, "sessionId": sessionId, "reply": reply,
                  "modelOverride": entry.modelOverride,
                  "thinkingEffort": entry.thinkingEffort,
                  "approvals": entry.approvalMode,
                  "limits": %*{"rounds": entry.limitRounds,
                                "tokens": entry.limitTokens,
                                "seconds": entry.limitSeconds},
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

func mapSubject*(sessionId: string): string =
  ## The repo-map auto-append channel (docs/research/REPOMAP.md): the
  ## repomap component publishes a finished workspace map here on
  ## ev.workspace.opened; the runner drains it (pumpMap) and runTurn
  ## appends it once as history.
  "svc.session." & sanitizeSessionId(sessionId) & ".map"

func diagSubject*(sessionId: string): string =
  ## The asynchronous LSP-diagnostics channel: the lsp component publishes the
  ## rendered diagnostics for an edited file here once its server answers (or a
  ## one-line note when it is still indexing), so no edit path waits on a cold
  ## server. The runner drains it (pumpDiag) and runTurn appends it as history
  ## — append-only, never the frozen prefix.
  "svc.session." & sanitizeSessionId(sessionId) & ".diag"

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
      discard ct.sup.addChild(rname, bin, rpNever, @[sessionId])
      ct.sup.startChild(ct.sup.children[^1])
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
          discard ct.sup.addChild(rname, bin, rpNever, @[sessionId])
          ct.sup.startChild(ct.sup.children[^1])
    if ct.cat.components.hasKey(rname): break
    sleep(100)
  if not ct.cat.components.hasKey(rname):
    raise newException(IOError,
      "session runner for " & sessionId & " did not come up")
  sessionSubject(sessionId)

proc routeSessionCall*(ct: CoreTools, env: Envelope, reply: string) =
  ## Start a session request and return immediately. The core's main pump owns
  ## the forwarding inboxes; the runner process remains the serialization
  ## boundary for calls belonging to one conversation, so separate
  ## conversations' turns overlap while one conversation never nests turns.
  if reply.len == 0: return
  let sessionId = env.args{"sessionId"}.getStr("")
  if sessionId.len == 0:
    ct.nc.publish(reply, errorEnvelope(env.id, "boom",
      "session needs sessionId").encode())
    return
  try:
    let subject = ensureRunner(ct, sessionId)
    let inbox = "_INBOX." & newId()
    var sub: ptr natsSubscription
    var st = natsConnection_SubscribeSync(addr sub, ct.nc.conn, inbox.cstring)
    if not checkStatus(st):
      raise newException(IOError, "subscribe session inbox: " & getErrorString(st))
    let data = env.encode()
    st = natsConnection_PublishRequest(ct.nc.conn, subject.cstring,
                                       inbox.cstring, data.cstring,
                                       data.len.cint)
    if not checkStatus(st):
      natsSubscription_Destroy(sub)
      raise newException(IOError, "publish session request: " &
        getErrorString(st))
    if ct.pending == nil:
      natsSubscription_Destroy(sub)
      raise newException(IOError, "session forwarding state is unavailable")
    ct.pending.forwards.add(SessionForward(
      env: env, reply: reply, sub: sub,
      deadline: epochTime() + 1800.0 * 1000.0))
  except CatchableError as e:
    ct.nc.publish(reply, errorEnvelope(env.id, "boom", e.msg).encode())

proc pumpCoreCalls*(ct: CoreTools, sub: ptr natsSubscription) =
  ## Serve svc.core.call messages (session/spawn/catalog). Every session call
  ## — control or turn-starting — is forwarded through a private inbox
  ## (routeSessionCall) and completed by pumpSessionForwards, so this pump
  ## never blocks on a runner: separate conversations' turns overlap, and
  ## each runner stays the serialization boundary for its own conversation
  ## (a mid-turn runner refuses further turns with "busy").
  pumpSessionForwards(ct)
  while true:
    pumpSessionForwards(ct)
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if reply.len == 0: continue
    if env.kind != ekCall:
      ct.nc.publish(reply, errorEnvelope(env.id, "bad-envelope",
        "expected a call envelope").encode())
      continue
    if env.tool == "session":
      if ct.routeSession == nil:
        ct.nc.publish(reply, errorEnvelope(env.id, "no-tool",
          "session routing is unavailable").encode())
      else:
        ct.routeSession(env, reply)
      continue
    var resp: Envelope
    try:
      case env.tool
      of "spawn", "catalog", "kill", "remove", "status", "discover", "ui",
          "session_prepare", "session_info", "prompt_preview", "doctor",
          "conversation_delete", "profile":
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
  pumpSessionForwards(ct)
