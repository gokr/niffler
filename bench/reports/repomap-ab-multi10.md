# bench report — Multi10 repomap auto-append A/B (feat/repomap @ 9150c08)

Question: on real OSS repos, does the auto-appended repo map help the agent
orient faster, or does it cost more than it is worth? This is the **value
probe** that `repomap-ab-full30.md` deferred (full30 was the regression gate,
and its repos are too small for orientation to matter).

Setup: the same worktree and the same commit (`9150c08`) for both lanes,
model `syn-large` (GLM-5.3-Flash), thinking high, `roundsMax 6`, ten real
tasks. **One knob:** `var/bin/repomap` present (map ON) vs absent (map OFF —
the manifest entry is `required: false`, so the harness boots with
`WARNING missing binary for repomap`). Verified in the artifacts: the ON
lane's transcripts contain the appended map in **8/10** cells, the OFF lane's
in **0/10**; the OFF harness log shows the missing-binary warning.

| metric (per-cell avg) | map ON | map OFF | delta |
|---|---:|---:|---:|
| **pass rate** | **8/10** | **9/10** | **−1 cell** |
| timeouts | 2 | 1 | +1 |
| avg tokens (in+out) | 252.0k | 68.3k | **3.7×** |
| avg uncached in | 214.0k | 47.6k | 4.5× |
| avg out | 38.0k | 20.7k | 1.8× |
| avg cache read | 1315.9k | 575.9k | 2.3× |
| avg wall time | 1842 s | 1147 s | +61% |

Per task (`pass`/`timeout`):

| task | map ON | map OFF |
|---|---|---|
| axios-4731 | pass | pass |
| caddy-6115 | pass | pass |
| docusaurus-10130 | pass | pass |
| fmt-1683 | pass | pass |
| gin-1805 | pass | pass |
| jq-2235 | pass | pass |
| nushell-12901 | pass | pass |
| redis-10068 | **timeout** | **pass** |
| rubocop-13362 | pass | pass |
| tokio-4384 | timeout | timeout |

## Read of it

The map is not paying for itself. The one cell that flips (`redis`) is a
timeout attributable to the map lane burning budget — 7.0M tokens against
1.5M without it. Every lane that passed did so either way, so **the map bought
zero passes and cost a pass**.

Note the magnitude difference from full30: there the tax was ~40% of tokens
with everything still 30/30, and the explanation was *behavioral* (the map
made the agent explore ~0.5 more turns on tiny repos). Here on large repos the
effect compounds — the extra orientation material sits in context for a much
longer episode, and cache dynamics amplify it into a 3.7× token figure. On
both suites the direction is the same: **cost up, accuracy flat.**

## Decision

The workspace-open auto-append ships **off by default**
(`NIF_REPOMAP_AUTOAPPEND=1` opts in). Nothing about the component is disabled:
`repo_map` stays registered, onDemand and read-effect, so the map is a tool the
model can discover when a large unfamiliar repo warrants it — rather than
context injected into every conversation on every workspace.

That shape is the right one independent of these numbers: it makes the feature
opt-in and measurable. If a future A/B on repos where orientation genuinely
dominates (the finding here is that time-to-first-correct-file did *not*
dominate, even on redis/tokio/jq) shows a win, the flag is already there.

Open question left behind: the ON lane's `redis` timeout at 7.0M tokens is a
large enough outlier to deserve a rerun before treating "map is net-negative"
as settled for long-horizon tasks specifically. The default-off decision does
not depend on it.

## Reproduce

```
# in the feat/repomap worktree, both lanes from the same commit:
NIF_REPOMAP_AUTOAPPEND=1  bench ... --suite multi10   # map ON
                          bench ... --suite multi10   # map OFF (rm var/bin/repomap)
```

Raw: `var/bench/results/multi10-map-{on,off}/` in the repomap worktree
(gitignored; `report.md` + `result.json` per cell). The full30 regression gate
is `repomap-ab-full30.md`.
