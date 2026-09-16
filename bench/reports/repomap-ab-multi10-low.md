# bench report — Multi10 repomap auto-append A/B at low thinking (matched-tree rerun)

Follow-up to `repomap-ab-multi10.md` (the value probe at thinking **high**:
map ON 8/10 vs OFF 9/10, 3.7× tokens — the evidence behind the
`NIF_REPOMAP_AUTOAPPEND` opt-in). This is the same probe at thinking **low**,
run because the first low attempt was invalidated by two confounds and the
high result alone left the long-horizon question open.

## Why this rerun exists

The first low A/B (raw: `multi10-low-{on,off}/`) had two defects:

1. **Lane B was DNS-dead.** Every one of its 10 cells failed in round 1 with
   `dial tcp: lookup api.synthetic.new: no such host` — 0 tokens, 1s/cell.
   Nothing about the harness; the network blinked and the run recorded `fail`.
   (Preserved as `multi10-low-off-dnsfail/` as the receipt.)
2. **The lanes ran on different trees.** Lane A ran on `aba88b8`; the rerun
   tree was `266e19c` — which also carried self-docs (system-prompt changes)
   and read-outline (whole-reads above 1000 lines return an LSP outline).
   Those change read/token behavior, so A-vs-B was never one knob.

Both fixed here: **both lanes on tree `266e19c`, same binary, one knob —
`NIF_REPOMAP_AUTOAPPEND=1` (map appended) vs unset (default off).** Control
verified in the artifacts: the ON lane published 10 maps
(`repo map published`); the OFF lane published 0. Raw:
`var/bench/results/multi10-low-on2/` and `multi10-low-off/` (both gitignored).

## Headline

Model `syn-large` (GLM-5.3-Flash), thinking low, `roundsMax 6`, 10 real OSS
tasks, `jobs 2`.

| metric (per-cell avg) | map ON | map OFF | delta |
|---|---:|---:|---:|
| **pass rate** | **10/10** | **9/10** | **+1 cell** |
| timeouts | 0 | 1 | −1 |
| avg tokens (in+out) | 165.9k | 362.2k | **0.46×** |
| avg uncached in | 20.9k | 53.5k | 0.39× |
| avg out | 3.0k | 5.4k | 0.56× |
| avg cache read | 141.9k | 303.3k | 0.47× |
| avg wall time | 354 s | 600 s | −41% |
| avg turns | 13.4 | 20.0 | −33% |

Per task (`pass`/`timeout`), tokens in+out:

| task | map ON | map OFF |
|---|---|---|
| axios-4731 | pass 43k | pass 117k |
| caddy-6115 | pass 56k | pass 86k |
| docusaurus-10130 | pass 71k | pass 46k |
| fmt-1683 | pass 83k | pass 185k |
| gin-1805 | pass 70k | pass 96k |
| jq-2235 | **pass** 720k | **timeout** 1.74M |
| nushell-12901 | pass 200k | pass 76k |
| redis-10068 | pass 38k | pass 850k |
| rubocop-13362 | pass 53k | pass 47k |
| tokio-4384 | pass 325k | pass 383k |

## Read of it

At low thinking the sign has flipped relative to the high run: the map is
**net-positive**, and the entire swing — here as there — lives in exactly two
cells:

- **jq**: ON passes in 582 s / 720k / 32 turns; OFF times out at 1931 s /
  1.74M / 56 turns. (At high, jq passed both ways: ON 3.5M, OFF 0.6M —
  the reverse direction.)
- **redis**: both pass, but ON costs 138 s / 38k / 5 turns against OFF
  1467 s / 850k / 37 turns. (At high, redis was *the* flipped cell: ON
  timeout at 7.0M, OFF pass at 1.5M.)

Excluding those two cells, the remaining 8 are mildly pro-map at low
(113k vs 129k avg tokens, basically flat wall time) and mildly anti-map at
high in the original report. Neither direction is strong; the aggregate is
decided by jq/redis in both regimes, and the two regimes disagree on the sign.

What the low transcript shape suggests is that the map mostly *prevents long
unproductive search phases* on unfamiliar large repos (OFF's redis: 37 turns
of flailing at 850k; ON: 5 turns). At high thinking the same model explores
much more aggressively, and the injected map seems to widen rather than
shorten that exploration (the 7.0M redis blowup).

## Decision status

The shipped default does **not** change on this report alone: the component
stays opt-in (`NIF_REPOMAP_AUTOAPPEND=1`), same as the high-thinking decision.
Two regimes pointing opposite ways, each decided by the same two high-variance
cells, is not enough to flip a default — whichever way it flipped, the next
populated run could reverse it.

The `Open question` in `repomap-ab-multi10.md` is now narrower: not "rerun
redis once" but "are jq/redis systematically map-sensitive, or are they
noise?" A dedicated probe is running: jq+redis × {low, high} × {ON, OFF}
(4 short lanes, `repomap-flip-{low,high}-{on,off}`). When it lands: if the
flips reproduce, the map's value is task-shaped (large unfamiliar repos with
a long search horizon) and the auto-append could default on for that shape;
if they scatter, both A/Bs were noise-dominated on these cells and the
default stays opt-in (tool-only), which is also the conservative shape.

## Reproduce

```
# in the repo, both lanes from the same commit (266e19c here):
NIF_REPOMAP_AUTOAPPEND=1 node bench/run.mjs --harness niffler --model syn-large \
  --thinking low --task-root var/bench/swe/tasks-multi --task all --jobs 2 --run-id multi10-low-on2
node bench/run.mjs --harness niffler --model syn-large \
  --thinking low --task-root var/bench/swe/tasks-multi --task all --jobs 2 --run-id multi10-low-off
```

Raw: `var/bench/results/multi10-low-{on2,off}/` (gitignored; `report.md` +
`report.csv` + per-cell `result.json`). Cross-reference: `repomap-ab-full30.md`
(regression gate) and `repomap-ab-multi10.md` (high-thinking value probe).
