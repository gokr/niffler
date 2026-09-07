# tokbucket — token-bucket rate limiter

- The bucket starts **full** (`tokens = capacity`).
- `_refill` advances tokens by `elapsed_seconds * refill_per_sec` since the
  last refill (init or previous take/retry call), capped at `capacity`, and
  records the new last-refill instant. Every public method refills first.
- `try_take(n)`: refill, then if `tokens >= n` subtract and return True;
  otherwise take NOTHING and return False. `n = 0` always succeeds.
- `retry_after(n)`: refill, then
  - if `n > capacity`, or `refill_per_sec == 0` with `tokens < n` →
    `math.inf` (it can never be satisfied),
  - if `tokens >= n` → `0.0`,
  - else `(n - tokens) / refill_per_sec` seconds from NOW, **rounded up to
    the next microsecond**: `math.ceil(x * 1e6) / 1e6`.
- `available`: tokens after refill, capped at capacity.
- Config errors (`capacity <= 0`, `refill_per_sec < 0`) raise `ValueError`.
