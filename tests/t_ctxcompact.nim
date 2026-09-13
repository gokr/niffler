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

import std/[json, os, strutils]
import natsnim
import ../core/[catalog, conversation, dispatch]
import helpers

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

  report("CTXCOMPACT")

main()
