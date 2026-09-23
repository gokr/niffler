# REPOMAP-GATES.md — when the repo map earns its append

Decision record for the two **admission gates** on the workspace-open
auto-append. Context: `REPOMAP.md` (the algorithm + port), `bench/reports/
repomap-ab-{full30,multi10,multi10-low}.md` (the three A/Bs). The gates were
agreed after those A/Bs, when the evidence stopped supporting "map good" or
"map bad" and started supporting "map depends on what's in it and how big the
repo is".

Status: **implemented** (`components/repomap/main.nim`, `MapStats` +
`appendCensusOk` + `appendGateReason`; tests in `tests/t_repomap*.nim`;
`make test-repomap` covers both admission gates and an explicit opt-out).
The append is **gated on by default**; `NIF_REPOMAP_AUTOAPPEND=0` disables it.
This changes only workspace-open history, never the frozen prompt prefix.
The ungated A/Bs below were mixed; the gated-on default has not yet had a
matched-tree quality/latency A/B on large repos.

## Why gates — what the A/Bs actually show

Three experiments, two regimes, opposite signs:

| suite | map ON | map OFF | tokens |
|---|---|---|---|
| full30 (11 micro repos, 3.6k lines total) | 30/30 | 30/30 | 34.5k vs 24.4k (+41%) |
| Multi10 high (real OSS repos) | 8/10 | 9/10 | 252k vs 68k (3.7×) |
| Multi10 low (matched-tree rerun) | 10/10 | 9/10 | 166k vs 362k (0.46×) |

Then the dedicated flipper probe (jq + redis × low/high × on/off, 8 cells)
added a second, sharper finding hidden in the first high A/B:

| lane | map quality for jq/redis | outcome |
|---|---|---|
| high A/B (`9150c08`) | **stub maps** — jq 154 B / 4 syms, nushell 1239 B / 9 syms (C/Rust tiers not yet landed) | map lost the aggregate |
| flip probe (`266e19c`, C tier in) | real maps — jq 4283 B / 119 syms | low: ON 6/6 on the two cells; high: mixed, violent tail (jq-ON 11.2M tok / 78 turns to timeout) |

Two lessons the gates encode:

1. **A map with almost nothing in it is pure overhead.** The high A/B's
   "anti-map" cells were partly measuring stub maps. That failure mode is
   objective and cheap to reject — hence a *content gate*.
2. **On micro repos the map cannot pay.** full30's tax was +41% tokens for
   zero accuracy change across 30/30: nothing to orient in. Hence a *size
   floor* — the same seam, one comparison, no new machinery.

Both gates are **append-only admission** decisions: they affect only the
auto-append. `repo_map` (the tool) is untouched and always available — if a
human or model explicitly asks, the answer is the map, however small.

## Gate 3 — the content gate (primary)

Reject the append unless the built map is *substantive*. Three signals, all
already computed at publish time in `components/repomap/main.nim`
(`hRepoMap`/`buildFor`): rendered byte length, rendered symbol count, file
count. Thresholds calibrated from the stored maps (all Append lanes in the
bench stores; stub observations are the pre-C-tier lanes):

| map | bytes | symbols | files | verdict at proposed thresholds |
|---|---:|---:|---:|---|
| jq stub (high A/B) | 154 | 4 | 1 | **rejected** (all three) |
| nushell stub (high A/B) | 1239 | 9 | 1 | **rejected** (symbols, files) |
| redis stub (high A/B) | 3095 | 71 | 4 | **rejected** (files) |
| t10-iniparse (full30) | 100 | 2 | 1 | rejected (irrelevant: size floor rejects first) |
| jq real (probe) | 4283 | 119 | 19 | admitted |
| redis real (probe) | 3648 | 83 | 34 | admitted |
| smallest healthy multi10 map (bytes) | 3549 | 91 | 30 | admitted |
| median healthy multi10 map | ~3.9k | 94 | 34 | admitted |

**Proposed thresholds** (all three must hold; constants in `main.nim`):

```
MIN_MAP_BYTES   = 800     # rendered map body, not the envelope
MIN_MAP_SYMBOLS = 25      # rendered rows of kind def+ref
MIN_MAP_FILES   = 5       # files with at least one rendered symbol
```

Rationale for each:

- **bytes ≥ 800**: separates noise-level maps from real ones with a wide
  margin on both sides (reject margin: ≥106 bytes below for the stubs below
  700; admit margin: ≥2.7k above). A map below ~800 B cannot contain enough
  orientation material to matter; it is a stub by construction.
- **symbols ≥ 25**: the stub class sat at 4–9 symbols while healthy maps sat
  at 59–119. 25 splits the gap (2.8× above the worst stub, 2.4× below the
  weakest healthy). Symbols (not lines) because the renderer's rows are the
  scorable material — a map of 40 bare file paths is not orientation.
- **files ≥ 5**: catches the "one file parsed, everything else dark" case —
  exactly the stub shape (1–4 files). It also rejects single-file maps from
  workspaces that are genuinely one module: that is the intended outcome,
  since a one-file map orients nothing a `read` would not.

Symbol and file counting: count rendered rows in the map string with the
renderer's own shape (`"  <line>:<col>  <symKind>  <name>"` — parse
`renderMap`'s output once, or have `buildMap` return stats alongside the text;
the latter is preferred — see Implementation). Counting the rendered string
is deliberate: it is the artifact the model would receive.

Not proposed: a language-coverage threshold (how many census languages have
tiers). The stub measurements were an artifact of missing tiers, but once the
tiers exist, coverage is the content gate's job — a repo whose languages
produce no symbols lands below `MIN_MAP_SYMBOLS` anyway. Keep the gate
language-agnostic per AGENTS.md: no engine-side language lists.

