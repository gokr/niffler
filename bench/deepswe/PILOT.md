# DeepSWE pilot — niffler vs pi vs opencode on deepseek-v4-flash

## Follow-up: niffler main after the reasoning/compaction work — 5/10

Run `deepswe-1daa3cc`, 2026-10-08. One-shot (`--rounds 1`), 10 tasks × 1
harness, **jobs=1**, release build (`-d:release`), niffler main @ `1daa3cc`
(the run id's commit — carries the §5.2 reasoning tombstone, the llm
request-boundary reasoning strip, and reasoning in the store search FTS).
Same 10 pilot tasks, same verifier protocol, `NIF_LOG_LEVEL=debug` — the
first run where the model-call timing seams fired end-to-end.

| task (lang) | verdict | time | rounds | tokens | cost $ |
|---|---|---:|---:|---:|---:|
| fd-deterministic-multi-key-sorting (rust) | **pass** | 1119s | 138 | 10.9M | 0.25 |
| geo-shapeindex-serialization (go) | **pass** | 363s | 66 | 3.1M | 0.11 |
| igel-persist-feature-schema (python) | **pass** | 541s | 91 | 5.1M | 0.15 |
| tomlkit-toml-table-converters (python) | **pass** | 854s | 147 | 13.8M | 0.31 |
| yjs-map-conflict-detection (js) | **pass** | 3357s | 244 | 33.0M | 0.81 |
| clack-async-autocomplete-options (ts) | fail | 977s | 100 | 6.5M | 0.20 |
| csstree-shorthand-expansion-compression (js) | fail | 829s | 144 | 9.1M | 0.28 |
| etree-xml-diff-patch (go) | fail | 270s | 32 | 1.0M | 0.08 |
| pest-character-class-coalescing (rust) | fail | 2264s | 143 | 9.7M | 0.23 |
| superjson-error-stack-serialization (ts) | fail | 571s | 73 | 2.9M | 0.16 |
| **summary** | **5/10** | avg 1114s | avg 118 | avg 9.5M | 2.57 run |

Reading (against the 8b08a1f pilot below — several weeks of harness work in
between, so this is a progress signal, not a single-change A/B):

- **5/10 vs the pilot's 3/10** on the same tasks. Newly passing: yjs (the
  hardest cell — 244 rounds / 56 min / 33M tokens, and the round machinery
  held together the whole way) and tomlkit. Rust's fd now passes too (was
  already passing as Go then — see the language note in the pilot's task
  table vs the import).
- The **failure shapes changed**: the pilot's fails died at 600–700 s / ~90
  rounds; these run 100–144 rounds and 977–2264 s. clack ended at exactly
  100 rounds with a natural "Done." — NOT a budget cut (no budget-exhausted
  record, and yjs ran 244 rounds in the same run, so no cap fired): the
  model wrapped up on its own, and the verifier's f2p 73/82 (partial
  0.988) says the miss is capability on 9 held-out tests. One real cost in
  that cell: 3 rounds burned on a subagent review the model could not
  launch (the child inherited the provider's model ECHO as an explicit pin
  and died on the cross-catalog check) — fixed in components/agent:
  children now inherit explicit pins only, resolving defaults like the
  parent.
- **Efficiency at long horizon**: avg 9.5M tokens/task (2.8× the pilot's
  3.4M) is the price of 2.4× the rounds and much longer turns; per-round
  tokens stayed flat. The prompt-cache discipline held: avg 9.2M of the
  9.5M was cache reads (97%), uncached in 167k/task.

---

## Original pilot — Run `deepswe-pilot-8b08a1f`, 2026-09-05.

Run `deepswe-pilot-8b08a1f`, 2026-09-05. One-shot (`--rounds 1`, canonical),
10 tasks × 3 harnesses = 30 cells, 2 jobs, launched from the laptop with
`bench/run.mjs` against `var/bench/deepswe/tasks-pilot` (see
`bench/deepswe/README.md` for task selection and pipeline).

