## memory live — the append-only recall lane, end to end.
##
## tests/t_memory.nim proves the COMPONENT: scope resolution, the record
## contract, and that the right blocks are published on
## svc.session.<id>.memory. It cannot prove the half that matters most, because
## nothing is draining the lane — it captures the published message.
##
## This test runs a REAL full core (store + memory + the mock llm) and asserts
## the claim the design rests on (docs/research/MEMORY.md §4, §10): a fact
## written in a repository is APPENDED TO THE CONVERSATION'S PERSISTED HISTORY,
## unasked, before the model's first request — and it arrives as ordinary
## append-only history, so the frozen prompt prefix is untouched.
##
## That distinction is the whole point of the feature. A memory the model has to
## think to ask for is memory it does not use; a memory spliced into the head
## would break the prompt cache for the conversation's lifetime. The lane is how
## both are avoided, and until this test ran, the lane was only half verified.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc sh(cmd: string): tuple[output: string, exitCode: int] =
  execCmdEx(cmd)

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "memory", "fixture-mock-llm"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      report("MEMORY LIVE TEST")

  let sandbox = newCoreSandbox("memory-live", ["store", "memory", "llm"])
  # Keep the sandbox when NIF_KEEP_SANDBOX is set: diagnosing a lane failure
  # needs the core log, and a removed root says nothing. The defer must sit at
  # PROC scope — a `defer` inside an `if` block fires at the end of that block,
  # which deleted the sandbox before the test could use it.
  let keepSandbox = getEnv("NIF_KEEP_SANDBOX", "").len > 0
  if keepSandbox: echo "sandbox kept at ", sandbox.root
  defer:
    if not keepSandbox: removeDir(sandbox.root)
  # The sandbox wants var/bin/llm; the mock is the provider-free stand-in every
  # conversation-loop contract test uses.
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fixture-mock-llm",
                          sandbox.sandboxBin("llm"))

  # A real git repository to scope the facts to.
  let repo = sandbox.root / "proj"
  createDir(repo)
  discard sh("git -C " & quoteShell(repo) & " init -q -b main")
  discard sh("git -C " & quoteShell(repo) &
             " config user.email t@example.invalid")
  discard sh("git -C " & quoteShell(repo) & " config user.name t")
  writeFile(repo / "README.md", "fixture\n")
  discard sh("git -C " & quoteShell(repo) & " add . && git -C " &
             quoteShell(repo) & " commit -qm init")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let core = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = [("NIF_AUTO_APPROVE", "1"), ("NIF_MOCK_ROUNDS", "0")],
    logFile = sandbox.root / "var" / "test-logs" / "core.log")
  defer: stopProcess(core)
  check("core is up", waitComponent(nc, "store") and waitComponent(nc, "memory") and
        waitComponent(nc, "llm"), "components did not register")

  # --- 1. write a fact in the repo, before any conversation exists --------
  let wrote = call(nc, "memory", "memory_remember", %*{
    "text": "make build needs -j1 on this box or nim OOMs",
    "subject": "build.jobs", "volatility": "stable", "workspace": repo},
    20_000)
  check("the fact is recorded for the repository",
        wrote{"ok"}.getBool(false) and wrote{"scope"}.getStr("") == "repo",
        $wrote)

  # --- 2. a real conversation turn, in that repo --------------------------
  # The conversation's cwd IS the repo, which is what makes it the same scope.
  let conv = "memlive-" & $int(epochTime())
  let turn = call(nc, "core", "session", %*{
    "sessionId": conv, "content": "hello", "cwd": repo}, 120_000)
  check("the conversation ran a turn",
        turn{"error"} == nil and turn{"turnError"}.getStr("") == "", $turn)

  # --- 3. THE CLAIM: the fact is in the persisted transcript, unasked -----
  # Read the canonical messages from the store, not from a live stream: the
  # block must be durable history, exactly like a user message.
  var blockText = ""
  let listing = call(nc, "store", "list",
                     %*{"kind": "message", "idPrefix": conv & ":",
                        "limit": 1000}, 20_000)
  var sawBlockMsg = false
  for item in listing{"items"}:
    let content = item{"value"}{"content"}.getStr("")
    if content.contains("Durable memory") and content.contains("build.jobs"):
      sawBlockMsg = true
      blockText = content
  check("the recall block was persisted into the transcript unasked",
        sawBlockMsg,
        "no memory block among " & $listing{"items"}.len & " messages — the " &
        "lane published but nothing appended it")
  check("the appended block is attributed (subject) and explained",
        blockText.contains("[build.jobs]") and
        blockText.contains("re-verify"), blockText)
  check("the fact itself is in the appended block",
        blockText.contains("-j1"), blockText)

  # --- 4. it is append-only: the block sits AFTER the human's message -----
  # A prefix member would be first (or part of the system prompt). Being
  # ordered after the user message is the observable form of "appended".
  var userIdx, blockIdx = -1
  var i = 0
  for item in listing{"items"}:
    let value = item{"value"}
    let content = value{"content"}.getStr("")
    if value{"role"}.getStr("") == "user" and content.strip() == "hello":
      userIdx = i
    if content.contains("Durable memory"): blockIdx = i
    inc i
  check("the block is appended after the human's message, not in the prefix",
        userIdx >= 0 and blockIdx >= 0 and blockIdx > userIdx,
        "user at " & $userIdx & ", block at " & $blockIdx)

  # --- 5. the frozen prompt is untouched by memory -----------------------
  # The block must not have become part of the system prompt: that is the
  # whole reason the recall rides history instead of the prefix.
  let header = call(nc, "store", "get",
                    %*{"kind": "conversation", "id": conv}, 10_000)
  let sysPrompt = header{"value"}{"systemPrompt"}.getStr("")
  check("the conversation froze a system prompt",
        sysPrompt.len > 0, "no systemPrompt in the header")
  check("memory did NOT splice the facts into the frozen prefix",
        not (sysPrompt.contains("Durable memory") or
             sysPrompt.contains("build.jobs")),
        "the block reached the system prompt — a cache miss per conversation")

  # --- 6. a worktree conversation shares the SAME memory ------------------
  # The reason the scope key is the primary root, proven through a real
  # conversation rather than through checkoutShape alone.
  let wt = sandbox.root / "proj.wt" / "feat"
  createDir(sandbox.root / "proj.wt")
  discard sh("git -C " & quoteShell(repo) & " worktree add -q " &
             quoteShell(wt) & " -b feat")
  let convWt = "memlive-wt-" & $int(epochTime())
  let turnWt = call(nc, "core", "session", %*{
    "sessionId": convWt, "content": "hello from the worktree", "cwd": wt},
    120_000)
  check("the worktree conversation ran a turn",
        turnWt{"error"} == nil and turnWt{"turnError"}.getStr("") == "",
        $turnWt)
  var wtSawFact = false
  let wtList = call(nc, "store", "list",
                    %*{"kind": "message", "idPrefix": convWt & ":",
                       "limit": 1000}, 20_000)
  for item in wtList{"items"}:
    if item{"value"}{"content"}.getStr("").contains("build.jobs"):
      wtSawFact = true
  check("a conversation in a WORKTREE is told the primary's fact unasked",
        wtSawFact,
        "the worktree got no recall block — memory would be per-path, not " &
        "per-repository")

  report("MEMORY LIVE TEST")

when isMainModule:
  main()
