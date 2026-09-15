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
    maxStreamRetries*: int ## bounded retries when output may already be billed
    maxConnectRetries*: int ## bounded local connection retries
    retryAfterCapMs*: int  ## maximum server-directed wait (default one hour)

  RetryKind* = enum
    rkTransient       ## provider outage or other retryable transient
    rkRateLimitHint   ## 429/rate limit with a Retry-After hint: unbounded
    rkRateLimitNoHint ## 429/rate limit without a hint: bounded
    rkStreamTimeout   ## stream timeout: bounded because output may be billed
    rkConnectRefused  ## local connection failure: bounded
    rkPermanent       ## not safe or useful to retry

  LlmFailureClass* = enum
    lfcTransient   ## rate limits, outages, dropped connections — backoff applies
    lfcOverflow    ## the request cannot fit the provider's context window
    lfcPermanent   ## auth, quota, bad request — fail fast

proc defaultRetryPolicy*(): RetryPolicy =
  RetryPolicy(maxRetries: 2, baseDelayMs: 500.0, maxDelayMs: 8000.0,
              maxStreamRetries: 2, maxConnectRetries: 2,
              retryAfterCapMs: 3_600_000)

proc envNonNegative(name: string, fallback: int): int =
  let v = getEnv(name).strip()
  if v.len == 0: return fallback
  try:
    let n = parseInt(v)
    if n >= 0: return n
  except CatchableError:
    discard
  fallback

proc retryPolicyFromEnv*(): RetryPolicy =
  ## NIF_LLM_MAX_RETRIES overrides the general/no-hint additional-attempt
  ## count. The narrower budgets can be tuned independently for failures whose
  ## cost differs: stream timeouts may have billed output, while a hinted 429
  ## is safe to wait out indefinitely.
  var policy = defaultRetryPolicy()
  policy.maxRetries = envNonNegative("NIF_LLM_MAX_RETRIES", policy.maxRetries)
  policy.maxStreamRetries = envNonNegative("NIF_LLM_MAX_STREAM_RETRIES",
                                           policy.maxStreamRetries)
  policy.maxConnectRetries = envNonNegative("NIF_LLM_MAX_CONNECT_RETRIES",
                                            policy.maxConnectRetries)
  policy.retryAfterCapMs = envNonNegative("NIF_LLM_RETRY_AFTER_CAP_MS",
                                          policy.retryAfterCapMs)
  policy

proc retryAfterMs*(msg: string): int =
  ## Parse the normalized retry hint appended by adapters. Both forms are
  ## accepted so non-HTTP adapters can pass seconds directly:
  ## `retry-after-ms: 1500` and `retry-after: 2`. Invalid/missing hints are 0.
  let lower = msg.toLowerAscii()
  let msMarker = "retry-after-ms:"
  let secMarker = "retry-after:"
  var marker = ""
  var at = lower.find(msMarker)
  var millis = true
  if at >= 0:
    marker = msMarker
  else:
    at = lower.find(secMarker)
    millis = false
    marker = secMarker
  if at < 0: return 0
  var raw = msg[at + marker.len .. ^1].strip()
  let stopAt = raw.find({']', ';', '\n', '\r'})
  if stopAt >= 0: raw = raw[0 ..< stopAt].strip()
  try:
    let n = parseFloat(raw)
    if n <= 0: return 0
    let value = if millis: n else: n * 1000.0
    if value >= float(high(int)): return high(int)
    return int(value)
  except CatchableError:
    0

proc retryKind*(msg: string): RetryKind =
  ## Classify the failure into an independent budget. Permanent markers win
  ## over transient words, matching is intentionally conservative.
  let lower = msg.toLowerAscii()
  if lower.len == 0: return rkPermanent
  for permanent in ["401", "403", "unauthorized", "forbidden",
                    "invalid api key", "invalid_api_key", "incorrect api key",
                    "quota", "billing", "insufficient",
                    "400", "bad request", "invalid request"]:
    if lower.contains(permanent): return rkPermanent
  let limited = lower.contains("429") or lower.contains("rate limit") or
                lower.contains("too many requests")
  if limited:
    return if retryAfterMs(msg) > 0: rkRateLimitHint
           else: rkRateLimitNoHint
  if lower.contains("connection refused") or lower.contains("econnrefused"):
    return rkConnectRefused
  if lower.contains("timeout") or lower.contains("timed out"):
    return rkStreamTimeout
  for transient in ["500", "502", "503", "504", "server error",
                    "overloaded", "capacity", "connection reset",
                    "connection dropped", "broken pipe", "eof", "econnreset",
                    "stream error"]:
    if lower.contains(transient): return rkTransient
  rkPermanent

proc canRetry*(policy: RetryPolicy, msg: string, attempt: int): bool =
  ## attempt is zero-based (0 = first retry). A server-directed rate-limit
  ## wait has no attempt cap; all other budgets are independently bounded.
  if attempt < 0 or policy.maxRetries <= 0: return false
  case retryKind(msg)
  of rkRateLimitHint: true
  of rkRateLimitNoHint, rkTransient: attempt < policy.maxRetries
  of rkStreamTimeout: attempt < policy.maxStreamRetries
  of rkConnectRefused: attempt < policy.maxConnectRetries
  of rkPermanent: false

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

proc retryDelayMs*(policy: RetryPolicy, attempt: int,
                   requestedMs = 0): int =
  ## Exponential backoff with jitter for attempt 0, 1, 2... A positive
  ## requestedMs is a server Retry-After hint: honor it, applying the local
  ## safety cap and a small floor so a gateway saying "0" cannot create a
  ## hot loop. attempt is 0-based (the first retry).
  if attempt < 0: return 0
  if requestedMs > 0:
    let floorMs = max(int(policy.baseDelayMs), 1)
    let capMs = max(policy.retryAfterCapMs, floorMs)
    return min(max(requestedMs, floorMs), capMs)
  if policy.maxRetries <= 0:
    return 0
  let exp = pow(2.0, float(attempt))
  var delay = policy.baseDelayMs * exp
  if delay > policy.maxDelayMs: delay = policy.maxDelayMs
  # full jitter within ±25%: spreads herd retries without pathological waits
  let jitter = delay * 0.25
  result = int(delay - jitter + rand(2.0 * jitter))
  if result < 0: result = 0
