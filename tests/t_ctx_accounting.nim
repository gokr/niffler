## Unit tests for usage-accurate context accounting (A2): the richer
## chars/4 estimate (content + reasoning + tool-call bulk) and the output
## reserve that lowers the trim threshold below the bare ratio.
## Pure logic — no bus, no processes.

import std/[json, math, os, strutils, tables]
import helpers
import ../core/catalog
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

  # --- §6.3 tier-1 stub: superseded reads ---------------------------------
  # The rung elides whole tool results whose files were WRITTEN LATER. Its
  # inputs are the tool's own declarations, so these cases pin the rules: which
  # results are eligible (read effect), how staleness is decided (a later write
  # to a declared path), and what must never be touched (write results, the
  # live working set, undetermined calls).
  block staleReadStub:
    proc schemaFor(tool: string): JsonNode =
      case tool
      of "read": %*{"x-harness": {"effect": "read",
                                   "workspace": {"pathFields": ["path"]}}}
      of "edit": %*{"x-harness": {"effect": "write",
                                   "writes": {"paths": ["path"]},
                                   "workspace": {"pathFields": ["path"]}}}
      of "grep": %*{"x-harness": {"effect": "read",
                                   "workspace": {"pathFields": ["glob"]}}}
      else: %*{"x-harness": {"effect": "write"}}

    proc call(cat: Catalog, id, name, args: string): JsonNode =
      %*{"role": "assistant", "content": "",
         "tool_calls": [%*{"id": id, "type": "function",
                            "function": {"name": name, "arguments": args}}]}

    proc resultOf(id, name, body: string): JsonNode =
      %*{"role": "tool", "tool_call_id": id, "name": name, "content": body}

    # A catalog whose registry answers the fake schemas above (same shape
    # t_discover builds: ComponentReg + ToolReg, no bus).
    var cat = Catalog(components: initTable[string, ComponentReg](),
                      toolIndex: initTable[string, string]())
    for tool in ["read", "edit", "grep"]:
      let owner = if tool == "grep": "grep" else: "edit"
      cat.toolIndex[tool] = owner
      if owner notin cat.components:
        cat.components[owner] = ComponentReg(name: owner)
      cat.components[owner].tools.add(
        ToolReg(name: tool, component: owner, schema: schemaFor(tool)))

    # read A -> STALE, read B -> kept (never written), edit A -> protected,
    # grep C -> kept (its path was never written).
    let body = repeat("x", 4000)
    var msgs = @[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "turn one"},
      call(cat, "c1", "read", "{\"path\": \"a.nim\"}"),
      resultOf("c1", "read", body),
      call(cat, "c2", "read", "{\"path\": \"b.nim\"}"),
      resultOf("c2", "read", body),
      call(cat, "c3", "grep", "{\"glob\": \"*.zzz\"}"),
      resultOf("c3", "grep", body),
      %*{"role": "user", "content": "turn two"},
      call(cat, "c4", "edit", "{\"path\": \"a.nim\"}"),
      resultOf("c4", "edit", "ok"),
      %*{"role": "user", "content": "turn three"},
    ]
    var sp = persisterForCatalog(cat)
    sp.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
    for i in 1 ..< msgs.len:
      sp.nodes.add(CtxNode(source: nsCanonical, id: "c:" & align($i, 6, '0'),
                           canonicalSeq: i, projectionIndex: i))
    let saved = sp.stubResults(msgs)
    check("a read superseded by a later write is stubbed",
          msgs[3]{"content"}.getStr("").startsWith(stubTag),
          msgs[3]{"content"}.getStr(""))
    check("the stub still points at the original by recall ref",
          msgs[3]{"content"}.getStr("").contains("c:000003") and
          msgs[3]{"content"}.getStr("").contains("context_recall"),
          msgs[3]{"content"}.getStr(""))
    check("tool_call_id and tool name survive the stub",
          msgs[3]{"tool_call_id"}.getStr("") == "c1" and
          msgs[3]{"name"}.getStr("") == "read")
    check("a read that was never written again is untouched",
          msgs[5]{"content"}.getStr("").len == body.len)
    check("a write tool's own result is never stubbed",
          msgs[10]{"content"}.getStr("") == "ok")
    check("a read whose glob was never written is untouched",
          msgs[7]{"content"}.getStr("").len == body.len)
    check("only the stale read was elided", saved == body.len - msgs[3]{"content"}.getStr("").len,
          "saved=" & $saved)
    check("the stub is recorded for replay",
          sp.prunes.len == 1 and sp.prunes[0].full and
          sp.prunes[0].id == "c:000003", $sp.prunes.len)
    check("stubbing is idempotent", sp.stubResults(msgs) == 0)

    # Nothing stale at all: the rung is a no-op.
    var msgs2 = @[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "turn"},
      call(cat, "d1", "read", "{\"path\": \"untouched.nim\"}"),
      resultOf("d1", "read", body),
      %*{"role": "user", "content": "later"},
    ]
    var sp2 = persisterForCatalog(cat)
    sp2.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
    for i in 1 ..< msgs2.len:
      sp2.nodes.add(CtxNode(source: nsCanonical, id: "d:" & align($i, 6, '0'),
                            canonicalSeq: i, projectionIndex: i))
    check("no stale reads means no stubs", sp2.stubResults(msgs2) == 0)

    # The last few messages are protected: the immediate working set (a tool
    # call and its result). Everything older that was superseded is fair game —
    # deliberately so, because a long agentic turn keeps all of its own tool
    # history after the latest user message, and protecting that would leave the
    # rung empty exactly when pressure arrives.
    # One assistant message carrying two edits keeps the tail exactly at
    # stubProtectRecent: the live.nim read (index 6) sits inside the protected
    # tail while still being superseded by the writes at index 7.
    let bothEdits = %*{"role": "assistant", "content": "",
      "tool_calls": [
        %*{"id": "e3", "type": "function",
           "function": {"name": "edit", "arguments": "{\"path\": \"old.nim\"}"}},
        %*{"id": "e4", "type": "function",
           "function": {"name": "edit", "arguments": "{\"path\": \"live.nim\"}"}}]}
    var msgs3 = @[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "old turn"},
      call(cat, "e1", "read", "{\"path\": \"old.nim\"}"),
      resultOf("e1", "read", body),
      %*{"role": "user", "content": "the current turn"},
      call(cat, "e2", "read", "{\"path\": \"live.nim\"}"),
      resultOf("e2", "read", body),
      bothEdits,
      resultOf("e3", "edit", "ok"),
      resultOf("e4", "edit", "ok"),
    ]
    var sp3 = persisterForCatalog(cat)
    sp3.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
    for i in 1 ..< msgs3.len:
      sp3.nodes.add(CtxNode(source: nsCanonical, id: "e:" & align($i, 6, '0'),
                            canonicalSeq: i, projectionIndex: i))
    let saved3 = sp3.stubResults(msgs3)
    check("an older superseded read is stubbed",
          msgs3[3]{"content"}.getStr("").startsWith(stubTag),
          msgs3[3]{"content"}.getStr(""))
    check("a superseded read inside the protected tail is kept",
          msgs3[6]{"content"}.getStr("").len == body.len,
          "protected=" & $stubProtectRecent & " len=" &
          $msgs3[6]{"content"}.getStr("").len)
    check("the protected tail is bounded — only the older read was elided",
          saved3 == body.len - msgs3[3]{"content"}.getStr("").len,
          "saved=" & $saved3)

  # --- §6.3 stub is wired into prune --------------------------------------
  # The rung's rules are pinned above; this proves the WIRING, which is what a
  # regression would quietly drop: pruneContext must include the stale-read stub
  # in the bytes it reports to admission.
  block stubWiring:
    proc schemaFor(tool: string): JsonNode =
      case tool
      of "read": %*{"x-harness": {"effect": "read",
                                   "workspace": {"pathFields": ["path"]}}}
      of "edit": %*{"x-harness": {"effect": "write",
                                  "writes": {"paths": ["path"]},
                                  "workspace": {"pathFields": ["path"]}}}
      else: %*{"x-harness": {"effect": "write"}}
    var cat = Catalog(components: initTable[string, ComponentReg](),
                      toolIndex: initTable[string, string]())
    for tool in ["read", "edit"]:
      let owner = "edit"
      cat.toolIndex[tool] = owner
      if owner notin cat.components:
        cat.components[owner] = ComponentReg(name: owner)
      cat.components[owner].tools.add(
        ToolReg(name: tool, component: owner, schema: schemaFor(tool)))
    let body = repeat("x", 4000)
    var msgs = @[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user", "content": "read it"},
      %*{"role": "assistant", "content": "",
         "tool_calls": [%*{"id": "r1", "type": "function",
                           "function": {"name": "read",
                                        "arguments": "{\"path\": \"a.nim\"}"}}]},
      %*{"role": "tool", "tool_call_id": "r1", "name": "read", "content": body},
      %*{"role": "assistant", "content": "",
         "tool_calls": [%*{"id": "w1", "type": "function",
                           "function": {"name": "edit",
                                        "arguments": "{\"path\": \"a.nim\"}"}}]},
      %*{"role": "tool", "tool_call_id": "w1", "name": "edit", "content": "ok"},
      %*{"role": "user", "content": "and now the filler"},
      %*{"role": "assistant", "content": "done"},
      %*{"role": "user", "content": "tail one"},
      %*{"role": "assistant", "content": "done"},
    ]
    var wp = persisterForCatalog(cat)
    wp.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
    for i in 1 ..< msgs.len:
      wp.nodes.add(CtxNode(source: nsCanonical, id: "w:" & align($i, 6, '0'),
                           canonicalSeq: i, projectionIndex: i))
    let saved = wp.pruneContext(msgs)
    check("pruneContext reports the stale-read stub it applied",
          saved >= body.len - msgs[3]{"content"}.getStr("").len and
          msgs[3]{"content"}.getStr("").startsWith(stubTag),
          "saved=" & $saved & " content=" & msgs[3]{"content"}.getStr("")[0 .. 60])

  # --- §6.3 tier 2: declared derivable results ----------------------------
  # The destructive tier: a non-stale result may be elided only (a) when the
  # tool DECLARED it derivable and (b) at the trim line, never at the ordinary
  # trigger. Both halves are asserted, because (b) is a policy the unit seam
  # cannot show — it lives in pruneContext's default versus checkContext's
  # escalation.
  block derivableTier:
    proc schemaFor(tool: string): JsonNode =
      case tool
      of "read": %*{"x-harness": {"effect": "read", "derivable": true}}
      of "fetch": %*{"x-harness": {"effect": "read"}}          # no declaration
      of "api": %*{"x-harness": {"effect": "write", "derivable": true}}
      of "edit": %*{"x-harness": {"effect": "write",
                                  "writes": {"paths": ["path"]}}}
      else: %*{"x-harness": {"effect": "write"}}
    var cat = Catalog(components: initTable[string, ComponentReg](),
                      toolIndex: initTable[string, string]())
    for tool in ["read", "fetch", "api", "edit"]:
      let owner = if tool == "edit": "edit" else: tool
      cat.toolIndex[tool] = owner
      if owner notin cat.components:
        cat.components[owner] = ComponentReg(name: owner)
      cat.components[owner].tools.add(
        ToolReg(name: tool, component: owner, schema: schemaFor(tool)))
    let body = repeat("x", 4000)
    proc fixture(): seq[JsonNode] =
      result = @[
        %*{"role": "system", "content": "sys"},
        %*{"role": "user", "content": "old request"},
        %*{"role": "assistant", "content": "",
           "tool_calls": [%*{"id": "r1", "type": "function",
                             "function": {"name": "read", "arguments": "{}"}}]},
        %*{"role": "tool", "tool_call_id": "r1", "name": "read",
           "content": body},
        %*{"role": "assistant", "content": "",
           "tool_calls": [%*{"id": "f1", "type": "function",
                             "function": {"name": "fetch", "arguments": "{}"}}]},
        %*{"role": "tool", "tool_call_id": "f1", "name": "fetch",
           "content": body},
        %*{"role": "assistant", "content": "",
           "tool_calls": [%*{"id": "a1", "type": "function",
                             "function": {"name": "api", "arguments": "{}"}}]},
        %*{"role": "tool", "tool_call_id": "a1", "name": "api",
           "content": body},
        %*{"role": "user", "content": "the current turn"},
        %*{"role": "assistant", "content": "working"},
        %*{"role": "user", "content": "tail"},
        %*{"role": "assistant", "content": "done"},
      ]
    proc persist(): Persister =
      result = persisterForCatalog(cat)
      result.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
      for i in 1 ..< 12:
        result.nodes.add(CtxNode(source: nsCanonical,
                                 id: "t:" & align($i, 6, '0'),
                                 canonicalSeq: i, projectionIndex: i))
    # Tier 1 alone: nothing is stale here, so nothing may be elided — even
    # though `read` and `api` declared themselves derivable.
    var t1 = fixture()
    var p1 = persist()
    check("tier 1 does not elide a merely derivable result",
          p1.stubResults(t1, smStale) == 0)
    # Tier 2: the declared ones go; the undeclared read-effect one does not.
    var t2 = fixture()
    var p2 = persist()
    let saved2 = p2.stubResults(t2, smDerivable)
    check("tier 2 elides a declared-derivable result",
          t2[3]{"content"}.getStr("").startsWith(stubTag) and
          saved2 > 0, "content=" & t2[3]{"content"}.getStr("")[0 .. 40])
    check("tier 2 leaves an UNDECLARED read-effect result alone",
          t2[5]{"content"}.getStr("").len == body.len,
          "fetch len=" & $t2[5]{"content"}.getStr("").len)
    check("tier 2 elides a declared result even at write effect",
          t2[7]{"content"}.getStr("").startsWith(stubTag),
          "api content=" & t2[7]{"content"}.getStr("")[0 .. 40])
    # `edit` declares no `derivable`, so even at tier 2 its own result stays.
    var t3 = fixture()
    var p3 = persist()
    t3.insert(%*{"role": "assistant", "content": "",
                 "tool_calls": [%*{"id": "w1", "type": "function",
                                   "function": {"name": "edit",
                                                "arguments": "{\"path\": \"x\"}"}}]}, 8)
    t3.insert(%*{"role": "tool", "tool_call_id": "w1", "name": "edit",
                 "content": body}, 9)
    p3.nodes.insert(CtxNode(source: nsCanonical, id: "t:000008b",
                            canonicalSeq: 108, projectionIndex: 8), 8)
    p3.nodes.insert(CtxNode(source: nsCanonical, id: "t:000009b",
                            canonicalSeq: 109, projectionIndex: 9), 9)
    discard p3.stubResults(t3, smDerivable)
    check("a write tool that declares nothing is never elided by tier 2",
          t3[9]{"content"}.getStr("").len == body.len,
          "edit len=" & $t3[9]{"content"}.getStr("").len)
    check("tier 2 preserves the recall ref and machine fields",
          t2[3]{"content"}.getStr("").contains("t:000003") and
          t2[3]{"content"}.getStr("").contains("context_recall") and
          t2[3]{"tool_call_id"}.getStr("") == "r1")
    check("tier 2 is idempotent", p2.stubResults(t2, smDerivable) == 0)

  # --- §6.3 tier 2 substitutes for trim -----------------------------------
  # The behavior change the ctxcompact fixture's substitution exposed: when the
  # window is tight and results are declared re-obtainable, the stub tier frees
  # the room and the DESTRUCTIVE rung no longer runs — no turns are dropped and
  # no trim watermark is written. That is the whole point of the tier, so it is
  # asserted directly rather than inferred from a fixture's side effects.
  block tier2SparesTurns:
    proc schemaFor(tool: string): JsonNode =
      %*{"x-harness": {"effect": "write", "derivable": true}}
    var cat = Catalog(components: initTable[string, ComponentReg](),
                      toolIndex: initTable[string, string]())
    cat.toolIndex["bash"] = "bash"
    cat.components["bash"] = ComponentReg(name: "bash", tools: @[
      ToolReg(name: "bash", component: "bash", schema: schemaFor("bash"))])
    let body = repeat("x", 4000)
    proc fixture(): seq[JsonNode] =
      result = @[%*{"role": "system", "content": "sys"}]
      for t in 1 .. 6:
        result.add(%*{"role": "user", "content": "turn " & $t})
        result.add(%*{"role": "assistant", "content": "",
                      "tool_calls": [%*{"id": "b" & $t, "type": "function",
                                        "function": {"name": "bash",
                                                     "arguments": "{}"}}]})
        result.add(%*{"role": "tool", "tool_call_id": "b" & $t,
                      "name": "bash", "content": body})
    proc persist(): Persister =
      result = persisterForCatalog(cat)
      result.nodes = @[CtxNode(source: nsSystem, projectionIndex: 0)]
      for i in 1 ..< 19:
        result.nodes.add(CtxNode(source: nsCanonical,
                                 id: "d:" & align($i, 6, '0'),
                                 canonicalSeq: i, projectionIndex: i))
    # With the tier available, the derivable results go and trim is not needed.
    var m1 = fixture()
    var p1 = persist()
    p1.ctxSize = 4000
    putEnv("NIF_CTX_RESERVE", "0")
    let before = estimateTokens(m1)
    let regained = p1.stubResults(m1, smDerivable)
    check("tier 2 frees room without dropping a turn",
          regained > 0 and m1.len == 19 and
          estimateTokens(m1) < before and p1.trimThrough == 0,
          "regained=" & $regained & " msgs=" & $m1.len &
          " trimThrough=" & $p1.trimThrough)
    var usersKept = 0
    for m in m1:
      if m{"role"}.getStr("") == "user": inc usersKept
    check("every user turn survived the substitution", usersKept == 6,
          "users kept=" & $usersKept)
    check("the tool results were stubbed, not deleted",
          m1.len == 19 and m1[3]{"content"}.getStr("").startsWith(stubTag) and
          m1[3]{"tool_call_id"}.getStr("") == "b1")
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
