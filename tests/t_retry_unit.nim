## Unit tests for the LLM retry policy (B3, core/retry.nim): classification
## of transient vs permanent failures and backoff bounds. Pure logic — no
## bus, no processes.

import std/[math, os, strutils]
import helpers
import ../core/retry

proc main() =
  # --- classification: retryable -------------------------------------------
  for msg in ["HTTP 429: too many requests",
              "503 Service Unavailable",
              "provider overloaded, try again",
              "request timed out after 300000ms",
              "connection reset by peer",
              "llm HTTP 500: internal server error",
              "EOF while streaming",
              "Rate limit reached for model"]:
    check("retryable: " & msg, isRetryableLlmError(msg))

  # --- classification: fail fast -------------------------------------------
  for msg in ["HTTP 401: unauthorized",
              "invalid api key",
              "provider \"x\": no API key",
              "quota exceeded for project",
              "billing error: card declined",
              "HTTP 400: messages required",
              "bad request: invalid tool schema",
              "insufficient quota"]:
    check("fail fast: " & msg, not isRetryableLlmError(msg))

  # --- classification: unknown → no retry ----------------------------------
  check("empty message does not retry", not isRetryableLlmError(""))
  check("unknown failure surfaces to the human",
        not isRetryableLlmError("something entirely unexpected"))
  # 401 must win over transient words appearing elsewhere in the message
  check("permanent beats transient in one message",
        not isRetryableLlmError("connection reset during 401 auth"))

  # --- backoff: bounds and growth ------------------------------------------
  let policy = RetryPolicy(maxRetries: 4, baseDelayMs: 500.0, maxDelayMs: 8000.0)
  for attempt in 0 ..< 4:
    let d = retryDelayMs(policy, attempt)
    let expected = min(500.0 * pow(2.0, float(attempt)), 8000.0)
    # full ±25% jitter around the exponential delay
    check("attempt " & $attempt & " delay " & $d & " within jitter band",
          float(d) >= expected * 0.75 and float(d) <= expected * 1.25)
  # ceiling respected (long beyond maxRetries anyway)
  var ceilingOk = true
  for i in 0 ..< 20:
    if float(retryDelayMs(policy, 10)) > 8000.0 * 1.25: ceilingOk = false
  check("backoff ceiling respected", ceilingOk)

  # --- backoff: disabled policy --------------------------------------------
  let off = RetryPolicy(maxRetries: 0, baseDelayMs: 500.0, maxDelayMs: 8000.0)
  check("disabled policy delays zero", retryDelayMs(off, 0) == 0)

  # --- env override ---------------------------------------------------------
  putEnv("NIF_LLM_MAX_RETRIES", "5")
  check("NIF_LLM_MAX_RETRIES=5 honored", retryPolicyFromEnv().maxRetries == 5)
  putEnv("NIF_LLM_MAX_RETRIES", "junk")
  check("junk falls back to default", retryPolicyFromEnv().maxRetries == 2)
  putEnv("NIF_LLM_MAX_RETRIES", "0")
  check("explicit 0 disables retries", retryPolicyFromEnv().maxRetries == 0)
  delEnv("NIF_LLM_MAX_RETRIES")
  check("unset falls back to default", retryPolicyFromEnv().maxRetries == 2)

  report("RETRY UNIT")

main()
