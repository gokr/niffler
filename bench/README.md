# bench — harness comparison framework

Compares coding-agent **harnesses** (Niffler, pi, opencode) on the same set of
coding tasks with the same models, and measures:

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
  adapters/            # pi.mjs, opencode.mjs, niffler.mjs
  tasks/t0*/           # prompt.md, meta.json, repo/ (pristine git repo, tag `base`)
  reports/             # committed aggregates (one *-report.{md,csv} per run)
  swe/                 # SWE-bench Verified importer (see swe/README.md)
var/bench/results/<runId>/   # raw output, disposable (gitignored, make clean wipes it)
```

## Tasks

Six self-contained repos, escalating difficulty, all "make the visible test
suite pass" (like SWE-bench's FAIL_TO_PASS, but lightweight and
dependency-free so every harness starts equal):

| task | language | kind |
|------|----------|------|
| t01-roman | Go | implement function (greedy numeral conversion) |
| t02-jsonrepair | Python | implement "almost JSON" repair (quote/literal/trailing-comma handling) |
| t03-ringbuffer | Nim | implement data structure to spec |
| t04-csvbugfix | Python | debug seeded bugs (mean off-by-one, string min/max) |
| t05-todostore | Node | implement class from API contract |
| t06-stackvm | Go | debug + complete a stack VM and two-pass assembler |

Every repo ships its tests + `./test.sh` (exit 0 = green) in the base commit;
all are red at `base` and verified green with a reference solution. The same
prompt text (with the repo path substituted) goes to every harness.

## Running

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
`--task-timeout-min`, `--test-timeout-sec`, `--harness niffler,pi`,
`--model a,b`, `--task t01,t03`, `--task-root path` (generated/custom tasks),
`--keep-repos` (preserve each completed
workdir's `.git` for debugging; default strips it after `patch.diff` capture so
editors do not discover dozens of nested repositories).

## How each harness is driven

- **pi** — `pi --mode json -p` per round in the repo dir, continuing the same
  session file via `--session`; fully isolated config via `PI_CODING_AGENT_DIR`
  (own `models.json`, no extensions/skills/context-files). Usage summed from
  the session JSONL (authoritative, incl. cache + cost).
- **opencode** — `opencode run --format json --pure --auto -m <provider/model>
  --dir <repo>` per round, `--session <id>` to continue. Usage = sum of
  `step_finish` token counters (provider-reported).
- **niffler** — one private harness per (model) combo: own `nats-server` on a
  free port + isolated `NIF_ROOT` (symlink farm over the bench worktree, real
  `var/`), pinned to the model gateway via `NIF_OPENAI_*` env. Each round is a
  blocking `cli call session` (session tool runs the turn, returns the final
  reply). Usage summed from the persisted transcript (assistant messages carry
  `usage`). `NIF_AUTO_APPROVE=1` is set on this private harness because gated
  tools (edit/write) otherwise deny with no human reachable — it affects only
  the bench's throwaway harness, never a developer's.
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
  show up directly in per-round input tokens.
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
one-shot submissions across Niffler, Pi, and OpenCode.