## Gate 4 — the size floor (secondary)

Reject the append when the workspace is too small for orientation to matter.

```
MIN_WORKSPACE_CENSUS = 50   # covered source files (the census() count)
```

Calibrated from the same data:

| workspace class | census files | outcome at 50 |
|---|---:|---|
| full30 micro repos | 1–31 (median 3) | **rejected** — correct: 30/30 either way, +41% tax |
| t13/t28 (the two larger full30) | 29, 31 | rejected |
| smallest multi10 repo (gin) | 80 | admitted |
| jq | 74 | admitted |
| mean multi10 | ~570 | admitted |

The gap is clean: every full30 repo ≤ 31, every multi10 repo ≥ 72. A floor
anywhere in 32–72 reproduces the same split on this corpus; 50 is the middle.
What the floor *means*: under ~50 source files the map is a worse `ls` — the
agent can hold the repo in head from one or two reads, as full30 showed.

Interaction with the content gate: the floor runs **first** (census count is
available before tags are parsed, so a micro repo costs no parse work at all),
and a rejected-by-size workspace skips the build entirely. That ordering also
means full30 costs nothing extra under a gated append.

Not proposed: LOC as the size metric. Lines correlate with files here but are
dominated by vendored/generated code (`deps/`, `dist/`) in exactly the repos
the map helps; file count is the orientation proxy (how many places are there
to look), and the census already computes it.

## What this does NOT solve

State this plainly so nobody mistakes the gates for the fix:

- **The high-thinking tail is untouched.** jq at high thinking is a
  mega-repo (74 census files of dense C — passes both gates) where the map
  lane spiralled to 11.2M tokens and timed out. Since low thinking flips the
  other way, the sign for a gated append remains regime-dependent, and the
  component cannot see thinking effort (the envelope carries no reasoning
  setting; that lives in the llm component's config). A gated append is
  therefore still **net unclear at high thinking** until either the tail
  reproduces in a second sample or a mechanism is found that explains it
  (over-verification feedback loop vs. map-induced exploration; see
  `REPOMAP.md` "open questions" for the transcript evidence).
- **Variance dominance is not fixed.** Two cells (jq, redis) decide every
  aggregate. The gates remove the *stub* and *micro-repo* failure classes —
  both objectively wrong regardless of the aggregate — but they do not turn
  the remaining sign question into a settled one.
- **Some repos will still get no map.** That is a feature: a repo with
  under 25 symbols across under 5 files has nothing to orient, and the
  tool remains for the case where someone insists.

## Implementation sketch

In `components/repomap/main.nim`:

1. `buildFor` returns `tuple[text: string, files: int, symbols: int]`
   (or a small `MapStats` object) — the counts are free inside `renderMap`
   (`display` length after dedup, distinct `rel` among symbol-bearing rows;
   the renderer already computes both).
2. `census()` result length is the size-floor input; check it before the
   tag parse in the `ev.workspace.opened` handler:
   `if srcFiles.len < MIN_WORKSPACE_CENSUS: return`
   (this needs `buildFor` split into census + build, or a `shouldBuild`
   precheck that returns the census count — the latter keeps one code path).
3. After build: `if not gatePasses(stats): c.log("info", "repo map withheld
   (stub): ..."); return`. The log line matters: the bench greps
   `repo map published` today, and a withheld map must be visible or the
   A/B silently changes meaning.
4. Constants at the top next to `MAP_DEFAULT_BUDGET`, each with a one-line
   provenance comment citing the calibration table above.
5. `NIF_REPOMAP_MIN_FILES` / `NIF_REPOMAP_MIN_SYMBOLS` / `NIF_REPOMAP_MIN_BYTES`
   overrides, same style as `NIF_REPOMAP_AUTOAPPEND` — the bench needs to
   drive lanes through the gates and a future corpus may want different
   numbers without a rebuild. Defaults above.

The tool path never consults the gates. The `selfTest` should gain two
checks: a stub workspace (one file, two symbols) yields an empty **append**
but a non-empty **tool** result; the same workspace padded past the
thresholds flips the append on.

Tests (`tests/t_repomap.nim`): the existing auto-append test uses a tiny
fixture — it will need to grow past both gates to keep exercising the happy
path, plus new cases for (a) size-floor rejection, (b) content-gate
rejection, (c) tool-path immunity, (d) withheld-log emission.

## Verification plan (post-implementation)

1. Unit: `make test-repomap` covers default-on, both gates, opt-out and
   explicit tool pulls; `make test-ctx-accounting` covers independent
   map/diagnostics queue drains.
2. Micro-repo: a future full30 run with the gated default should produce
   **0 publishes** across all 30 (size floor); the earlier +41% tax was from
   ungated injection, not this policy.
3. Real-repo: a matched-tree low Multi10 A/B with gated ON/OFF remains
   desirable. Old ungated runs differed substantially, so do not attribute
   their outcomes to the new default.
4. The high tail stays an open question; a second high sample on
   jq+redis is the follow-up probe promised in `repomap-ab-multi10.md`.

## Open questions

- Is `MIN_MAP_SYMBOLS = 25` too lenient for an *append* (vs. a tool
  answer)? A 30-symbol map may still be mostly bare paths. Consider
  requiring symbols ≥ 25 **and** symbols/files ≥ 3 once more data exists.
- Should the gates apply to the **tool** when the workspace is huge and the
  budget small? (Tool path is currently ungated by design; a model that asks
  for 32 tokens of map will get a tiny one. Leave it.)
- The withheld log line is the only observability for a rejected append; if
  the append default flips on, the session-context status events may deserve
  a `map: withheld(stub)` field so UIs can show it.
