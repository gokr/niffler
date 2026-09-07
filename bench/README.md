# bench — harness comparison framework

Compares coding-agent **harnesses** (Niffler, pi, opencode, codewhale) on the
same set of coding tasks with the same models, and measures:

- **time to green** — wall clock from the first agent turn until `./test.sh`
  exits 0 (multi-round: failing test output is fed back to the agent, exactly
  like a human would), capped by a round and a wall-clock budget,
- **token consumption** — provider-reported usage per harness (input / output /
  reasoning / cache read+write / cost where the harness reports it),
- **solution quality** — `git diff` vs the task's base commit (files, +/−),
  plus a guard: touching protected files (tests, `test.sh`) marks the run
  `invalid` even when tests pass.

## Layout

```
bench/
  config.json          # model × harness wiring (endpoints, model ids, key env names)
  run.mjs              # orchestrator: combos → [turn → verify] loops → results
  report.mjs           # aggregates a run dir into report.md + report.csv
  lib/                 # util + key resolution (keys never stored/logged)
  adapters/            # pi.mjs, opencode.mjs, niffler.mjs, codewhale.mjs
  tasks/t0*/           # prompt.md, meta.json, repo/ (pristine git repo, tag `base`)
  reports/             # committed aggregates (one *-report.{md,csv} per run)
  swe/                 # SWE-bench Verified importer (see swe/README.md)
  deepswe/             # DeepSWE (Datacurve) port — 113 original long-horizon
                       # tasks, 5 languages (see deepswe/README.md)
  container/           # niffler-bench Docker job image + compose (builds
                       # Niffler at NIFFLER_REF per run; see container/README.md)
var/bench/results/<runId>/   # raw output, disposable (gitignored, make clean wipes it)
```

## Tasks

Seventeen self-contained repos, all "make the visible test suite pass"
(like SWE-bench's FAIL_TO_PASS, but lightweight and dependency-free so
every harness starts equal). `meta.json` tags each with a `kind`:
`general` (bug fixes, implementations, refactors), `fabric` (mechanical
fan-out work a guest program excels at), `expert` (tasks with Niffler-
specific tool-selection traps) and `selfextend` (build your own tool).

| task | language | kind |
|------|----------|------|
| t01-roman | Go | implement function (greedy numeral conversion) |
| t02-jsonrepair | Python | implement "almost JSON" repair (quote/literal/trailing-comma handling) |
| t03-ringbuffer | Nim | implement data structure to spec |
| t04-csvbugfix | Python | debug seeded bugs (mean off-by-one, string min/max) |
| t05-todostore | Node | implement class from API contract |
| t06-stackvm | Go | debug + complete a stack VM and two-pass assembler |
| t07-validate | Python | debug seeded email/date validation bugs |
| t08-logsum | Python | implement a log-summary CLI from spec |
| t09-poolrace | Go | fix a racy worker pool (go test -race) |
| t10-iniparse | Nim | debug seeded INI-parser bugs |
| t11-asyncbugs | Node | debug seeded async bugs (ordering, retry, await) |
| t12-refactor | Go | repair what a bad refactor broke |
| t13-batchrename | Go | rename a function across 26 files |
| t14-todosweep | mixed | sweep TODO/FIXME comments into an exact report |
| t15-pollstats | Python | poll a generator 12 times, compute stats |
| t16-apisum | Python | fetch a local JSON API and aggregate |
| t17-doccheck | Go | build a checker tool and fix invariant violations |

**Mid tier (t18–t27)** — added because t01–t17 saturated (frontier models
clear them all in ~20 s/cell) while SWE-bench/DeepSWE cells burn hours.
Difficulty comes from spec fidelity and edge cases (vixie cron's dom/dow OR
rule, LCS-minimal JSON patches, tie-broken edit scripts, race-tested
sharding, tar checksums), not volume. Target: 2–10 min/cell, part-fail
expectation:

| task | language | kind |
|------|----------|------|
| t18-lruttl | Go | LRU cache with per-key TTL, injected clock, purge-before-evict |
| t19-tokbucket | Python | token bucket: refill math, atomic failed takes, µs-rounded retry_after |
| t20-jsonpatch | Node | RFC 6902-style diff/apply with LCS array alignment, exact op order |
| t21-wireproto | Go | varint/zigzag/length-delimited codec with exact error taxonomy |
| t22-cronnext | Python | cron parser + next-run (vixie dom/dow OR, leap days, NoNext) |
| t23-mergesched | Go | interval merge (adjacency ≠ overlap, max priority) + min-rooms sweep |
| t24-editops | Node | Levenshtein edit script with deterministic keep>sub>ins>del tie-break |
| t25-shardmap | Go | FNV-sharded concurrent map, exact Len under `-race` |
| t26-logfilter | Python | mini query language: lexer, precedence parser, evaluator, error positions |
| t27-tarpeek | Nim | ustar reader: checksums, octal fields, prefix/name joining |

Every repo ships its tests + `./test.sh` (exit 0 = green) in the base commit;
all are red at `base` and verified green with a reference solution. The same
prompt text (with the repo path substituted) goes to every harness.

