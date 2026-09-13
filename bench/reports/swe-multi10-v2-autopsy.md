# Multi10 v2 autopsy — what actually failed and why

Run: `swe-multi10-dsv41-high-v2` (DeepSeek V4.1 Flash @ high, 3 lanes × 10 tasks).
Grading: official (SWE-bench Multilingual 5.0.2 docker, hidden tests).

## Scoreboard (official grading)

| task | niffler | claudecode | pi | what actually happened |
|---|---|---|---|---|
| axios | ✓ | ✓ | ✓ | solved by all |
| docusaurus | ✓ | ✓ | ✓ | solved by all |
| gin | ✓ | ✓ | ✓ | solved by all |
| nushell | ✓ | 429* | ✗ | niffler solved it; CC's *final* call was rate-limited (18 turns in); pi's patch didn't compile |
| fmt | ✗ | ✓ | ✗ | all three fixed the new test; niffler+pi **regressed ZeroFlag** (PASS_TO_PASS) |
| redis | 429 | ✓ | 429 | only CC has data — the others never started |
| rubocop | 429 | ✓ | 429 | only CC has data — the others never started |
| caddy | ✗ | ✗ | ✗ | all 3 converge on the same wrong fix |
| jq | ✗ | ✗ | ✗ | **eval bug** — build breaks on a pre-existing README artifact |
| tokio | ✗ | ✗ | ✗ | **eval bug** — cargo manifest parse failure; tests never ran |

**niffler 4/8 attempted** (2 no-start) · **claudecode 7/10** · **pi 3/8 attempted** (2 no-start).
v1 official was 6/6/6.

## Infra: Synthetic 429 rate limits (4 cells)

niffler redis, niffler rubocop, pi redis, pi rubocop died on the *first* LLM call:
`429 "You've exceeded your subscription rate limits"`. A fifth (pi nushell) died on
its *final* call after 18 turns. These are not model failures. Fix: retry-with-
backoff on 429 in the adapters, or rerun the 4 cells (the lanes' windows
collided — CC's same-task cells ran at different times and got through).

## Eval-environment bugs (2 tasks ungradeable for everyone, both runs)

**jq-2235** — the task image's working tree ships a pre-existing `M README`
modification that the agent did not make. `verify.mjs` captures the candidate
patch as `git diff base`, so the artifact rides along; in the eval container the
spurious README change breaks the build (`No rule to make target 'README'`) and
nothing runs. All three lanes' actual `src/main.c` fixes were never graded.
*Durable fix*: the harness should snapshot the repo state at session start and
have verify.mjs diff final-vs-start instead of final-vs-base.

**tokio-4384** — `error: failed to parse manifest …/getrandom-0.4.3/Cargo.toml`
in the image's cargo registry cache; cargo dies before compiling anything.
Ungradeable regardless of patch. Both runs, all lanes.

## Convergent wrong fix: caddy-6115 (all 3 lanes, both runs, ~46-byte-identical diffs)

The issue narrative implies the sticky-cookie should gain `Secure: true` +
`SameSite: None`. All three agents implemented exactly that in
`CookieHashSelection.Select`. The hidden test pins the opposite:
`cookieHashPolicy should set cookie Secure attribute to false when request is
not secure` → `--- FAIL: TestCookieHashPolicy`. The real fix must make Secure
*conditional* (request.TLS-style) — the issue text actively misleads, and every
lane followed it off the cliff. Note: all three wrote 646-byte diffs; there is
no signal in the harness output telling the agent its fix is wrong (the "never
run tests" rule hides it by design).

## fmt-1683: minimalism beats fidelity (CC ✓, niffler ✗, pi ✗)

The hidden test adds `%-5c`, `%-5hhi`, `%-5d` expectations. niffler and pi
both wrote the *upstream-style* fix (reset fill + guard numeric align, 785-byte
identical diffs): it **passed the new test** (F2P 1/1) but regressed
`PrintfTest.ZeroFlag` (P2P 34+1 / 7+1). CC's one-liner —
`if (fmt_specs.align != align::left) fmt_specs.align = align::right;` —
passes the new test and touches nothing else. Lesson: under hidden PASS_TO_PASS
suits, the *smallest* semantics-preserving change wins; "more correct" fixes
that alter adjacent behavior lose.

## Token / cache / time / tools (attempted cells only)

| metric | niffler | claudecode | pi |
|---|---|---|---|
| avg agent time | 242s | 231s | 866s |
| avg turns | 15.6 | 22.1 | 24.9 |
| avg uncached in | 27.9k | 0 | 51.0k |
| avg cache read | 311.7k | 253.3k | 522.5k |
| avg out | 11.6k | 5.2k | 56.9k |
| cache hit rate | 91.8% | 100% (explicit, 210k writes) | 91.1% |
| run cost (provider) | $0.69 | $0.64 | $1.54 |
| run cost (official DeepSeek) | $0.194 | $0.140 | $0.694 |
| tools | bash 44%, read 36%, grep 9%, edit 7%, **lsp ×2** | Bash 57%, Read 34%, Edit 6% | bash 71%, read 21% |

Notables:
- **The lsp tool was invoked for the first time in a graded run** (niffler,
  discover + invoke twice). With warmup now committed, cold-start cost lands at
  session bootstrap instead of mid-edit.
- CC's explicit caching (100% hit, writes billed $0 at catalog) plus leaner
  output makes it cheapest on the official DeepSeek basis despite ~40% more
  turns than niffler.
- pi's failure mode is volume: 455k output tokens (vs niffler 93k), incl.
  116.7k on gin and 154.7k on tokio — generative thrash (long reasoning +
  echoing), 3-4× the wall time (jq 2089s, tokio 2161s).
- niffler's jq cell: 961s / 34 turns / 1.1M tokens — the O(n²) history-resend
  problem (uncached input grows every turn; flagged previously as the durable
  compaction target).

## What to change next

1. **429 backoff** in bench adapters (or rerun the 4 no-start cells) — niffler's
   fair-competition baseline vs CC's 7/10 is missing 2 data points.
2. **verify.mjs: diff final-vs-start-state** (harness snapshots repo at session
   start) — un-poisons jq and any task whose image ships a dirty tree.
3. **tokio image** needs a cargo registry fix (or pin getrandom) before tokio
   measures anything.
4. Consider a **"tests hint" hygiene check**: when a lane's F2P passes but a P2P
   regresses (fmt), that's a *near-miss* worth surfacing to the model only in
   non-hidden-test mode — in bench mode it stays a loss, and the lesson is for
   the systemprompt rubric: prefer the minimal semantics-preserving edit.
