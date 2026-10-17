## Unit tests for usage-accurate context accounting (A2): the richer
## chars/4 estimate (content + reasoning + tool-call bulk) and the output
## reserve that lowers the trim threshold below the bare ratio.
## Pure logic — no bus, no processes.

import std/[json, math, os, strutils]
import helpers
import ../core/conversation

proc main() =
  # --- estimateTokens counts the full next-request payload -----------------
  let simple = @[%*{"role": "user", "content": "12345678"}]  # 8 chars → 2
  check("plain text estimate", estimateTokens(simple) == 8 + 2,
        $estimateTokens(simple))

  let thinking = @[%*{"role": "assistant", "content": "",
                      "reasoning": "12345678"}]
  check("reasoning counted", estimateTokens(thinking) == 8 + 2,
        $estimateTokens(thinking))

  let toolCall = @[%*{"role": "assistant", "content": "",
                       "tool_calls": [%*{"id": "c1", "type": "function",
                         "function": {"name": "bash",
                                      "arguments": "{\"command\":\"12345678\"}"}}]}]
  # 8 overhead + 4 name + (28 args chars /4 = 7) + 4 args extra = 23
  check("tool-call args counted", estimateTokens(toolCall) >= 15,
        $estimateTokens(toolCall))
  # ...and strictly more than content-only accounting would give
  let contentOnly = 8 + 0
  check("estimate exceeds content-only accounting",
        estimateTokens(toolCall) > contentOnly)

  # --- output reserve (env / catalog) ---------------------------------------
  delEnv("NIF_CTX_RESERVE")
  var p = Persister()
  check("default reserve 16K", outputReserve(p) == 16_384,
        $outputReserve(p))
  # A resolved catalog output cap IS the reserve: the provider counts the
  # requested max_tokens against the window at admission.
  p = Persister(ctxOutput: 384_000)
  check("catalog output cap becomes the reserve", outputReserve(p) == 384_000,
        $outputReserve(p))
  putEnv("NIF_CTX_RESERVE", "1000")
  check("env override honored", outputReserve(p) == 1000)
  putEnv("NIF_CTX_RESERVE", "junk")
  check("junk falls back to catalog/default", outputReserve(p) == 384_000)
  putEnv("NIF_CTX_RESERVE", "0")
  check("0 disables reserve", outputReserve(p) == 0)
  delEnv("NIF_CTX_RESERVE")

  # --- trim threshold: min(ratio bound, window − reserve) -------------------
  # 40K window: 90% ratio = 36K; window − 16,384 = 23,616 → reserve binds
  p = Persister(ctxSize: 40_000)
  check("reserve binds below ratio", trimThreshold(p) == 23_616,
        $trimThreshold(p))
  # A declared output cap binds well below the ratio: 1M window, deepseek's
  # 384K output → trim/admission at 616K, the failure this guards.
  p = Persister(ctxSize: 1_000_000, ctxOutput: 384_000)
  check("catalog output cap lowers the trim line", trimThreshold(p) == 616_000,
        $trimThreshold(p))
  check("admission holds the declared cap back", contextTarget(p) == 616_000,
        $contextTarget(p))
  # ...but a cap past half the window floors there instead of standing down
  p = Persister(ctxSize: 128_000, ctxOutput: 384_000)
  check("absurd cap floors at half the window", contextTarget(p) == 64_000,
        $contextTarget(p))
  # large window: ratio binds (reserve never exceeds the 90% line)
  p = Persister(ctxSize: 200_000)
  check("ratio binds for large windows", trimThreshold(p) == 180_000,
        $trimThreshold(p))
  # small window (< ~2× reserve): clamped to half the window, never negative
  p = Persister(ctxSize: 10_000)
  check("sub-reserve window clamps to half", trimThreshold(p) == 5_000,
        $trimThreshold(p))
  # reserve 0 → ratio alone
  putEnv("NIF_CTX_RESERVE", "0")
  p = Persister(ctxSize: 100_000)
  check("reserve 0 restores bare ratio", trimThreshold(p) == 90_000,
        $trimThreshold(p))
  delEnv("NIF_CTX_RESERVE")

  # --- trimTurns still keeps whole turns (now ledger-aware, §6.3) ---------
  var msgs = @[
    %*{"role": "system", "content": "sys"},
    %*{"role": "user", "content": "turn one"},
    %*{"role": "assistant", "content": "answer one"},
    %*{"role": "user", "content": "turn two"},
    %*{"role": "assistant", "content": "answer two",
       "tool_calls": [%*{"id": "c1", "type": "function",
         "function": {"name": "bash", "arguments": "{}"}}]},
    %*{"role": "tool", "tool_call_id": "c1", "content": "out"},
    %*{"role": "user", "content": "turn three"},
  ]
  var tp = Persister()
  tp.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
  for i in 1 ..< msgs.len:
    tp.nodes.add(CtxNode(source: nsCanonical, id: "c:" & align($i, 6, '0'),
                         canonicalSeq: i, projectionIndex: i))
  let dropped = tp.trimTurns(msgs, minKeepTurns)
  check("trim drops turn one whole", dropped == 2, $dropped)
  check("system message kept", msgs[0]{"role"}.getStr("") == "system")
  check("first kept user is turn two",
        msgs[2]{"content"}.getStr("") == "turn two", $msgs[2])
  check("ledger stayed 1:1 after trim", tp.nodes.len == msgs.len,
        $tp.nodes.len & " vs " & $msgs.len)
  check("omission notice replaced the dropped span",
        tp.nodes[1].source == nsNotice and
        msgs[1]{"content"}.getStr("").contains("history omitted without summary"),
        $msgs[1])
  check("notice names the covered canonical ids",
        msgs[1]{"content"}.getStr("").contains("c:000001") and
        msgs[1]{"content"}.getStr("").contains("c:000002"), $msgs[1])
  check("projectionIndex reindexed after the structural edit", block:
    var ok = true
    for i in 0 ..< tp.nodes.len:
      if tp.nodes[i].projectionIndex != i: ok = false
    ok)
  var pairs = true
  for m in msgs:
    if m{"role"}.getStr("") == "tool":
      var paired = false
      for a in msgs:
        let tcs = a{"tool_calls"}
        if tcs.isNil: continue
        for tc in tcs:
          if tc{"id"}.getStr("") == m{"tool_call_id"}.getStr(""): paired = true
      if not paired: pairs = false
  check("tool_call_id pairs stay intact", pairs)

  # --- §6.3 proportional trim -------------------------------------------
  # The rung must take the smallest whole-turn prefix that fits, not jump
  # straight to its floor. Measured on the live loss (conv-d3a5be6c05be): the
  # request needed a ~33% reduction and the floor took 59%, landing 179,550
  # tokens below the line it had to reach — history the model still had room
  # for, discarded because one oversized turn decided the boundary.
  block proportionalTrim:
    proc bigMsgs(turns, body: int): seq[JsonNode] =
      result.add(%*{"role": "system", "content": "sys"})
      for t in 0 ..< turns:
        result.add(%*{"role": "user", "content": "u" & $t & " " & repeat("x", body)})
        result.add(%*{"role": "assistant", "content": "a" & $t & " " & repeat("y", body)})

    proc ledger(msgs: seq[JsonNode]): Persister =
      result.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
      for i in 1 ..< msgs.len:
        result.nodes.add(CtxNode(source: nsCanonical,
                                 id: "c:" & align($i, 6, '0'),
                                 canonicalSeq: i, projectionIndex: i))

    # 10 turns x ~2KB; a window that requires dropping well over half but not
    # everything. The measured cutoff must land short of the floor.
    let many = bigMsgs(10, 4000)
    var pp = ledger(many)
    pp.ctxSize = 12000
    pp.ctxOutput = 0
    pp.trimThrough = 0
    putEnv("NIF_CTX_RESERVE", "0")
    let target = pp.contextTarget()
    let cutoff = pp.trimCutoffFor(many, 0)
    delEnv("NIF_CTX_RESERVE")
    check("a measured cutoff exists when the floor would overshoot",
          cutoff > 0, "cutoff=" & $cutoff & " target=" & $target)
    # The floor keeps only the latest user request; the measured cutoff keeps more.
    var floorIdx = 0
    for i in countdown(many.len - 1, 0):
      if pp.nodes[i].source == nsCanonical and
          many[i]{"role"}.getStr("") == "user":
        floorIdx = i
        break
    check("the measured cutoff keeps more turns than the floor",
          cutoff < floorIdx, "cutoff=" & $cutoff & " floor=" & $floorIdx)
    var pm = many
    let pcut = pp.trimTurns(pm, minKeepTurns, cutoff)
    check("the proportional cut drops fewer messages than the floor would",
          pcut > 0 and pcut < floorIdx - 1,
          "cut=" & $pcut & " floor=" & $(floorIdx - 1))
    check("the trimmed request now fits the target",
          estimateTokens(pm) <= target,
          "used=" & $estimateTokens(pm) & " target=" & $target)
    check("the proportional cut still keeps whole turns and the ledger 1:1",
          pm.len == pp.nodes.len and
          pm[pm.len - 1]{"role"}.getStr("") == "assistant")

    # No cutoff when no boundary is needed: the request already fits, so the
    # rung must leave the projection alone. (The caller only consults the scan
    # after admission reports pressure, so this is the "nothing to do" case.)
    var small = bigMsgs(3, 100)
    var ps = ledger(small)
    putEnv("NIF_CTX_RESERVE", "0")
    ps.ctxSize = 1_000_000
    check("a fitting request reports no cutoff",
          ps.trimCutoffFor(small, 0) == 0,
          "cutoff=" & $ps.trimCutoffFor(small, 0) &
          " used=" & $estimateTokens(small) & " target=" & $ps.contextTarget())
    # The structural floor is reached: even keeping only the newest user request
    # leaves the candidate over the target, so there is nothing measured to
    # prefer — the caller must keep its floor.
    var tight = bigMsgs(3, 100)
    putEnv("NIF_CTX_RESERVE", "0")
    ps.ctxSize = 100
    check("a candidate still over target at the floor reports no cutoff",
          ps.trimCutoffFor(tight, 0) == 0,
          "cutoff=" & $ps.trimCutoffFor(tight, 0) &
          " used=" & $estimateTokens(tight) & " target=" & $ps.contextTarget())
    delEnv("NIF_CTX_RESERVE")

  # --- A3: cache hit-rate arithmetic ---------------------------------------
  # The runner accumulates Σprompt and Σcached across responses reporting
  # details, then reports hitRate = read*100/prompt (1 decimal). Verify the
  # rounding mode used in conversation.nim (math.round, half-away-from-zero).
  check("hit rate rounding (2/3 → 66.7)",
        round(2.0 * 100.0 / 3.0, 1) == 66.7)
  check("hit rate rounding (80/100 → 80.0)",
        round(80.0 * 100.0 / 100.0, 1) == 80.0)
  check("hit rate zero prompt never divides (guard is prompt > 0)",
        round(0.0 * 100.0 / 1.0, 1) == 0.0)

  # --- A4: wake-budget accounting (docs/WIRE.md "Autonomous wake") --------
  # A wake turn is a user message marked notice.kind == "wake"; the budget
  # counts the trailing run of those behind the last real user input, and
  # machinery messages (settlement notices, process exits, mails) neither
  # count nor reset it.
  proc um(c: string): JsonNode = %*{"role": "user", "content": c}
  proc wake(c: string): JsonNode =
    %*{"role": "user", "content": c, "notice": {"kind": "wake"}}
  proc notice(c: string): JsonNode =
    %*{"role": "user", "content": c, "notice": {"kind": "subagent-settled"}}
  proc am(c: string): JsonNode = %*{"role": "assistant", "content": c}

  check("no history means no wakes spent",
        consecutiveWakeTurns(@[]) == 0)
  check("a real user message spends nothing",
        consecutiveWakeTurns(@[um("hello")]) == 0)
  check("one wake turn counts as one",
        consecutiveWakeTurns(@[um("hello"), wake("w1"), am("ok")]) == 1)
  check("three wake turns count as three",
        consecutiveWakeTurns(@[um("hello"), wake("w1"), am("ok"),
                               notice("child done"), wake("w2"), am("ok"),
                               notice("child done"), wake("w3"), am("ok")]) == 3)
  check("a later real user message resets the run",
        consecutiveWakeTurns(@[um("hello"), wake("w1"), am("ok"),
                               um("real"), wake("w2"), am("ok")]) == 1)
  check("machinery never counts as a wake",
        consecutiveWakeTurns(@[um("hello"), notice("a"), notice("b")]) == 0)
  check("default budget is three", wakeBudget() == 3)
  putEnv("NIF_AGENT_WAKES", "7")
  check("budget honors NIF_AGENT_WAKES", wakeBudget() == 7)
  putEnv("NIF_AGENT_WAKES", "0")
  check("zero disables wakes", wakeBudget() == 0)
  putEnv("NIF_AGENT_WAKES", "junk")
  check("junk falls back to three", wakeBudget() == 3)
  delEnv("NIF_AGENT_WAKES")
  check("notice hold is on by default", noticeHoldEnabled())
  putEnv("NIF_AGENT_NOTICE_HOLD", "0")
  check("notice hold can be disabled", not noticeHoldEnabled())
  putEnv("NIF_AGENT_NOTICE_HOLD", "false")
  check("notice hold accepts a word", not noticeHoldEnabled())
  delEnv("NIF_AGENT_NOTICE_HOLD")

  report("CTX ACCOUNTING")

main()
