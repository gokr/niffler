# bench report — full30 with the repomap gates active (append forced ON)

Verification run for the admission gates implemented in `500d007`
(docs/research/REPOMAP-GATES.md). Question: with `NIF_REPOMAP_AUTOAPPEND=1`
**forced on**, do the gates reproduce full30's append-off economics — i.e.
does the +41% token tax from `repomap-ab-full30.md` disappear by
construction?

Setup: main checkout at the gate implementation, model `syn-large`
(GLM-5.3-Flash), thinking low, `roundsMax 6`, `--jobs 2`, all 30 tasks
(`bench/tasks`). One knob vs the historical lanes: the flag is forced on and
the gates decide. Raw: `var/bench/results/full30-gates-on/` (gitignored).

## Delivery control (the primary assertion)

**30/30 workspaces withheld, 0 published** — verified in the component log
(`repo map withheld for ... (workspace below census floor)` × 30, `repo map
published` × 0, i.e. nothing was injected into any conversation). All 30
full30 repos census 1–31 source files; the floor is 50. This is the exact
expectation recorded in the gates doc.

## Economics (per-cell averages)

| metric | gated ON | ungated ON (`repomap-on`) | ungated OFF (`repomap-off`) |
|---|---:|---:|---:|
| pass rate | **30/30** | 30/30 | 30/30 |
| tok total | **24.1k** | 34.5k | 24.4k |
| uncached in | 4.8k | 4.9k | 2.5k |
| tok out | **881** | 1085 | 822 |
| cache read | 18.5k | 28.5k | 21.1k |
| turns | 5.5 | 6.2 | 5.7 |
| tool calls | 4.7 | 5.4 | 4.8 |
| wall time | 101 s | 68 s | 66 s |

The token profile of **gated-ON matches ungated-OFF** (24.1k vs 24.4k total,
881 vs 822 out, 4.7 vs 4.8 tool calls, 5.5 vs 5.7 turns): with the append
forced on and the gates live, the map never enters context, so the behavioral
"explore ~0.5 turns more" effect the original report attributed to the map is
gone. The +41% tax is removed **by construction**, not by luck.

Wall time is the one metric that does not line up (101 s vs 66–68 s), and it
is not attributable to the gates: the transcript shape and token counts are
identical to append-off, while wall time tracks provider latency (the same
suite's wall time ranges 48–101 s across runs on this box; the per-cell
median delta vs today's baseline is +34 s with no corresponding turn/token
delta — transport time, not agent work). Note this as a caveat: **the gates
do not change wall time; this run was slower end-to-end**.

## Status of the gate work

- Gate behavior verified live (withheld × 30, published × 0, reason strings
  in the log).
- The size floor does its job at zero cost: census-only, no tag parsing.
- No regression on the suite: 30/30 as before.

## Remaining verification (not this report)

The append-off default stays until the **low Multi10** no-regression lane is
also clean: the gates should publish normally there (all ten repos clear
both gates), so `multi10-low-*` economics should replicate. Then, and only
then, the default flip is a candidate (gates doc, "Verification plan"
step 5).
