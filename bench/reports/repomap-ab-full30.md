# bench report — full30 repomap A/B (feat/repomap @ bd4cfcc)

Question: does the auto-appended repo map regress the optimized stack, and
what does it cost? Same worktree, same commit, same model/protocol
(syn-large / Synthetic, thinking low, `--jobs 2`); one knob between lanes:
`var/bin/repomap` present (on) vs renamed away (off — manifest entry
`required: false`, so the harness boots without it).

| metric (per-cell avg) | map ON | map OFF | delta |
|---|---:|---:|---:|
| pass rate | **30/30** | **30/30** | = |
| avg turns | 6.2 | 5.7 | +0.5 |
| avg time | 68 s | 66 s | +3% |
| avg tok total | 34.5k | 24.4k | **+41%** |
| avg uncached in | 4.9k | 2.5k | +2.4k |
| avg cache read | 28.5k | 21.1k | +7.4k |
| avg tok out | 1.1k | 822 | +278 |
| avg tool calls | 5.4 | 4.8 | +0.5 |
| run cost (provider) | $0.0725 | $0.0489 | +48% |

## What the map itself costs (much less than the delta)

The appended map averages **854 chars ≈ 214 tokens** on these small
workspaces (max 530). The +10k token/cell delta is **behavioral**, not
bytes: with the map in context the agent makes ~0.5 more tool calls and
~0.5 more turns — it explores slightly more — and cache dynamics amplify
that into the totals. On repos this small and a suite this saturated
(30/30 either way), extra thoroughness is pure cost: no benefit is
measurable here, by design of the suite. full30 was the **regression
gate**: passed.

## Coverage gap found and closed (bd4cfcc)

5/30 lanes-off cells (t05, t11, t20, t24, t30 — all Node/JS) never
received a map: the census found zero supported files (no `.js` tier) and
the component silently skipped them. The component published exactly
25/25 maps for the cells it could serve — delivery is reliable.
tree-sitter-javascript v0.23.1 + aider's javascript-tags.scm added; .js
joins census and dispatch; 27 tags checks.

## Decision

- **Regression gate: passed.** The auto-append is safe on the stack.
- **Value question open**: full30's repos are too small for orientation
  to matter. The probe that answers it is Multi10 (real OSS repos, where
  time-to-first-correct-file dominates) — map on/off there, measuring
  pass rate and turns-to-orientation.
- Known knob if the token tax matters on small workspaces: skip the
  auto-append when the census yields < N source files (a 3-file repo's
  map teaches nothing the first `ls` wouldn't). Not implemented —
  decide with Multi10 data.

Raw: `var/bench/results/repomap-{on,off}/` (gitignored; report.md/csv per
run). Baseline reference (older commit, different prompt volume):
`bench/reports/full30-synlarge-low-niffler-report.md` — 30/30, 48s,
20.5k avg; not comparable directly, the internal A/B is the measurement.
