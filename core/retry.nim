## LLM auto-retry policy (B3): classification of transient errors and
## exponential-backoff delay computation. Pure logic — no bus, no clock
## side effects beyond jitter — so it unit tests trivially.
##
## Mirrors pi's `ai/src/utils/retry.ts` classification: retry the
## transient failure modes (rate limits, provider outages, dropped
## connections), fail fast on everything else (bad request, auth,
## quota/billing — retrying those is wasted latency and can make billing
## worse).

import std/[math, os, random, strutils]

type
  RetryPolicy* = object
    maxRetries*: int       ## additional attempts after the first (0 = off)
    baseDelayMs*: float    ## first backoff
    maxDelayMs*: float     ## backoff ceiling

  LlmFailureClass* = enum
    lfcTransient   ## rate limits, outages, dropped connections — backoff applies
    lfcOverflow    ## the request cannot fit the provider's context window
    lfcPermanent   ## auth, quota, bad request — fail fast

proc defaultRetryPolicy*(): RetryPolicy =
  RetryPolicy(maxRetries: 2, baseDelayMs: 500.0, maxDelayMs: 8000.0)

proc retryPolicyFromEnv*(): RetryPolicy =
  ## NIF_LLM_MAX_RETRIES overrides the additional-attempt count.
  var policy = defaultRetryPolicy()
  let v = getEnv("NIF_LLM_MAX_RETRIES").strip()
  if v.len > 0:
    try:
      let n = parseInt(v)
      if n >= 0: policy.maxRetries = n
    except CatchableError:
      discard
  policy

proc isRetryableLlmError*(msg: string): bool =
  ## True when the failure is plausibly transient and worth a retry.
  ## Classification is deliberately coarse: match machine-readable status
  ## codes first, then known provider phrases. Auth/quota/bad-request fail
  ## fast (retrying cannot succeed and billing/lockout risks grow).
  let lower = msg.toLowerAscii()
  if lower.len == 0:
    return false
  # Fail fast — permanent or caller-fixable:
  for permanent in ["401", "403", "unauthorized", "forbidden",
                    "invalid api key", "invalid_api_key", "incorrect api key",
                    "quota", "billing", "insufficient",
                    "400", "bad request", "invalid request"]:
    if lower.contains(permanent):
      return false
  # Retry — transient:
  for transient in ["429", "rate limit", "too many requests",
                    "500", "502", "503", "504", "server error",
                    "overloaded", "capacity",
                    "timeout", "timed out",
                    "connection reset", "connection refused",
                    "connection dropped", "broken pipe",
                    "eof", "econnreset", "stream error"]:
    if lower.contains(transient):
      return true
  # Nats request timeouts surface as "timeout"-family strings (matched
  # above). Anything unrecognized does not retry — an unknown failure mode
  # should surface to the human, not spin silently.
  false

proc classifyLlmError*(msg: string): LlmFailureClass =
  ## Three-way classification (docs/research/COMPACTION.md §6.5). Overflow is
  ## its own class: it is a 400-family failure, so the phrase lists above
  ## would call it permanent — and retrying it as transient would be wasted
  ## latency against a deterministic refusal. It routes to bounded overflow
  ## recovery instead: one attempt per logical request, only after a
  ## validated reduction. The llm adapter normalizes provider errors to the
  ## stable "context-overflow" prefix (the machine-readable signal); the
  ## phrase fallbacks cover providers whose messages predate the adapter
  ## wrap.
  let lower = msg.toLowerAscii()
  if lower.contains("context-overflow") or
     lower.contains("context_length_exceeded") or
     lower.contains("maximum context length") or
     lower.contains("prompt is too long") or
     lower.contains("input length exceeds") or
     lower.contains("too many input tokens"):
    return lfcOverflow
  if isRetryableLlmError(msg): return lfcTransient
  return lfcPermanent

proc windowFromOverflow*(msg: string): int =
  ## The provider's context window, parsed from the adapter's normalized
  ## overflow text ("...; window <N> tokens"). The adapter's stable suffix is
  ## the contract; scan from the END so an earlier mention of "window" in
  ## free-form provider detail cannot shadow it. 0 when absent — the caller
  ## keeps its current (unknown) capacity and recovery declines, since a
  ## reduction cannot be validated against an unknown target. §6.1: unknown
  ## capacity is reported as unknown, never zero.
  let key = "window "
  var i = msg.rfind(key)
  while i >= 0:
    var j = i + key.len
    var digits = ""
    while j < msg.len and msg[j] in {'0' .. '9'}:
      digits.add(msg[j])
      inc j
    if digits.len > 0:
      try:
        return parseInt(digits)
      except ValueError:
        discard
    if i == 0: break
    i = msg[0 ..< i].rfind(key)
  0

proc retryDelayMs*(policy: RetryPolicy, attempt: int): int =
  ## Exponential backoff with jitter for attempt 0, 1, 2... 0 when the
  ## policy is off. attempt is 0-based (the first retry).
  if policy.maxRetries <= 0 or attempt < 0:
    return 0
  let exp = pow(2.0, float(attempt))
  var delay = policy.baseDelayMs * exp
  if delay > policy.maxDelayMs: delay = policy.maxDelayMs
  # full jitter within ±25%: spreads herd retries without pathological waits
  let jitter = delay * 0.25
  result = int(delay - jitter + rand(2.0 * jitter))
  if result < 0: result = 0
