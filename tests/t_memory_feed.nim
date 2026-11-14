## memory feed validation — how facts get IN, and whether what comes back OUT
## is worth the context it costs.
##
## Validation asked two questions that the contract tests do not answer:
## "how do we collect long-term facts selectively?" and "does the recall
## block actually help?". Both are about behaviour a fictional transcript can
## show, so this test drives a REAL core + runner with the mock model and
## asserts on the PERSISTED conversation, not on a captured bus frame.
##
## What it pins:
##
## 1. Selective collection. The seam is an `onDemand` tool, so the write is
##    always a model decision — there is no automatic extractor turning every
##    turn into facts. This test proves the tool is DISCOVERABLE (not in the
##    frozen direct set and found by `discover`) and that an explicitly
##    authored fact persists. It does not test a real model's curation quality.
## 2. The library is not the transcript. Three turns of chatter about a build
##    produce no facts on their own; a deliberate `memory_remember` produces
##    one. That is the difference between a memory and a transcript copy.
## 3. The write gate. A subagent (a session carrying `sessionmeta.parent`)
##    may read its repo's facts and may not write: a child's half-finished
##    inference is the least trustworthy thing in the system.
## 4. Recall reaches the model unasked, and stays bounded. The block is
##    appended after the user message, capped in facts, and the frozen system
##    prompt contains none of the recalled fact text.
##
## The retrieval-quality question ("does semantic search find the right
## fact?") belongs to tests/t_memory_vector.nim, which measures the store's
## kNN; this file measures the ACCUMULATION half.

import std/[json, os, osproc, sequtils, strutils]
import natsnim
import helpers

proc git(dir: string, args: seq[string]): bool =
  try:
    let p = startProcess("git", workingDir = dir, args = args,
                         options = {poUsePath, poStdErrToStdOut})
    result = waitForExit(p, 30_000) == 0
    p.close()
  except CatchableError:
    result = false

proc factsIn(text: string): int =
  ## Count `- subject:` lines in a recall block: the shape a reader (and the
  ## model) can count without parsing prose.
  for line in text.splitLines():
    if line.strip().startsWith("- "): inc result