First calibration data (niffler vs pi, glm-5.3-flash low: 20/20 pass) and the
error/token analysis behind the `meta.verify` hidden-test plan:
[midtier-analysis.md](midtier-analysis.md).

## Running

Interactive launcher (asks: target localhost/wowbagger, harnesses, model,
thinking profile, benchmark + tasks, rounds/jobs; every prompt has a default
and every answer can be passed as a flag instead — `--dry-run` prints the
command only):

```bash
node bench/launch.mjs                                   # guided
node bench/launch.mjs --dry-run --harness niffler,pi \
  --model glm-5.3-flash --thinking max --bench deepswe-pilot
```

Direct orchestrator:

```bash
# single combo
node bench/run.mjs --harness pi --model deepseek-v4-flash --task t01-roman

# paired Niffler run: ordinary loop vs explicitly armed advisory peer
node bench/run.mjs --harness niffler,niffler-expert --model all --task all \
  --jobs 2 --run-id niffler-advisory

# everything (3 harnesses × 2 models × 6 tasks), 2 lanes
node bench/run.mjs --all --jobs 2 --run-id pilot1

# report
node bench/report.mjs --run pilot1     # prints table, writes report.md/.csv
node bench/report.mjs --latest         # most recent run in var/bench/results
```

Useful flags: `--rounds N` (feedback rounds, default 6), `--turn-timeout-min`,
`--task-timeout-min`, `--test-timeout-sec`, `--max-turn-rounds N` (niffler
LLM-round budget per turn, default 100), `--harness niffler,pi`,
`--model a,b`, `--task t01,t03`, `--task-root path` (generated/custom tasks),
`--resume` (skip cells of this run id that already have a pass/fail/timeout
result — continue an interrupted run; delete a cell's result.json to re-run it),
`--keep-repos` (preserve each completed
workdir's `.git` for debugging; default strips it after `patch.diff` capture so
editors do not discover dozens of nested repositories), and
`--skip-preflight` (bypass the pre-run provider probe that aborts on
HTTP 401/402/403 — dead key or exhausted balance — before any cell runs).

Scheduling is task-major: cells are (combo, task) pairs emitted task by
task with the harness order rotated per task index, so no harness lane
systematically runs first. Niffler harnesses boot lazily on their first
cell and stay up until the run ends; fatal provider errors (401/402/403,
balance) stop a cell immediately after one verification of the partial
patch instead of burning the remaining feedback rounds.

## How each harness is driven

- **pi** — `pi --mode json -p` per round in the repo dir, continuing the same
  session file via `--session`; fully isolated config via `PI_CODING_AGENT_DIR`
  (own `models.json`, no extensions/skills/context-files). Usage summed from
  the session JSONL (authoritative, incl. cache + cost).
- **opencode** — `opencode run --format json --pure --auto -m <provider/model>
  --dir <repo>` per round, `--session <id>` to continue. Usage = sum of
  `step_finish` token counters (provider-reported).
- **codewhale** — `codewhale --provider <p> --model <m> exec --auto
  --output-format stream-json <prompt>` per round in the repo dir; round 2+
  add `--continue` (session ids are redacted in stream output, so the
  workspace-scoped continue flag is the supported continuation path).
  `CODEWHALE_HOME` is a per-run temp dir holding the custom-provider config
  (llmgateway is not native; deepseek is), and `<workspace>/.codewhale` is
  removed between rounds — sessions live in the home, the workspace dir only
  holds startup locks that would otherwise pollute the diff. Usage = sum of
  `turn_usage` events (provider-reported, incl. reasoning + cache hit/miss);
  exit code 75 (EX_TEMPFAIL) maps to a retryable transport failure.
- **niffler** — one private harness per (model) combo: own `nats-server` on a
  free port + isolated `NIF_ROOT` (symlink farm over the bench worktree, real
  `var/`), pinned to the model gateway via `NIF_OPENAI_*` env. Each round is a
  blocking `cli call session` (session tool runs the turn, returns the final
  reply). Usage summed from the persisted transcript (assistant messages carry
  `usage`). `NIF_AUTO_APPROVE=1` is set on this private harness because gated
  tools (edit/write) otherwise deny with no human reachable — it affects only
  the bench's throwaway harness, never a developer's.
  - **Workspace isolation**: the task repo is handed to the session as its
    immutable `cwd` workspace (mirrored under the harness root via
    `var/bench`), and the prompt says "your current working directory"
    instead of an absolute path — relative paths stay inside the workspace
    by construction, so no tool can wander into the harness root. Core
    resolves path-shaped tool args against that workspace at dispatch
    (bash `cd`, edit/grep/read_many paths, git `repo`).
  - **No prompt-context asymmetry**: Niffler's own `AGENTS.md` is excluded
    from the bench harness root, so the system prompt carries no contributor
    guidance other harnesses don't get.
  - **Errors are errors**: a parsed `turnError` (transport/LLM failure inside
    the turn) is reported as a failed round, cli-level transport failures get
    a bounded 3-attempt retry, and feedback rounds read the stored
    `testOutputTail` (previously the feedback prompt silently got an empty
    string). Turn-failure records are persisted with `role: "error"` and
    skipped when replaying history.
  - **Telemetry**: every persisted message carries `createdAt`, `turnId` and
    (`startedAt`, `durationMs`) for assistant/tool/error records — the
    exported `transcript.json` doubles as the timing event stream. Each
    `result.json` records `sessionId`, the workspace path and
    `firstPromptTokens` (prompt tokens of the first assistant answer — the
    cheapest cross-run proxy for system-prompt + toolset footprint).
- **niffler-expert** — the same private Niffler setup, but the runner waits for
  the expert component and calls `expert_follow` with the exact task session id
  before the first turn. The result records judgment/steer/acceptance counters,
  and expert prompt/completion/cache tokens are added to total usage. Judgments
  run on a separate cheap flash provider (`config.json` → `expertJudge`, default
  Synthetic `syn:small:text`, wired through `NIF_LLM_PROVIDERS`) so the judge
  never competes with the worker's model — the worker's input cost stays
  comparable to plain Niffler. This is a separate harness label because
  autostart alone leaves expert inert and its extra model calls must not
  disappear from Niffler's cost.

## Model wiring (as configured here)

Both bench models are reached through OpenAI-compatible endpoints; keys are
resolved at run time (env → niffler `.env` → opencode `auth.json`) and never
written anywhere:

| model | endpoint | niffler | pi | opencode |
|-------|----------|---------|----|----------|
| deepseek-v4-flash | api.deepseek.com/v1 | `NIF_OPENAI_*` | `--provider deepseek` (models.json override) | `-m deepseek/deepseek-v4-flash` |
| glm-5.3-flash | api.llmgateway.io/v1 | `NIF_OPENAI_*` | `--provider llmgateway` (models.json) | `-m llmgateway/glm-5.3-flash` |

The opencode zen gateway (`opencode-go/*`) is NOT usable here: it 403s
`deepseek-v4-flash` with a China-hosting opt-in wall and reports
"insufficient balance" for `glm-5.3-flash` on this workspace.

## Fairness notes / caveats

- Each harness keeps its **own** system prompt and tool loop — that is the
  thing being measured (harness overhead included). pi's default system prompt
  is ~1.5k tokens, opencode's ~14k, Niffler's sits in between; expect that to
  show up directly in per-round input tokens. `firstPromptTokens` in each
  Niffler result tracks the first-call footprint over time. When it exceeds
  `defaults.firstPromptBudget` (config.json), run.mjs prints a `[footprint]`
  warning and sets `footprintOver: true` — trim the direct toolset or
  baseprompt before the next run; the budget never fails a task.
- Reasoning/thinking is left at each harness's default (config knobs exist in
  `config.json` / the pi adapter for `--thinking`).
