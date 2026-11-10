## Settlement-notice policy — the pure rules both the conversation loop and
## dispatch read (docs/WIRE.md "Settlement notices").
##
## Why this is its own module rather than living in `conversation.nim`: the
## wake budget is not only an admission rule, it is a FACT A CLIENT NEEDS
## ("if my background job finishes, will this conversation be woken?"), and
## the surface that publishes instance facts is `catalog {op: list}` in
## `dispatch.nim`. `dispatch` cannot import `conversation` (conversation
## imports dispatch), so the rule moved down to a leaf instead of being
## re-stated in a second place — two copies of "how many wakes are allowed"
## is exactly the mirror-of-policy shape AGENTS.md warns about, and the one
## that drifts is always the one people read.
##
## Nothing here touches the store, the bus or provider-visible history: these
## are pure functions of the environment and of stored MESSAGE RECORDS.

import std/[json, os, strutils]

proc wakeBudget*(): int =
  ## Consecutive autonomous wake turns a conversation may run before a real
  ## user message must reset the budget (dsh's maxConsecutiveWakes). A wake
  ## turn is a session call with `wake: true` that exists only to fold
  ## pending background-settlement notices into an idle conversation. 0
  ## disables wakes entirely. Exported for tests and published in the catalog
  ## so a client can tell a human whether a completion will reach them.
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