proc main() =
  let root = getEnv("NIF_REPO_ROOT",
                    getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "memory", "fixture-mock-llm"]:
    if not fileExists(root / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      report("MEMORY FEED TEST")

  let sandbox = newCoreSandbox("memoryfeed", ["store", "memory", "llm"])
  let keepSandbox = getEnv("NIF_KEEP_SANDBOX", "").len > 0
  if keepSandbox: echo "sandbox kept at ", sandbox.root
  defer:
    if not keepSandbox: removeDir(sandbox.root)
  copyFileWithPermissions(root / "var" / "bin" / "fixture-mock-llm",
                          sandbox.sandboxBin("llm"))

  let repo = sandbox.root / "proj"
  createDir(repo)
  discard git(repo, @["init", "-q", "-b", "main"])
  discard git(repo, @["config", "user.email", "t@example.invalid"])
  discard git(repo, @["config", "user.name", "t"])
  writeFile(repo / "README.md", "fixture\n")
  discard git(repo, @["add", "."])
  discard git(repo, @["commit", "-qm", "init"])

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # NIF_MOCK_ROUNDS=0: the mock answers in one round, so a turn is cheap and
  # the assertion is about memory, not about a tool loop.
  let core = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = [("NIF_AUTO_APPROVE", "1"), ("NIF_MOCK_ROUNDS", "0")],
    logFile = sandbox.root / "var" / "test-logs" / "core.log")
  defer: stopProcess(core)
  # Poll the catalog rather than `waitRegistered`: that helper only watches
  # FUTURE reg.publish frames, and every component here has already registered
  # by the time a started core returns — the wait could only ever time out.
  # Asking core is also the stronger check: it proves core finished
  # subscribing to svc.core.call (see waitCoreUp's note).
  var ready = false
  for _ in 0 ..< 200:
    let cat = call(nc, "core", "catalog", %*{"op": "components"}, 3_000)
    if cat{"components"}{"memory"} != nil and
        cat{"components"}{"llm"} != nil and
        cat{"components"}{"store"} != nil:
      ready = true
      break
    sleep(100)
  check("core, store, memory and llm are up", ready,
        "components did not register")
  if not ready: report("MEMORY FEED TEST")

  proc listMemory(prefix = ""): seq[string] =
    let r = call(nc, "store", "list",
                 %*{"kind": "memory", "idPrefix": prefix, "limit": 1000}, 10_000)
    if r{"items"} != nil:
      for item in r{"items"}: result.add item{"id"}.getStr("")

  # === 1. selective collection: the write is a model DECISION =============
  # Shapes, probed rather than assumed (they differ per op):
  #   catalog {op: snapshot}   -> components: [ {name, version, tools:[…]} ]
  #   catalog {op: list}       -> tools: [ … ]  (the frozen DIRECT set)
  #   catalog {op: components} -> components: { name: [toolName, …] }
  let snapshot = call(nc, "core", "catalog", %*{"op": "snapshot"}, 10_000)
  var memoryTools: seq[string] = @[]
  if snapshot{"components"} != nil and snapshot{"components"}.kind == JArray:
    for entry in snapshot{"components"}:
      if entry{"name"}.getStr("") == "memory" and entry{"tools"} != nil:
        for tool in entry{"tools"}:
          memoryTools.add tool{"name"}.getStr("")
  check("the memory tools exist in the catalog", memoryTools.len >= 5,
        $memoryTools)

  let directView = call(nc, "core", "catalog", %*{"op": "list"}, 10_000)
  var directTools: seq[string] = @[]
  # A nil/absent key must never be iterated: json.nim's items iterator
  # SIGSEGVs on nil (AGENTS.md).
  if directView{"tools"} != nil and directView{"tools"}.kind == JArray:
    for tool in directView{"tools"}:
      directTools.add tool{"name"}.getStr("")
  check("no memory tool is in the frozen direct set",
        directTools.len > 0 and not memoryTools.anyIt(directTools.contains(it)),
        "a memory schema in the direct set costs every conversation tokens; " &
        "direct=" & $directTools)

  # Ten turns of ordinary chatter must not manufacture facts. Run through the
  # SESSION surface (a real runner), because that is where an automatic
  # extractor would live if one existed.
  let chat = "chat-no-facts"
  for i in 1 .. 3:
    discard call(nc, "core", "session", %*{
      "sessionId": chat, "content": "look at the build output again #" & $i,
      "cwd": repo}, 120_000)
  sleep(500)
  let afterChatter = listMemory()
  check("conversation chatter does not create facts by itself",
        afterChatter.len == 0,
        "a transcript-to-facts extractor would defeat selective collection: " &
        $afterChatter)

  # The write path the model uses: discover, then invoke. `invoke` with a
  # discovered name is how an on-demand tool is reached (docs/MANUAL.md,
  # "Progressive tool discovery").
  let discovered = call(nc, "core", "discover",
                        %*{"query": "remember a durable fact"}, 15_000)
  # The registry answer TRUNCATES each description with an ellipsis, so assert
  # on the component/tool names it routes to, not on prose that may be cut.
  var discoveredNames: seq[string] = @[]
  if discovered{"components"} != nil and discovered{"components"}.kind == JArray:
    for entry in discovered{"components"}:
      for tool in entry{"onDemand"}:
        discoveredNames.add tool{"name"}.getStr("")
  check("discover routes a memory query to the write tool",
        discoveredNames.contains("memory_remember"), $discoveredNames)
  let wrote = callAsSession(nc, "memory", "memory_remember", %*{
    "workspace": repo,
    "subject": "build.jobs",
    "text": "`make build` needs -j1 on this box or the link step OOMs",
    "volatility": "stable",
    "tags": %*["build"]}, session = chat, timeoutMs = 20_000)
  let activities = call(nc, "store", "list", %*{
    "kind": "memory-activity", "idPrefix": chat & ":"}, 10_000)
  check("successful saves have durable, separately renderable memory activity",
    ($activities).contains("saved") and ($activities).contains("build.jobs"), $activities)
  check("a deliberate remember writes one fact",
        wrote{"ok"}.getBool(false) and listMemory().len == 1, $wrote)
  check("the fact records its provenance (scope key + subject)",
        wrote{"subject"}.getStr("") == "build.jobs" and
        wrote{"scopeKey"}.getStr("").startsWith("repo:"), $wrote)

  # A second, DIFFERENT fact — the recall block caps facts, and two facts let
  # that cap be tested without relying on duplicates.
  discard call(nc, "memory", "memory_remember", %*{
    "workspace": repo, "subject": "deps.package_manager",
    "text": "this repo uses pnpm, not npm", "volatility": "slow"}, 20_000)
  check("a second fact in a different subject is stored",
        listMemory().len == 2, $listMemory())

  # === 2. the subagent write gate ========================================
  # docs/MANUAL.md ("Long-term memory") and docs/research/MEMORY.md §6: a
  # subagent may READ its repo's facts and may NOT write. The rule is enforced
  # from `sessionmeta.parent` — the same durable lineage core and `agent` use —
  # and fails closed when the store cannot answer.
  let child = "chat-child"
  discard call(nc, "core", "session", %*{
    "sessionId": child, "content": "hi", "cwd": repo,
    "parent": chat}, 120_000)
  # A conversation under `parent` IS the subagent shape the rule describes. In
  # production `agent_spawn` records that lineage; a turn through
  # `core session {parent}` does not, so the record the rule reads is seeded
  # explicitly rather than assumed.
  let seeded = call(nc, "store", "put", %*{
    "kind": "sessionmeta", "id": child,
    "value": %*{"parent": chat, "agent": "test-child"}}, 10_000)
  check("the child carries sessionmeta.parent (the rule's input exists)",
        seeded{"ok"}.getBool(false), $seeded)

  let childRead = callAsSession(nc, "memory", "memory_search",
    %*{"query": "build jobs", "workspace": repo},
    session = child, timeoutMs = 15_000)
  check("a subagent READS its repo's facts",
        childRead{"ok"}.getBool(false) and
        childRead{"count"}.getInt(0) >= 1, $childRead)

  let childForget = callAsSession(nc, "memory", "memory_forget", %*{
    "id": wrote{"id"}}, session = child, timeoutMs = 15_000)
  check("subagents cannot forget a curated fact either",
    childForget{"code"}.getStr("") == "subagent-readonly", $childForget)
  let beforeChildWrite = listMemory().len
  let childWrite = callAsSession(nc, "memory", "memory_remember", %*{
    "workspace": repo, "subject": "build.child_guess",
    "text": "the child thinks the build is broken"}, session = child,
    timeoutMs = 15_000)
  check("a subagent may NOT write a fact",
        childWrite{"error"} != nil, $childWrite)
  check("the refusal says WHY, naming the lineage it found",
        childWrite{"error"}.getStr("").contains("subagent") and
        childWrite{"error"}.getStr("").contains(chat), $childWrite)
  check("the refused write stored nothing",
        listMemory().len == beforeChildWrite, $listMemory())

  # A ROOT conversation with no lineage record is not a subagent: the gate must
  # not over-refuse, or memory becomes unwritable by the very conversations
  # that are supposed to curate it.
  let rootWrite = callAsSession(nc, "memory", "memory_remember", %*{
    "workspace": repo, "subject": "build.root_fact",
    "text": "a root conversation may still remember"}, session = chat,
    timeoutMs = 15_000)
  check("a root conversation (no parent) still writes",
        rootWrite{"ok"}.getBool(false) and rootWrite{"error"} == nil, $rootWrite)

  # === 3. recall reaches the model unasked, bounded, prefix-stable =======
  let fresh = "chat-recall"
  let firstTurn = call(nc, "core", "session", %*{
    "sessionId": fresh, "content": "what should I know before I build?",
    "cwd": repo}, 120_000)
  check("the recall conversation ran", firstTurn{"error"} == nil, $firstTurn)

  var transcript = ""
  let messages = call(nc, "store", "list", %*{
    "kind": "message", "idPrefix": fresh & ":", "limit": 1000}, 15_000)
  if messages{"items"} != nil:
    for item in messages{"items"}:
      transcript.add $item{"value"} & "\n"
  check("the fact text appears in the PERSISTED transcript",
        transcript.contains("-j1"), "the block never reached the conversation")
  check("the recall block names the subject it came from",
        transcript.contains("build.jobs"), "a fact without a subject is ambient")
  # The prefix invariant is about the HEADER, not about ordering inside the
  # transcript: the frozen system prompt is persisted in the conversation
  # document, so a fact spliced into it would show up there.
  let header = call(nc, "store", "get", %*{"kind": "conversation", "id": fresh},
                    15_000)
  let systemPrompt = header{"value"}{"systemPrompt"}.getStr("")
  check("a frozen system prompt exists for this conversation",
        systemPrompt.len > 0, "the header carried no prompt: " & $header)
  check("recall never enters the frozen system prompt",
        not systemPrompt.contains("build.jobs") and
        not systemPrompt.contains("-j1"),
        "a recalled fact in the header would break the cache for the whole " &
        "conversation")
  check("the fact is in HISTORY instead (what a later turn can recall)",
        transcript.contains("build.jobs"), "absent from both prefix and history")

  # Bounded: a third fact must not push the block past its cap. recallFacts
  # defaults to 6, so three facts fit — assert the cap exists at all by
  # asking for a block of one.
  let tiny = call(nc, "memory", "memory_recall",
                  %*{"workspace": repo, "limit": 1}, 15_000)
  check("recall honours a fact cap", factsIn(tiny{"block"}.getStr("")) <= 1,
        $tiny)

  report("MEMORY FEED TEST")

main()