- Model: `deepseek-v4-flash` (all lanes). Niffler binaries: host `var/bin`
  built from main @ `8b08a1f` (the run id's commit).
- Datacurve verifier unmodified, run in the task's own Docker image with
  `--network none`; grade = `reward.json` (f2p/p2p fractions).

## Results

| harness | pass | valid cells | avg time (s) | avg tok total | avg uncached in | avg tok out | avg cost $ |
|---|---:|---:|---:|---:|---:|---:|---:|
| niffler | **3/10** | 9 | 640 | 3.36M | 45.7k | 70.0k | 0.11 |
| opencode | 1/10 | 9 | 4276 | 11.25M | 79.8k | 23.1k | 0.09 |
| pi | 0/10 | 8 | 3626 | 3.99M | 39.7k | 73.8k | 0.20 |

(The original report shows cost 0 for niffler cells — the adapter did not
price traffic then; the number above is back-computed with the same
$/MTok table pi uses. Fixed in `bench/adapters/niffler.mjs` for future runs.)

Per-task verdicts:

| task (lang) | niffler | opencode | pi |
|---|---|---|---|
| fd-deterministic-multi-key-sorting (Go) | **pass 505s** | timeout 31ks | fail 370s |
| geo-shapeindex-serialization (Python) | **pass 431s** | **pass 1069s** | timeout 30.6ks |
| igel-persist-feature-schema (Python) | **pass 542s** | fail 1045s | fail 480s |
| clack-async-autocomplete-options (TS) | fail 610s | fail 1466s | fail 853s |
| csstree-shorthand-expansion-compression (JS) | fail 680s | fail 1655s | fail 765s |
| etree-xml-diff-patch (Go) | fail 1370s | fail 2095s | fail 1072s |
| pest-character-class-coalescing (Rust) | fail 599s | fail 1296s | fail 566s |
| superjson-error-stack-serialization (TS) | fail 668s | fail 1405s | fail 773s |
| tomlkit-toml-table-converters (Python) | fail 746s | fail 1725s | error (402) |
| yjs-map-conflict-detection (JS) | error (402) | error (402) | error (402) |

## Reading

- **Niffler passed 3/9 valid cells and was the fastest and leanest lane**
  (640 s avg vs opencode's 4276 s; 3.4 M tokens/task vs opencode's 11.3 M —
  opencode burns ~3.3× niffler's tokens for 1 pass). pi never passed but its
  token profile matches niffler's; its losses were mostly "close" fails
  (several cells produced partial diffs within tens of lines of the gold).
- Difficulty is even by language here: the passes landed in Go and Python,
  the fails cluster in TS/JS and Rust — consistent with DeepSWE's own
  hardest-language observations, but 10 tasks is far too few to conclude.
- opencode's one pass (geo-shapeindex) took 15.4 M tokens — the most
  expensive single cell of the run.

## Validity caveats

1. **4 cells died on `402 Insufficient Balance`** (DeepSeek wallet emptied
   near the end of the run): yjs on all three lanes + pi/tomlkit. They are
   recorded as `error`, not agent failures. Re-run after topping up:
   `node bench/run.mjs --task-root var/bench/deepswe/tasks-pilot \
   --task yjs-map-conflict-detection,tomlkit-toml-table-converters \
   --harness niffler,pi,opencode --model deepseek-v4-flash --rounds 1 ...`
2. Two cells (opencode/fd-sorting, pi/geo-shapeindex) show ~31 ks wall time:
   `run.mjs` only checked `--task-timeout-min` *between* rounds, while the
   adapters retry internally — fixed (the budget is now enforced mid-retry
   and surfaced as a budget-only round that still verifies the diff).
3. Canonical DeepSWE numbers use one attempt per task; multi-round feedback
   would leak hidden tests. Everything here is `--rounds 1`.

## Harness provenance

- niffler: private harness on a private NATS bus, binaries from main@`8b08a1f`
  (the store/sqlite-tidb work landed mid-pilot but was not picked up by these
  binaries; it *was* exercised by the container smoke builds of newer mains).
- pi: `pi` CLI with modelcfg pricing (input 0.283, output 1.14, cacheRead
  0.028 $/MTok); opencode: `opencode` CLI, cost as reported by the provider.

## Next

- Top up DeepSeek credit, re-run the 4 invalidated cells, then decide the
  wave shape: 30–50 tasks across all 5 languages for stable per-language
  rates, or the SWE-bench Verified cross-repo wave first.
- Cloud: `bench/container/` (niffler-bench image + compose) is verified for
  all three source modes (mounted checkout, per-SHA cache hit, `NIFFLER_REF`
  GitHub clone). wowbagger runbook is in `bench/container/README.md`.
