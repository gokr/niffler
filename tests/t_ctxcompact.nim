## t_ctxcompact — the context identity ledger (docs/research/COMPACTION.md §4.2).
##
## Step-1 contract, unit level (store + conversation procs, no LLM):
## - the node ledger stays 1:1 with the projection (ctxAppend is the only
##   growth path; a bare messages.add is how the ledger drifts),
## - resume rebuilds canonical ids: loadStoredMessagesEx returns nodes whose
##   ids are the store keys the context was built from,
## - error-role records consume ids but never become nodes (audit only),
## - canonicalHigh tracks the last canonical node; appends continue after it,
## - the `after` cursor starts a reload mid-transcript (projection reload,
##   §6.2 reload step 4),
## - ctxDigest binds ids + per-message content and moves when either changes,
##   which is what lets the runner verify a compaction candidate's claim.
##
## The long-turn regression, admission and the fallback ladder land here in
## step 2 (§6.1–6.5) against the mock-LLM sandbox.

import std/[json, os, osproc, strutils, times]
import natsnim
import ../core/[catalog, conversation, dispatch]
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc stopHard(p: var Process) =
  if p != nil and p.running():
    p.terminate()
    sleep(500)
    if p.running(): p.kill()
    sleep(100)
  if p != nil: p.close()
  p = nil

proc readRequests(path: string): tuple[accepted: seq[int], rejected: int] =
  ## The mock's JSONL request log: accepted estimates and the rejection
  ## count — the provider's own view of what admission let through.
  result.accepted = @[]
  result.rejected = 0
  if not fileExists(path): return
  for line in readFile(path).strip().splitLines():
    if line.len == 0: continue
    try:
      let r = parseJson(line)
      if r{"rejected"}.getBool(false): inc result.rejected
      else: result.accepted.add(r{"estimate"}.getInt(0))
    except CatchableError:
      discard

