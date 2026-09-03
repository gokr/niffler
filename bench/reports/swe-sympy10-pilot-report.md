# SWE-bench Verified pilot — sympy 10, one-shot

**Run**: `swe-sympy10-glm` (glm-5.3-flash) + `swe-sympy10-ds` (deepseek-v4-flash),
commit `72d41f7` (post transport-retry/group-kill/recipe-prompt fixes).
**Date**: 2026-09-02 → 2026-09-03.

## Task set

10 SWE-bench Verified instances (sympy), one-shot (`--rounds 1`), canonical:
the agent sees only the issue text and a `base`-tagged checkout; grading is
the official swebench 4.1.0 Docker harness with the hidden `test_patch`
applied (FAIL_TO_PASS + PASS_TO_PASS must all pass, protected files untouched).
Setup/protocol: [bench/swe/README.md](../swe/README.md).

Instances: 11618, 12096, 12419, 12481, 12489, 13031, 13091, 13372, 13480, 13551.

## Results

| model | harness | resolved | avg agent time | avg tok total | avg uncached in |
|---|---|---:|---:|---:|---:|
| deepseek-v4-flash | pi | **9/10** | 274 s | 1178 k | 20.0 k |
| deepseek-v4-flash | opencode | **9/10** | 339 s | 1481 k | 38.4 k |
| deepseek-v4-flash | niffler | 6/10 | 165 s | 513 k | 16.3 k |
| glm-5.3-flash | pi | **8/10** | 335 s | 338 k | 36.2 k |
| glm-5.3-flash | opencode | 7/10 | 545 s | 521 k | 77.0 k |
| glm-5.3-flash | niffler | 5/10 | 610 s | 510 k | 65.7 k |

(`tok total` = uncached in + cache read + output; GLM via llmgateway reports
no cache, so its "uncached" is the whole prompt.)

## Reading

- **Niffler resolves fewer tasks but at 2.3–2.9× less total tokens per task**
  (deepseek: 513 k vs 1178 k/1481 k). The gap comes from Niffler's lean
  context: it re-reads less per turn and its system prompt is much smaller
  than pi's/opencode's.
- **deepseek-v4-flash is materially stronger on this task set** than
  glm-5.3-flash (9/9/6 vs 8/7/5) *and* the harnesses run it faster.
- Niffler's misses are quality, not infra: every failed cell produced a real
  diff after the recipe-prompt fix (pre-fix runs produced empty diffs because
  flash agents burned their turn on environment archaeology — see
  [Protocol changes](#protocol-changes)).
- pi and opencode track each other closely on resolution; pi is cheaper on
  deepseek (1.18 M vs 1.48 M avg total), opencode cheaper on glm on the same
  metric but its GLM lane includes one infra-hung cell.

## Protocol changes forced by this pilot (commit 72d41f7)

1. **Recipe-style task prompt.** The original constraint-list prompt
   ("don't run tests, don't install deps…") let flash agents wander into
   `find /` environment hunts instead of editing (4/4 empty diffs in the
   first niffler deepseek attempt). The prompt now prescribes
   locate → edit → re-read → summarize with explicit no-tests/no-network/
   stay-in-repo rules. All harnesses get the same text.
2. **Transport-level retries (2×, pattern-matched).** Gateway outages
   (llmgateway TLS flap, deepseek 402 balance, opencode hang) previously
   turned one-shot cells into instant bogus fails. Auth/balance errors are
   never retried; a "successful" zero-usage Niffler turn counts as transport
   failure.
3. **Process-group kill on timeout.** A killed `opencode run` left a child
   holding the stdio pipe, delaying `close` (and the runner) by ~20 h.
   `run()` now spawns detached, SIGKILLs the group, and force-EOFs the pipes.
4. **Hidden cards moved outside the workspace** (`~/.cache/niffler-swe/cards`)
   so a wandering `grep -r` inside the agent's tree cannot reach gold/test
   patches.

## Corrections

- **opencode/glm-5.3-flash/sympy__sympy-13551**: first attempt hung behind the
  pre-fix timeout bug (wall 78481 s is infra, not agent). Clean re-run under
  fixed tooling also failed (730 s, 29.1 k in / 115 out, empty diff). FAIL
  kept; the re-run dir was discarded after the decision.

## Raw data

- `var/bench/results/swe-sympy10-glm/` — report.md/csv, 30 result dirs with
  transcripts, patches, harness logs.
- `var/bench/results/swe-sympy10-ds/` — same shape.
- Discarded intermediates: `swe-sympy10-45ba045`, `swe-sympy10-r2`,
  `swe-sympy10-r3` (deepseek balance ran out mid-run), `swe-glm-c13551`
  (re-run, superseded), plus pre-fix smoke runs.
