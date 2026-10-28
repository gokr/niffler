## Unit tests for the LLM retry policy (B3, core/retry.nim): classification
## of transient vs permanent failures and backoff bounds. Pure logic — no
## bus, no processes.

import std/[math, os]
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
              "Rate limit reached for model",
              # A provider cutting a generation short for its own resource
              # pressure arrives as HTTP 200 + finish_reason
              # insufficient_system_resource; the adapter words it as a stream
              # error so it lands here (docs/research/DEEPSEEK.md).
              "stream error: the provider ended the generation early (provider resource pressure)",
              "insufficient_system_resource"]:
    check("retryable: " & msg, isRetryableLlmError(msg))

  # --- classification: fail fast -------------------------------------------
  for msg in ["HTTP 401: unauthorized",
              "invalid api key",
              "provider \"x\": no API key",
              "quota exceeded for project",
              "billing error: card declined",
              "HTTP 400: messages required",
              "bad request: invalid tool schema",
              "insufficient quota",
              # Billing exhaustion stays permanent — but only the billing
              # phrasings, not every message containing "insufficient".
              "insufficient balance",
              "HTTP 402: Insufficient Balance",
              "insufficient funds for this account"]:
    check("fail fast: " & msg, not isRetryableLlmError(msg))

  # --- classification: unknown → no retry ----------------------------------
  check("empty message does not retry", not isRetryableLlmError(""))
  check("unknown failure surfaces to the human",
        not isRetryableLlmError("something entirely unexpected"))
  # 401 must win over transient words appearing elsewhere in the message
  check("permanent beats transient in one message",
        not isRetryableLlmError("connection reset during 401 auth"))
  check("resource pressure uses the transient retry budget",
        canRetry(defaultRetryPolicy(),
                 "stream error: provider resource pressure", 0) and
        not canRetry(defaultRetryPolicy(),
                     "stream error: provider resource pressure",
                     defaultRetryPolicy().maxRetries))

  # --- classification: overflow (its own class, §6.5) ----------------------
  # Real provider wordings. The normalized adapter prefix classifies on its
  # own; the raw host phrasings (Anthropic/GLM-class, synthetic, OpenAI)
  # must be caught by the phrase list even inside a 400 Bad Request.
  for msg in ["context-overflow: request ~90000 tokens exceeds the " &
                "window of 8192; window 8192 tokens",
              "llm error: error, status code: 400, status: 400 Bad " &
                "Request, message: , body: {\"error\":\"Context limit " &
                "exceeded\"}",
              "400 This model's maximum context length is 200000 tokens",
              "400 prompt is too long: 190000 tokens > 131072 maximum",
              "input length exceeds context window",
              "too many input tokens"]:
    check("overflow: " & msg, classifyLlmError(msg) == lfcOverflow)
  # ...while a 400 WITHOUT an overflow phrase stays permanent
  check("plain 400 is still permanent",
        classifyLlmError("HTTP 400: messages required") == lfcPermanent)

  # --- the refusal's own count (§6.5 recovery input) -----------------------
  # A provider that refuses names exactly what it counted, and that number is
  # the ONLY measurement of the real tokenizer a failed request yields. Prod
  # conv-aedf2d00aef8: two terminal overflow receipts because recovery
  # re-measured with the same chars/4 proxy that under-reported by ~14% and
  # concluded the candidate could not be reduced. Recovery now calibrates from
  # this number before the ladder measures anything.
  check("provider prompt count parsed from the DeepSeek refusal",
        promptTokensFromOverflow("context-overflow: This model's maximum " &
          "context length is 1048576 tokens. However, you requested " &
          "1122561 tokens (729345 in the messages, 393216 in the " &
          "completion). Please reduce the length of the messages or " &
          "completion. (request_id: 685eb992-a0bd-4063-ac09-184ee79e1ff1); " &
          "window 1048576 tokens") == 729345)
  check("thousands separators tolerated",
        promptTokensFromOverflow("requested 1,084,407 tokens " &
          "(691,191 in the messages, 393,216 in the completion)") == 691191)
  check("the completion figure is never mistaken for the prompt",
        promptTokensFromOverflow("requested 500 tokens " &
          "(300 in the messages, 200 in the completion)") == 300)
  check("absent counts yield 0, not a guess",
        promptTokensFromOverflow("context-overflow: request too large; " &
          "window 8192 tokens") == 0)
  check("the adapter's own window text does not leak into the count",
        promptTokensFromOverflow("context-overflow: request ~90000 tokens " &
          "exceeds the window of 8192; window 8192 tokens") == 0)

  # --- independent budgets and Retry-After ----------------------------------
  check("millisecond Retry-After parsed",
        retryAfterMs("HTTP 429; retry-after-ms: 1500") == 1500)
  check("seconds Retry-After parsed",
        retryAfterMs("HTTP 429; retry-after: 2") == 2000)
  check("invalid Retry-After ignored",
        retryAfterMs("HTTP 429; retry-after: later") == 0)
  let budgets = defaultRetryPolicy()
  check("hinted rate limit has no attempt cap",
        canRetry(budgets, "HTTP 429; retry-after-ms: 3000", 100))
  check("stream timeout uses its own budget",
        canRetry(budgets, "stream timed out", 1) and
        not canRetry(budgets, "stream timed out", 2))
  check("connection refused uses its own budget",
        canRetry(budgets, "connection refused", 1) and
        not canRetry(budgets, "connection refused", 2))
  check("Retry-After is capped and floored",
        retryDelayMs(budgets, 0, 1) >= 500 and
        retryDelayMs(budgets, 0, 1) <= budgets.retryAfterCapMs)

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