proc runSandboxFixture(tag: string, window: int, rounds: int,
                       toolBytes: int, hideCtx: bool, reserve: string,
                       objective: string,
                       verify: proc(nc: NatsConnection, sessionId: string) {.closure.} = nil):
    tuple[reply, turnError: string, logPath: string] =
  ## Boot a sandbox core with the enforcing mock provider and drive one
  ## user turn. `verify` runs while the sandbox is still live (store
  ## assertions). Returns the session result plus the mock's request log.
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  let sandbox = newCoreSandbox(tag, ["store", "bash", "llm"])
  let root = sandbox.root
  # Replace the real llm with the test-only mock (t_expert pattern).
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & sandbox.sandboxBin("llm"),
    repoRoot / "tests" / "mock_llm.nim"],
    options = {poUsePath, poStdErrToStdOut})
  if waitForExit(compProc, 120_000) != 0:
    fail("mock llm failed to compile for " & tag)
    quit(1)
  compProc.close()
  let logPath = root / "mock-requests.log"

  let (server, url) = startNats()
  var nc = waitConnect(url)
  var extra: seq[(string, string)] = @[
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MOCK_CTX", $window),
    ("NIF_MOCK_ROUNDS", $rounds),
    ("NIF_MOCK_TOOLCMD", "head -c " & $toolBytes &
      " /dev/zero | tr '\\0' 'x'"),
    ("NIF_MOCK_LOG", logPath)]
  if hideCtx: extra.add(("NIF_MOCK_HIDE_CTX", "1"))
  if reserve.len > 0: extra.add(("NIF_CTX_RESERVE", reserve))
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
    extra = extra,
    logFile = root / "var" / "test-logs" / "core-" & tag & ".log")
  defer: coreProc.stopHard()
  defer: nc.close()
  defer: stopServer(server)
  doAssert waitComponent(nc, "store"), tag & ": store did not register"
  doAssert waitComponent(nc, "llm"), tag & ": mock llm did not register"

  let sessionId = "conv-" & tag & "-" & $int(epochTime())
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sessionId, "content": objective},
                  180_000)
  result.reply = turn{"reply"}.getStr("")
  result.turnError = turn{"turnError"}.getStr("")
  result.logPath = logPath
  if verify != nil:
    verify(nc, sessionId)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(resolveStoreBin(repoRoot)):
    fail("missing store binary — run `make build` first")
    quit(1)

  let tmp = tempRoot("ctxcompact")
  defer: removeDir(tmp)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var storeProc = startComponent(resolveStoreBin(repoRoot), url, root = tmp)
  defer: stopProcess(storeProc)
  doAssert waitRegistered(nc, "store"), "store did not register"

  let cat = newCatalog(nc)
  let ct = CoreTools(nc: nc, cat: cat)

  # --- 1. ctxAppend: the ledger stays 1:1 with the projection --------------
  let conv = "ctxcompact"
  var p = newPersister(ct)   # creates the conversation header, like a real session
  p.convId = conv
  p.seqNo = 0
  # The system message is the frozen nsSystem node — rebuilt from the
  # header, never persisted as a message (same shape the session runner
  # composes on the fresh path).
  var msgs: seq[JsonNode] = @[%*{"role": "system", "content": "sys"}]
  p.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
  for i in 1 .. 6:
    p.ctxAppend(msgs, %*{"role": "user", "content": "m" & $i})
  # Error-role record: consumes a seq id, is persisted for audit, but must
  # never become a node (§4.2 — excluded from context, ids unaffected).
  p.persistMsg(%*{"role": "error", "content": "boom"})
  p.ctxAppend(msgs, %*{"role": "assistant", "content": "a1"})

  check("ledger 1:1 with projection", p.nodes.len == msgs.len,
        $p.nodes.len & " vs " & $msgs.len)
  var allCanonical = true
  for i in 1 ..< p.nodes.len:
    if p.nodes[i].source != nsCanonical: allCanonical = false
  check("system node first, canonical after",
        p.nodes[0].source == nsSystem and allCanonical)
  check("canonical ids are the store keys",
        p.nodes[1].id == conv & ":000001" and
        p.nodes[^1].id == conv & ":000008", p.nodes[^1].id)
  check("projectionIndex aligned with the projection", block:
    var ok = true
    for i in 0 ..< p.nodes.len:
      if p.nodes[i].projectionIndex != i: ok = false
    ok)
  # seqs: users 1..6, error 7 (no node), assistant 8 — canonicalHigh is the
  # last canonical append, never the error record.
  check("canonicalHigh past the error record", p.canonicalHigh == 8,
        $p.canonicalHigh)

  # --- 2. resume rebuilds the ledger ---------------------------------------
  var pt = 0
  var used = 0
  var csz = 0
  let (loaded, nodes, lastSeq) = ct.loadStoredMessagesEx(conv, pt, used, csz)
  check("resume loads every non-error message", loaded.len == 7,
        $loaded.len)
  check("lastSeqNo counts the error record", lastSeq == 8, $lastSeq)
  check("resume nodes carry canonical ids",
        nodes.len == 7 and nodes[0].id == conv & ":000001" and
        nodes[^1].id == conv & ":000008")
  check("no error-role node on resume", block:
    var ok = true
    for n in nodes:
      if n.id == conv & ":000007": ok = false
    ok)
  check("loader projectionIndex is 0-based over its own list",
        nodes[3].projectionIndex == 3)
  check("canonicalHigh = last canonical node",
        nodes[^1].canonicalSeq == 8)

  # --- 3. the after cursor (projection reload, §6.2 step 4) ----------------
  # A checkpoint covering :000001..:000005 resumes the read after covered.to:
  # only the retained tail comes back, and an error record inside the tail
  # is still excluded from the nodes.
  let (tail, tailNodes, tailSeq) = ct.loadStoredMessagesEx(conv, pt, used, csz,
                                                           after = conv & ":000005")
  check("after-cursor reload returns only the tail", tail.len == 2,
        $tail.len)
  check("tail nodes start after the cursor",
        tailNodes[0].id == conv & ":000006" and
        tailNodes[1].id == conv & ":000008")
  check("tail continuation id still counts everything", tailSeq == 8,
        $tailSeq)

  # --- 4. ctxDigest binds ids and content ----------------------------------
  let d1 = ctxDigest(p.nodes, msgs, 0, msgs.high)
  let d2 = ctxDigest(p.nodes, msgs, 0, msgs.high)
  check("digest is deterministic", d1 == d2)
  check("digest names its algorithm", d1.startsWith("sha256:"))
  var mutated = msgs
  mutated[3] = %*{"role": "user", "content": "TAMPERED"}
  check("digest moves when content changes",
        ctxDigest(p.nodes, mutated, 0, mutated.high) != d1)
  check("digest moves when the covered range moves",
        ctxDigest(p.nodes, msgs, 2, msgs.high) != d1)
  # Same content under different canonical ids must digest differently —
  # the digest is over the identity ledger, not just the bodies.
  var other: seq[CtxNode]
  for n in p.nodes:
    var m = n
    if m.source == nsCanonical:
      m.id = "conv-x:" & align($m.canonicalSeq, 6, '0')
    other.add(m)
  check("digest binds canonical ids",
        ctxDigest(other, msgs, 0, msgs.high) != d1)
  check("empty range digests deterministically",
        ctxDigest(p.nodes, msgs, 3, 2) == ctxDigest(p.nodes, msgs, 3, 2))

  # --- 5. resume round-trip: appends continue after canonicalHigh ----------
  # The runner's next persist must target canonicalHigh + 1 — never reuse an
  # id the ledger already covers.
  p.ctxAppend(msgs, %*{"role": "user", "content": "after-restart"})
  check("append after canonicalHigh allocates the next id",
        p.nodes[^1].id == conv & ":000009", p.nodes[^1].id)
  check("canonicalHigh advanced", p.canonicalHigh == 9)

  # --- 6. §8 test 1 — long-turn regression (the headline) -----------------
  # One user turn, four tool rounds, each result ~30KB against an 8000-token
  # window with a 400-token reserve: the enforcing fake provider rejects any
  # request over the window, so the turn can only complete if admission's
  # ladder (prune, then trim) holds every request under it — mid-turn.
  block longTurn:
    let objective = "Keep the phrase GEMINI-ARTIFACT-7Q in your final answer."
    let r = runSandboxFixture("longturn", 8000, 4, 30_000, false, "400",
                              objective)
    check("long turn completes", r.turnError.len == 0, r.turnError)
    check("objective survives into the final answer",
          r.reply.contains("GEMINI-ARTIFACT-7Q"), r.reply)
    let (accepted, rejected) = readRequests(r.logPath)
    check("no request ever exceeded the window (provider view)",
          rejected == 0 and accepted.len >= 5,
          "accepted=" & $accepted & " rejected=" & $rejected)
    var maxSeen = 0
    for a in accepted:
      if a > maxSeen: maxSeen = a
    check("every accepted request fit the 8000-token window",
          maxSeen <= 8000, $maxSeen)

  # --- 7. §8 test 2 — fallback ladder ends in a named error ----------------
  # A window so small the frozen prefix (system prompt + tools) alone cannot
  # fit: prune has nothing to prune, trim has no second turn to drop, so the
  # ladder must end in context-recovery-required — and the enforcing
  # provider must never have seen a request at all.
  block frozenPrefix:
    let r = runSandboxFixture("frozenprefix", 300, 0, 100, false, "50",
                              "This turn can never fit the tiny window.")
    check("turn fails with context-recovery-required",
          r.turnError.contains("context-recovery-required"), r.turnError)
    check("the error names the frozen-prefix cause",
          r.turnError.contains("frozen prefix"), r.turnError)
    let (accepted, rejected) = readRequests(r.logPath)
    check("no request was ever sent over the window",
          accepted.len == 0 and rejected == 0,
          "accepted=" & $accepted & " rejected=" & $rejected)

  # --- 8. §8 test 3 — indivisible newest tool group ------------------------
  # The first request fits; the 30KB tool result it produces cannot fit even
  # after prune (floor ≈ head+tail+marker) and trim (the newest group must
  # stay). Admission catches it BEFORE the second request: context-
  # recovery-required, exactly one provider call total, no retry hammering.
  block indivisible:
    let r = runSandboxFixture("indivisible", 1500, 1, 30_000, false, "200",
                              "Produce one huge result, then answer.")
    check("turn fails with context-recovery-required",
          r.turnError.contains("context-recovery-required"), r.turnError)
    check("the error names the indivisible cause",
          r.turnError.contains("indivisible"), r.turnError)
    let (accepted, rejected) = readRequests(r.logPath)
    check("exactly one provider call — no second request with the huge result",
          accepted.len == 1 and rejected == 0,
          "accepted=" & $accepted & " rejected=" & $rejected)

  # --- 9. §6.5 — overflow recovery end to end -----------------------------
  # Capacity stays UNKNOWN (the mock hides its window): admission stands
  # down, the first oversized request reaches the provider and is rejected,
  # and the runner recovers — receipt written, ladder prunes, the same
  # logical request is retried exactly once, and the turn completes.
  block overflowRecovery:
    let objective = "Keep the phrase RECOVERY-MARKER-3F in your final answer."
    proc checkReceipt(nc: NatsConnection, sessionId: string) =
      let store = call(nc, "store", "list",
                       %*{"kind": "contextreceipt", "limit": 100}, 10_000)
      let items = store{"items"}
      check("context receipt persisted",
            items != nil and items.len == 1 and
            items[0]{"value"}{"outcome"}.getStr("") == "recovered" and
            items[0]{"value"}{"failureClass"}.getStr("") == "context-overflow",
            $store)
    let r = runSandboxFixture("recovery", 3000, 1, 20_000, true, "400",
                              objective, checkReceipt)
    check("turn completes after provider-overflow recovery",
          r.turnError.len == 0, r.turnError)
    check("objective survives the recovery",
          r.reply.contains("RECOVERY-MARKER-3F"), r.reply)
    let (accepted, rejected) = readRequests(r.logPath)
    check("exactly one rejected request (one recovery attempt)",
          rejected == 1, $rejected)
    var fits = true
    for a in accepted:
      if a > 3000: fits = false
    check("every accepted request fit the window", fits, $accepted)

  report("CTXCOMPACT")

main()
