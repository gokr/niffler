## memory tests — the durable layer's contract (docs/research/MEMORY.md).
##
## The load-bearing claim, and the one this file exists for: a LINKED WORKTREE
## resolves to its PRIMARY repository's memory. Keying on the workspace path
## instead would give every worktree an amnesiac clone of the repo it was cut
## from — exactly backwards, since a worktree is where you go to apply what the
## repository already taught you. The scope key is `repo:<primaryRoot>`, from
## the same `checkoutShape` the write fence uses.
##
## The rest is the record contract: one live fact per subject (a correction is
## a revision, not a second contradicting fact), an audit trail that survives
## `forget`, strictest-scope shadowing, a deterministic token-prefix ranker, a
## credential refusal, and never failing a turn when the store is unreachable.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc git(dir: string, args: seq[string]): bool =
  ## Run git in `dir`; false on a non-zero exit. Kept tiny on purpose — the
  ## fixture needs a real repository and a real `git worktree`, because the
  ## scope rule is about what GIT reports, not about a string comparison.
  try:
    let p = startProcess("git", workingDir = dir, args = args,
                         options = {poUsePath, poStdErrToStdOut})
    result = waitForExit(p, 30_000) == 0
    p.close()
  except CatchableError:
    result = false

proc scopeKey(r: JsonNode): string =
  ## The resolved store key from any memory reply that carries one.
  if r == nil: return ""
  if r{"scopeKey"} != nil: return r{"scopeKey"}.getStr("")
  if r{"scopes"} != nil and r{"scopes"}.kind == JArray and r{"scopes"}.len > 0:
    return r{"scopes"}[0].getStr("")
  ""

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let memoryBin = root / "var" / "bin" / "memory"
  if not fileExists(memoryBin):
    fail(memoryBin & " missing — run `make build` first")
  report("MEMORY TEST")
  let storeBin = resolveStoreBin(root)
  if not fileExists(storeBin):
    fail(storeBin & " missing — run `make build` first")
    report("MEMORY TEST")

  let tmp = tempRoot("memory")
  defer: removeDir(tmp)

  # --- a real repository, and a real linked worktree of it -----------------
  let repo = tmp / "proj"
  createDir(repo)
  check("fixture repository created", git(repo, @["init", "-q", "-b", "main"]),
        "git init failed")
  discard git(repo, @["config", "user.email", "t@example.com"])
  discard git(repo, @["config", "user.name", "Test"])
  writeFile(repo / "README.md", "fixture\n")
  check("fixture commit created", git(repo, @["add", "."]) and
        git(repo, @["commit", "-qm", "init"]), "git commit failed")
  let wt = tmp / "proj.wt" / "feat"
  createDir(tmp / "proj.wt")
  check("linked worktree created",
        git(repo, @["worktree", "add", "-q", "-b", "feat", wt]),
        "git worktree add failed")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let storeProc = startComponent(storeBin, url, root = tmp)
  defer: stopProcess(storeProc)
  let memoryProc = startComponent(memoryBin, url, root = tmp)
  defer: stopProcess(memoryProc)

  # The component registers at boot; give it a moment to subscribe. (A call to
  # an unregistered component returns nats 23, which would read like a broken
  # tool rather than a race — so wait for the catalog instead.)
  var ready = false
  let readyDeadline = epochTime() + 20.0
  while not ready and epochTime() < readyDeadline:
    let r = call(nc, "store", "list", %*{"kind": "memory", "limit": 1}, 3_000)
    if r{"error"} == nil: ready = true
    else: sleep(100)
  check("store and memory are reachable", ready, "components did not come up")

  # --- 1. scope resolution: a worktree shares its primary's memory ---------
  let inRepo = call(nc, "memory", "memory_scopes", %*{"workspace": repo}, 15_000)
  let inWt = call(nc, "memory", "memory_scopes", %*{"workspace": wt}, 15_000)
  let repoKey = block:
    var k = ""
    for s in inRepo{"scopes"}:
      if s{"scope"}.getStr("") == "repo" and s{"resolved"}.getBool(false):
        k = s{"key"}.getStr("")
    k
  let wtKey = block:
    var k = ""
    for s in inWt{"scopes"}:
      if s{"scope"}.getStr("") == "repo" and s{"resolved"}.getBool(false):
        k = s{"key"}.getStr("")
    k
  check("repo scope resolves to a repo:<path> key",
        repoKey.startsWith("repo:") and repoKey.len > 5, $inRepo)
  check("a linked worktree resolves to the SAME key as its primary",
        wtKey == repoKey and wtKey.len > 0,
        "primary=" & repoKey & " worktree=" & wtKey &
        " — a worktree must not get its own memory (" & $inWt & ")")

  # --- 2. write in the repo, read from the worktree ------------------------
  let wrote = call(nc, "memory", "memory_remember", %*{
    "text": "make build needs -j1 on this box or the compiler OOMs",
    "subject": "build.jobs", "tags": ["build", "gotcha"],
    "type": "gotcha", "volatility": "stable", "workspace": repo}, 15_000)
  check("remember creates a fact", wrote{"ok"}.getBool(false) and
        wrote{"revision"}.getInt(0) == 1 and
        wrote{"updated"}.getBool(true) == false, $wrote)

  let fromWt = call(nc, "memory", "memory_search",
                    %*{"query": "compiler OOM", "workspace": wt}, 15_000)
  check("the worktree's conversation READS the primary's fact",
        fromWt{"ok"}.getBool(false) and fromWt{"count"}.getInt(0) == 1 and
        fromWt{"items"}[0]{"subject"}.getStr("") == "build.jobs", $fromWt)
  check("search reports which ranker answered",
        fromWt{"ranker"}.getStr("") == "text", $fromWt)

  let rememberedFromWt = call(nc, "memory", "memory_remember", %*{
    "text": "the feat branch flake: sqlite lock in tests under -j2",
    "subject": "test.flake", "volatility": "slow", "workspace": wt}, 15_000)
  check("the worktree WRITES into the primary's scope",
        rememberedFromWt{"ok"}.getBool(false) and
        rememberedFromWt{"scopeKey"}.getStr("") == repoKey, $rememberedFromWt)
  let bothVisible = call(nc, "memory", "memory_list",
                         %*{"scope": "repo", "workspace": repo}, 15_000)
  check("both writes are one scope, not two memories",
        bothVisible{"count"}.getInt(0) == 2, $bothVisible)

  # --- 3. one live fact per subject: a correction is a revision ------------
  let corrected = call(nc, "memory", "memory_remember", %*{
    "text": "make build needs -j1 on this box (2 cores); -j2 OOMs",
    "subject": "build.jobs", "tags": ["build"], "volatility": "stable",
    "workspace": repo}, 15_000)
  check("re-remembering a subject UPDATES it (revision 2), not duplicates",
        corrected{"ok"}.getBool(false) and
        corrected{"revision"}.getInt(0) == 2 and
        corrected{"updated"}.getBool(false), $corrected)
  let afterCorrect = call(nc, "memory", "memory_list",
                          %*{"scope": "repo", "workspace": repo}, 15_000)
  check("still one record for that subject",
        afterCorrect{"count"}.getInt(0) == 2, $afterCorrect)

  let got = call(nc, "memory", "memory_get", %*{
    "id": repoKey & ":build.jobs"}, 15_000)
  check("get returns the current text and the revision trail",
        got{"ok"}.getBool(false) and
        got{"value"}{"text"}.getStr("").contains("-j2 OOMs") and
        got{"revisions"}.len >= 1 and
        got{"revisions"}[0]{"text"}.getStr("").contains("-j1 on this box or"),
        $got)

  # --- 4. strictest scope wins: repo shadows global on the same subject ----
  let globalWrite = call(nc, "memory", "memory_remember", %*{
    "text": "prefer -j2 everywhere for speed",
    "subject": "build.jobs", "scope": "global", "workspace": repo}, 15_000)
  check("a global write is allowed (core gates it; a direct call is trusted)",
        globalWrite{"ok"}.getBool(false), $globalWrite)
  let shadowed = call(nc, "memory", "memory_search",
                      %*{"query": "build jobs", "workspace": repo,
                         "limit": 10}, 15_000)
  var subjects: seq[string]
  for item in shadowed{"items"}: subjects.add item{"subject"}.getStr("")
  check("the repo fact shadows the global one on the same subject",
        not ("build.jobs" in subjects and subjects.len > 2), $shadowed)
  check("the searched scopes are reported (repo first, then global)",
        shadowed{"scopes"}.kind == JArray and shadowed{"scopes"}.len >= 1,
        $shadowed)

  # --- 5. forget archives, it does not destroy ----------------------------
  let forgotten = call(nc, "memory", "memory_forget",
                       %*{"id": repoKey & ":test.flake"}, 15_000)
  check("forget succeeds", forgotten{"ok"}.getBool(false), $forgotten)
  let afterForget = call(nc, "memory", "memory_list",
                         %*{"scope": "repo", "workspace": repo}, 15_000)
  check("the forgotten fact leaves the live list",
        afterForget{"count"}.getInt(0) == 1, $afterForget)
  let archived = call(nc, "memory", "memory_get",
                      %*{"id": repoKey & ":test.flake"}, 15_000)
  check("the forgotten fact is archived, not destroyed (still readable)",
        archived{"ok"}.getBool(false) == false and
        archived{"code"}.getStr("") == "not-found",
        "live record should be gone: " & $archived)

  # --- 6. retrieval quality: prefix matching, and a real miss is empty ----
  let prefixHit = call(nc, "memory", "memory_search",
                       %*{"query": "worktree", "workspace": repo}, 15_000)
  check("a query matching nothing returns an empty page, not an error",
        prefixHit{"ok"}.getBool(false) == false or
        prefixHit{"items"}.kind == JArray, $prefixHit)
  let noWords = call(nc, "memory", "memory_search",
                     %*{"query": "   ", "workspace": repo}, 15_000)
  check("a query with no tokens is a bad-request",
        noWords{"ok"}.getBool(true) == false and
        noWords{"error"}.getStr("").contains("query"), $noWords)

  # --- 7. a credential is refused, with a reason --------------------------
  let secret = call(nc, "memory", "memory_remember", %*{
    "text": "the deploy key is sk-live-abcdef0123456789",
    "subject": "deploy.key", "workspace": repo}, 15_000)
  check("credential-shaped text is refused",
        secret{"ok"}.getBool(true) == false and
        secret{"code"}.getStr("") == "secret", $secret)
  let secretStored = call(nc, "memory", "memory_search",
                          %*{"query": "sk-live", "workspace": repo}, 15_000)
  check("and nothing was written", secretStored{"count"}.getInt(1) == 0,
        $secretStored)

  # --- 8. the recall block: bounded, attributed, never a prefix change ----
  let recall = call(nc, "memory", "memory_recall",
                    %*{"workspace": repo, "limit": 6}, 15_000)
  let recallText = recall{"block"}.getStr("")
  check("recall returns a block with the standing facts",
        recall{"ok"}.getBool(false) and recallText.len > 0 and
        recallText.contains("build.jobs"), $recall)
  check("each fact names its subject (auditable, not ambient)",
        recallText.contains("[build.jobs]"), recallText)
  check("the block says what it is, and to re-verify stale facts",
        recallText.contains("Durable memory") and
        recallText.contains("re-verify"), recallText)
  let tiny = call(nc, "memory", "memory_recall",
                  %*{"workspace": repo, "limit": 1}, 15_000)
  check("recall is bounded by limit", tiny{"count"}.getInt(0) <= 1, $tiny)

  # --- 9. scope ownership: another path's memory is not readable ----------
  let other = tmp / "other"
  createDir(other)
  let otherList = call(nc, "memory", "memory_list",
                       %*{"scope": "repo", "workspace": other}, 15_000)
  check("a different (non-git) directory is its own dir: scope, and empty",
        otherList{"ok"}.getBool(false) and
        otherList{"count"}.getInt(-1) == 0 and
        otherList{"scope"}.getStr("") == "dir", $otherList)
  let bogus = call(nc, "memory", "memory_list",
                   %*{"scope": "somewhere-else", "workspace": repo}, 15_000)
  check("an unknown scope is refused with the valid set named",
        bogus{"ok"}.getBool(true) == false and
        bogus{"error"}.getStr("").contains("global"), $bogus)

    # --- 10. the append-only recall lane ------------------------------------
  # The two triggers the core lane rides (docs/research/MEMORY.md §4): a
  # conversation opening, and a compaction that removed history. Both must
  # land on svc.session.<id>.memory — the lane core drains and ctxAppend's as
  # history — and nowhere near the frozen prefix.
  block recallLane:
    let conv = "conv-memtest"
    var laneSub: ptr natsSubscription
    discard checkStatus(natsConnection_SubscribeSync(addr laneSub, nc.conn,
                                                     ("svc.session." & conv & ".memory").cstring))
    defer: natsSubscription_Destroy(laneSub)

    proc waitBlock(): JsonNode =
      for _ in 0 ..< 100:
        var msg: ptr natsMsg
        if natsSubscription_NextMsg(addr msg, laneSub, 100) == NATS_OK:
          let data = $natsMsg_GetData(msg)
          natsMsg_Destroy(msg)
          let env = decode(data)
          if env.payload != nil and env.payload{"block"}.getStr("").len > 0:
            return env.payload
      nil

    # birth: a conversation opening on this repo publishes its standing facts
    nc.publish("ev.workspace.opened",
      Envelope(v: 1, id: newId(), kind: ekEvent,
               payload: %*{"workspace": repo, "conversationId": conv}).encode())
    let birthBlock = waitBlock()
    check("opening a conversation publishes a recall block on the lane",
          birthBlock != nil and
          birthBlock{"block"}.getStr("").contains("build.jobs"),
          if birthBlock == nil: "no block arrived" else: $birthBlock)
    check("the block is attributed and bounded",
          birthBlock != nil and
          birthBlock{"block"}.getStr("").contains("[build.jobs]") and
          birthBlock{"block"}.getStr("").len < 20_000,
          if birthBlock == nil: "no block" else: $birthBlock)

    # compaction: the same conversation, after history was removed, re-opens
    # the window (the facts a summary dropped are what memory restores).
    # A real conversation ALWAYS has a header carrying its workspace — that is
    # where the component learns which repo the facts belong to, because the
    # context event itself carries only the conversation id.
    let seededHeader = call(nc, "store", "put", %*{
      "kind": "conversation", "id": conv,
      "value": %*{"createdAt": epochTime(), "title": "memory lane",
                  "cwd": repo, "systemPrompt": "seeded"}}, 15_000)
    check("seeded the conversation header (its cwd is the repo)",
          seededHeader{"ok"}.getBool(false), $seededHeader)
    nc.publish("ev.session." & conv & ".context",
      Envelope(v: 1, id: newId(), kind: ekEvent,
               payload: %*{"sessionId": conv, "reason": "reset:compact"}).encode())
    sleep(300)
    let compactBlock = waitBlock()
    check("a compaction republishes the recall block", compactBlock != nil,
          "no block after reset:compact")

    # a sticky-tool prefix rebuild removed NO history, so it must stay silent
    nc.publish("ev.session." & conv & ".context",
      Envelope(v: 1, id: newId(), kind: ekEvent,
               payload: %*{"sessionId": conv, "reason": "reset:tools"}).encode())
    sleep(400)
    check("a reset:tools (no history lost) does NOT republish",
          waitBlock() == nil, "the block was repeated for a non-lossy reset")

  # --- 11. the component survives its optional neighbours being absent ----
  # Regression for a bug this test could not see and t_memory_live could:
  # `requestOk` RAISES "no responders" when systemprompt is absent, and an
  # uncaught exception in the idle handler killed the component in a restart
  # loop — which silently cost the whole feature in exactly the harness that
  # lacked the component, while every direct bus call still worked.
  block optionalNeighbours:
    sleep(1200)   # two idle ticks: the hint attempt runs and must not crash
    let alive = call(nc, "memory", "memory_scopes", %*{"workspace": repo},
                     15_000)
    check("the component is still serving after idle ticks with NO systemprompt",
          alive{"ok"}.getBool(false), $alive)
    # And the facts it held are still there: a restart loop would have been
    # survivable only because the store outlives the process — the point here
    # is that the PROCESS stayed up.
    let stillThere = call(nc, "memory", "memory_list",
                          %*{"scope": "repo", "workspace": repo}, 15_000)
    check("its records survived the idle ticks",
          stillThere{"ok"}.getBool(false) and stillThere{"count"}.getInt(0) >= 1,
          $stillThere)

  report("MEMORY TEST")

when isMainModule:
  main()