- Token totals are provider-reported sums over all LLM calls of all rounds.
  Counters are normalized to be disjoint: `total = uncached input + output +
  cache read + cache write`. Pi and opencode already report that shape;
  OpenAI-style Niffler `prompt_tokens` includes cached tokens, so the adapter
  subtracts `prompt_tokens_details.cached_tokens` into `cacheRead`.
- The verify step (`./test.sh`) runs outside the agent's turn and its duration
  is recorded separately (`testTimeS` vs `agentTimeS`).
- A run is `invalid` when the diff touches protected files even if tests pass.
- Niffler re-sends the full conversation context on each call; provider cache
  reads are reported when the gateway exposes them (including OpenAI-compatible
  `prompt_tokens_details.cached_tokens`). Multi-round tasks still amplify the
  uncached portion and total input processed.
- Expert-assisted runs are paired experiments, not the default Niffler score:
  the advisor uses additional model calls concurrently, can remain silent, and
  may finish too late to affect short tasks. Check each result's `expert.active`,
  judgment, steer, acceptance and stale-drop counters before interpreting it.

## SWE-bench Verified

See `swe/README.md` for the active 10-task SymPy pilot. `uv` installs the
pinned official SWE-bench 4.1 harness, `prepare.mjs` creates base-only checkouts
under `var/`, and official Docker images apply `test_patch` only at verification
time. `run.mjs --task-root var/bench/swe/tasks --rounds 1` runs canonical
one-shot submissions across Niffler, Pi, and OpenCode. The importer downloads
all 500 rows; omit `--repos`/`--limit` to benchmark the full set.

## DeepSWE (Datacurve)

See `deepswe/README.md`. 113 original long-horizon tasks (TS/Python/Go/Rust/JS)
from datacurve-ai/deep-swe, graded by Datacurve's own verifier inside Docker;
verified end-to-end on `etree-xml-diff-patch` (trivial patch unresolved, gold
patch resolved). Same task-root protocol: `--task-root var/bench/deepswe/tasks
--rounds 1`, with larger timeouts (--turn-timeout-min 185 --task-timeout-min
200 --test-timeout-sec 2000). Runs remotely via the niffler-bench container
(`container/README.md`) — see also bench/container/README.md.
