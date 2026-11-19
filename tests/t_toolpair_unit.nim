## Tool-pair repair (core/conversation.nim:healToolPairing) — pure contract.
##
## A strict provider validates tool-call pairing on EVERY request: each
## assistant `tool_calls` entry needs a `tool` message, and each `tool` message
## needs a pending call. A transcript that lost a record (best-effort
## persistMsg, a runner killed mid-persist, a fork copying damaged history) can
## never be sent again unless the projection is repaired — permanently, since
## the damage is in the stored history and every later request repeats it.
##
## The repair is a PROJECTION edit and a pure function of that history, so this
## test pins the properties that make it safe to run on every load:
##  * it repairs (synthesize the missing result, drop the orphan/duplicate),
##  * it invents nothing it cannot know (the synthesized body says the output
##    is GONE and names the call),
##  * it is idempotent and deterministic (a resumed turn sends the same prefix,
##    so the prompt cache survives),
##  * a healthy conversation is untouched, and the node ledger stays 1:1 with
##    the projection (COMPACTION.md §4.2).

import std/[json, strutils]
import helpers
import ../core/[conversation, dispatch]

proc call(id, name: string): JsonNode =
  %*{"id": id, "type": "function",
     "function": {"name": name, "arguments": "{}"}}

proc batch(ids: string): JsonNode =
  var calls = newJArray()
  for id in ids.split(','): calls.add(call(id, "bash"))
  %*{"role": "assistant", "content": newJNull(), "tool_calls": calls}

proc tool(id: string, body = "ok"): JsonNode =
  %*{"role": "tool", "tool_call_id": id, "name": "bash", "content": body}

proc user(body: string): JsonNode = %*{"role": "user", "content": body}

proc nodesFor(msgs: seq[JsonNode]): seq[CtxNode] =
  for i in 0 ..< msgs.len:
    result.add(CtxNode(source: nsCanonical, id: "conv:00000" & $(i + 1),
                       canonicalSeq: i + 1, projectionIndex: i))

proc repair(msgs: seq[JsonNode]):
    tuple[m: seq[JsonNode], added, dropped: int, entries: JsonNode] =
  var m = msgs
  var n = nodesFor(msgs)
  let r = healToolPairing("conv", m, n)
  check("heal keeps the ledger 1:1 with the projection", n.len == m.len)
  (m, r.added, r.dropped, r.entries)

proc main() =
  # --- a healthy conversation is untouched --------------------------------
  let healthy = @[user("hi"), batch("c1,c2"), tool("c1"), tool("c2"),
                  %*{"role": "assistant", "content": "done"}]
  let h = repair(healthy)
  check("healthy history is not repaired",
        h.added == 0 and h.dropped == 0 and h.entries.len == 0 and
        $h.m == $healthy)

  # --- the sqlite-vec shape: one lost result + one orphaned result --------
  # (the stored transcript that made every turn fail with "An assistant
  # message with 'tool_calls' must be followed by tool messages ...")
  let damaged = @[user("read the store"), batch("a,b"), tool("a"),
                  tool("zzz", "output whose call was lost"),
                  %*{"role": "assistant", "content": "next step"}]
  let d = repair(damaged)
  check("missing result is synthesized, orphan is dropped",
        d.added == 1 and d.dropped == 1, $d.entries)
  check("the batch now owns one result per declared call",
        d.m.len == damaged.len and
        d.m[1]{"tool_calls"}.len == 2 and
        d.m[2]{"tool_call_id"}.getStr("") == "a" and
        d.m[3]{"tool_call_id"}.getStr("") == "b", $d.m)
  check("the synthesized result is honest, not a fabricated success",
        d.m[3]{"content"}.getStr("").contains("no result was recorded") and
        d.m[3]{"content"}.getStr("").contains("bash") and
        d.m[3]{"name"}.getStr("") == "bash")
  # Issue #143: a lost result means UNKNOWN, never "safe to retry". The call
  # may already have written a file or started a job, and the harness cannot
  # tell; inviting a retry is what produced double effects.
  check("a lost result reports an unknown outcome, not a retry hint",
        d.m[3]{"content"}.getStr("").contains("OUTCOME IS UNKNOWN") and
        not d.m[3]{"content"}.getStr("").toLowerAscii.contains("re-run it"))
  var orphanKept = false
  for m in d.m:
    if m{"role"}.getStr("") == "tool" and
        m{"tool_call_id"}.getStr("") == "zzz": orphanKept = true
  check("the orphaned result leaves the request, nothing is fabricated",
        d.m.len == damaged.len and d.m[3]{"tool_call_id"}.getStr("") == "b" and
        not orphanKept)
  check("later history survives the repair",
        d.m[^1]{"role"}.getStr("") == "assistant" and
        d.m[^1]{"content"}.getStr("") == "next step")
  check("both repairs are named in the ledger entries", block:
    var synth = false
    var drop = false
    for e in d.entries:
      if e{"action"}.getStr("") == "synthesized" and
          e{"callId"}.getStr("") == "b": synth = true
      if e{"action"}.getStr("") == "dropped" and
          e{"toolCallId"}.getStr("") == "zzz": drop = true
    synth and drop)
  check("the synthesized node is a notice, never canonical", block:
    var ok = true
    var m = damaged
    var n = nodesFor(damaged)
    discard healToolPairing("conv", m, n)
    for node in n:
      if node.id.contains("#heal-"): ok = ok and node.source == nsNotice
    ok)

  # --- duplicates ---------------------------------------------------------
  let dup = @[batch("x"), tool("x"), tool("x", "second answer")]
  let dupR = repair(dup)
  check("a duplicate result for one call is dropped",
        dupR.added == 0 and dupR.dropped == 1 and dupR.m.len == 2, $dupR.m)

  # --- a whole lost batch: results with no surviving call -----------------
  let headless = @[user("go"), tool("gone1"), tool("gone2"),
                   %*{"role": "assistant", "content": "resumed"}]
  let headR = repair(headless)
  check("results whose batch is gone are dropped and history keeps flowing",
        headR.added == 0 and headR.dropped == 2 and headR.m.len == 2 and
        headR.m[1]{"role"}.getStr("") == "assistant")

  # --- idempotent + deterministic (prompt-cache stability) ----------------
  let once = repair(damaged)
  let twice = repair(once.m)
  check("a repaired projection is a fixed point",
        twice.added == 0 and twice.dropped == 0 and $twice.m == $once.m)
  check("the rule is deterministic across runs",
        $repair(damaged).m == $once.m)

  # --- non-tool-shaped history is never touched ---------------------------
  let plain = @[user("a"), %*{"role": "assistant", "content": "b"},
                %*{"role": "user", "content": "c"}]
  let pr = repair(plain)
  check("a conversation with no tool calls is untouched",
        pr.added == 0 and pr.dropped == 0 and $pr.m == $plain)

  # An unavailable store must not consume a sequence or mutate the projection.
  var dead = newPersister(CoreTools())
  var messages: seq[JsonNode]
  var refused = false
  try: ctxAppend(dead, messages, user("not durable"))
  except TranscriptWriteError: refused = true
  check("a failed append leaves sequence and projection untouched",
        refused and dead.seqNo == 0 and messages.len == 0)

  report("TOOLPAIR UNIT")

main()
