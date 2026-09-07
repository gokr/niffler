# Mid-tier calibration analysis — `midtier-glm53-low` (t18–t27, GLM-5.3-Flash, thinking=low)

Compared lanes: `niffler` vs `pi`, both on `glm-5.3-flash` (llmgateway), 10 tasks
(t18–t27), 1 round. Result: **20/20 PASS** (niffler 10/10 avg 164s; pi 10/10 avg 103s).
Evidence: `var/bench/results/midtier-glm53-low/*`, niffler lane transcript recovered
from the lane's barrel-db (`var/bin/dumpbarrel`, source kept in git history of this
analysis: 179 messages), pi lane from `pi-sessions/*.jsonl`, LLM call log from the
lane harness's `var/logs/llm.log` (84 calls).

## 1. What the "tiny calls" are

llm.log: **84 calls, 501,628 prompt / 19,662 completion tokens**. 61 of 84 calls emit
<60 completion tokens (mostly 12–15) — these are **tool-selection turns**: GLM-low
answers with just a tool call ({"name":"bash","arguments":{...}} ≈ 12–25 tokens).
The big completions (~300–4,300 tok) are the code-writing turns (write/edit) and
final replies. reasoning_chars is ~0 almost everywhere (one 51, one 7k) — thinking=low
barely reasons on either harness.

So the agent loop's shape is: many cheap-looking turns that each **re-send the whole
conversation**. Whether that is expensive depends entirely on whether the gateway
caches prompts (see §4).

## 2. Niffler's mistakes

16 non-zero tool results over 79 tool calls:

| error | cells | verdict |
|---|---|---|
| `./test.sh: Permission denied` (exit 126) | **10/10** | pure harness bug — prompts say `./test.sh`, plain file copy loses the exec bit; **every cell wasted one turn + ~10–20 s**. Fixed in `run.mjs:prepareRepo` (chmod 0o755). |
| t18 wrote cache.go with unterminated string literal → compile error → edit fix | 1 | legit iterate cycle (+2 turns) |
| t19 traceback + invalid-config test failures | 1 | legit red→green cycles (×2) |
| t20 / t24 TAP test failures → edit fix | 2 | legit |
| t27 compile error → edit fix | 1 | legit |

Only 6 of 16 errors are genuine solve-iterations; 10 are the bench's exec-bit bug
(equal tax on pi). No test-cheating in this run (the deepseek smoke's t24 INVALID —
model editing protected `test.sh` — did not recur; GLM niffler touched only
`lib/editops.mjs`). t22 needed 3 edit rounds (cron dom/dow OR rule) — hardest task,
still solved.

## 3. Tool calls: niffler vs pi

| | niffler | pi |
|---|---|---|
| turns (LLM calls) | **84 (8.4/cell)** | **62 (6.2/cell)** |
| bash | 40 (51%) | **171 (77%)** |
| read | 22 | 4 (!) |
| write | 12 | 42 (one per cell, big) |
| edit | 9 | 6 |
| files / read_many | 2 | – |

pi works in **batched shell turns**: `cat cache.go; echo ---; cat README.md; ls` is
one call; its `read` tool almost never fires (4× in 10 cells). niffler uses the
purpose-built tools granularly: ls → read → read → write. Best case pi solves t19 in
**4 turns** (cat→write→test→reply, 42 s). Same final verdicts on all 10 tasks.

## 4. Why pi pays half the input tokens

Per cell: niffler **50.1k in / 2.0k out** vs pi **23.8k in / 1.7k out** (result.json
matches llm.log sums). Decomposition of the ~26k/cell gap:

1. **~38% more turns** (8.4 vs 6.2) ≈ 10k/cell — granular file tools + 1 wasted
   exec-bit turn + fix-up edits vs pi's batched bash.
2. **Frozen prefix ≈ 2.2k vs pi ≈ 1.1k tokens** (turn-1 calls: 2494 vs 1576; task
   prompts are identical) — niffler's system prompt + 6-tool schema is ~2× pi's,
   and it is **re-paid on every one of the 84 calls** ≈ 12k/cell.
3. Rest (~4k/cell): niffler's history grows slightly faster (read tool dumps whole
   files; pi cats them into bash results — similar, plus pi writes once, niffler
   write+edit round-trips).

**The caching asymmetry is the kicker.** llmgateway reports `cacheRead ≈ 0` for glm
(a few cells show 8,960, most 0) — so every turn re-pays the full prompt. On deepseek
(`full17-ds-low`, same build) niffler's history *is* cached: 3.7k uncached +
**35.7k cache-read** per cell. The multi-turn style is only "expensive" on gateways
without prompt caching. Consequence: GLM-high runs will inflate niffler's token
counts far more than pi's (pi-glm-high already shows 462k-in cells at 5,800 s).

## 5. Actions taken / options

- **done**: exec-bit fix in `prepareRepo` (kills the 1-turn/cell waste for all
  harnesses).
- **optional**: trim niffler's frozen prefix toward pi's 1.1k (system prompt is the
  fat part; tool schemas for 6 tools are small). ~1k × 8 calls ≈ 8k tok/cell.
- **optional**: teach the agent to batch reads (`read_many` exists and was used once)
  — a prompt nudge, not a code change.
- **note for model comparisons**: on no-cache gateways, compare **turns**, not just
  tokens; a caching gateway (deepseek) amortizes niffler's style.

## 6. Run-state notes (incidents during analysis)

- DeepSeek balance ran dry again (402) — the deepseek-high lanes of
  `deepswe-pilot-glm53high-0907` mostly completed before that (opencode 4 pass/10,
  pi 5 pass/9, niffler 0 pass/2); remaining deepseek-high cells are parked until a
  top-up.
- An overbroad `pkill` (mine) briefly killed the active deepswe runners mid-flight;
  18 zero-token garbage cells were deleted and the GLM-high lanes (niffler+pi)
  relaunched under the same run-id with `--resume`. `deepswe-pilot-8b08a1f`'s last
  402-refill cells also need the top-up.
