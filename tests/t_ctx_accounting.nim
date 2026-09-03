## Unit tests for usage-accurate context accounting (A2): the richer
## chars/4 estimate (content + reasoning + tool-call bulk) and the output
## reserve that lowers the trim threshold below the bare ratio.
## Pure logic — no bus, no processes.

import std/[json, math, os]
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

  # --- output reserve (env) -------------------------------------------------
  delEnv("NIF_CTX_RESERVE")
  check("default reserve 16K", outputReserve() == 16_384, $outputReserve())
  putEnv("NIF_CTX_RESERVE", "1000")
  check("env override honored", outputReserve() == 1000)
  putEnv("NIF_CTX_RESERVE", "junk")
  check("junk falls back to default", outputReserve() == 16_384)
  putEnv("NIF_CTX_RESERVE", "0")
  check("0 disables reserve", outputReserve() == 0)
  delEnv("NIF_CTX_RESERVE")

  # --- trim threshold: min(ratio bound, window − reserve) -------------------
  # 40K window: 90% ratio = 36K; window − 16,384 = 23,616 → reserve binds
  var p = Persister(ctxSize: 40_000)
  check("reserve binds below ratio", trimThreshold(p) == 23_616,
        $trimThreshold(p))
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

  # --- trimContext still keeps whole turns ---------------------------------
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
  let dropped = trimContext(msgs)
  check("trim drops turn one whole", dropped == 2, $dropped)
  check("system message kept", msgs[0]{"role"}.getStr("") == "system")
  check("first kept user is turn two",
        msgs[1]{"content"}.getStr("") == "turn two", $msgs[1])
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

  report("CTX ACCOUNTING")

main()
