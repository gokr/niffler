# SWE-bench Verified pilot

[SWE-bench Verified](https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified)
contains 500 human-validated issues across 12 real repositories. The first
Niffler pilot is deliberately smaller: the first 10 SymPy cards, one worker
model, and the three plain harnesses (Niffler, Pi, OpenCode).

A second pilot widens the surface to non-Python work:
[SWE-bench Multilingual](https://huggingface.co/datasets/SWE-bench/SWE-bench_Multilingual)
(300 tasks, 8 languages — Go, Rust, C, C++, JavaScript, TypeScript, Java,
Ruby, PHP) contributes the 10-task `tasks-multi` set: caddy, gin, tokio,
nushell, redis, jq, fmt, axios, docusaurus, rubocop. Its rows carry
embedded eval specs (`eval_script`/`image`/`log_parser`), so it evaluates
under a **second harness venv** — see "Two harness generations" below.

## Two harness generations

The two dataset generations need different swebench majors, so `setup.sh`
builds two venvs and `verify.mjs` picks by dataset shape:

- `var/bench/swe/.venv` — `swebench==4.1.0` (requirements.txt): classic
  repo/version test specs and prebuilt `swebench/sweb.eval.*` images;
  evaluates SWE-bench_Verified rows (the SymPy pilot). 5.x cannot evaluate
  these (it dropped the classic specs).
- `var/bench/swe/.venv-multi` — `swebench==5.0.2`
  (requirements-multi.txt): evaluates rows whose JSONL carries an embedded
  `eval_script` (SWE-bench_Multilingual). `verify.mjs` detects the field in
  the dataset's first row and routes there automatically;
  `NIF_SWEBENCH_PYTHON` overrides. 5.x removed `--cache_level`/`--clean`,
  so verify.mjs only passes them on the classic path.

Both pipelines were validated after the split: a known-resolved SymPy cell
re-graded resolved under 4.1.0, and a Multilingual gold-patch run
(`jqlang__jq-2235`) resolved under 5.0.2.

## Current status

The old blocker is gone: `uv` and Docker are installed. The supported path now
uses `swebench==4.1.0` and official `swebench/sweb.eval.*` images. Version 5.x
expects a newer enriched task format and cannot directly evaluate the classic
Verified rows used here (the multilingual pilot uses 5.x for exactly that
reason — see "Two harness generations").

The end-to-end evaluator has been proved on `sympy__sympy-11618`:

- no-op patch: unresolved (base red);
- dataset gold patch: resolved (reference green);
- official image: 3.92 GB; first pull + evaluation took about 9 minutes;
- cached evaluations take about 25 seconds.

## Setup and prepare the 10-task pilot

Everything generated or downloaded stays under `var/bench/swe/`.

```bash
# Install the pinned official harness into var/bench/swe/.venv, plus the
# 5.x multilingual harness into var/bench/swe/.venv-multi.
bench/swe/setup.sh

# Import the first 10 SymPy cards. Gold/test patches remain outside agent repos.
node bench/swe/import.mjs \
  --out var/bench/swe/tasks-sympy.jsonl \
  --repos sympy/sympy --limit 10

# Create base-only task checkouts and pre-pull official images. Image setup is
# intentionally outside measured agent/verification time.
node bench/swe/prepare.mjs \
  --input var/bench/swe/tasks-sympy.jsonl \
  --out var/bench/swe/tasks \
  --pull-images --workers 2

# Multilingual pilot (separate task root; import all 300 rows, then trim to
# the selected 10 — see the list in tasks-multi.jsonl's sibling import note).
node bench/swe/import.mjs \
  --dataset SWE-bench/SWE-bench_Multilingual \
  --out var/bench/swe/tasks-multi-catalog.jsonl
node bench/swe/prepare.mjs \
  --input var/bench/swe/tasks-multi.jsonl \
  --out var/bench/swe/tasks-multi \
  --pull-images --workers 2
```

`prepare.mjs` keeps one Git mirror for efficient setup, but each agent checkout
contains only its shallow `base_commit` plus a local `base` tag. Future commits,
the gold patch, and the hidden `test_patch` are not exposed in the working repo.

## Run the pilot

Start with one cell after the first image is cached:

```bash
node bench/run.mjs \
  --task-root var/bench/swe/tasks \
  --task sympy__sympy-11618 \
  --harness niffler --model deepseek-v4-flash \
  --rounds 1 --turn-timeout-min 30 --task-timeout-min 45 \
  --test-timeout-sec 1200 --run-id swe-smoke
```

Then run the described 10 × 3 pilot:

```bash
node bench/run.mjs \
  --task-root var/bench/swe/tasks \
  --task all \
  --harness niffler,pi,opencode \
  --model deepseek-v4-flash \
  --rounds 1 --jobs 2 \
  --turn-timeout-min 30 --task-timeout-min 45 \
  --test-timeout-sec 1200 \
  --run-id swe-sympy10-$(git rev-parse --short HEAD)
```

`--rounds 1` preserves canonical SWE-bench one-shot evaluation: the agent never
sees hidden-test output before its submitted patch is scored. A later
*time-to-green* experiment may use multiple rounds, but must be reported as a
separate non-canonical metric because verifier feedback is then returned to the
agent.

## How hidden verification works

Each generated task has only:

- `repo/` at `base_commit`;
- `prompt.md` containing `problem_statement`;
- `meta.json` and a tiny verifier wrapper.

After the turn, `verify.mjs` captures `git diff --binary base` (including
untracked files), writes an official prediction JSONL, and asks SWE-bench to:

1. start the pinned instance image;
2. apply the candidate patch to `/testbed`;
3. apply `test_patch` only inside that evaluator container;
4. run the repository/version-specific command;
5. require all `FAIL_TO_PASS` and `PASS_TO_PASS` checks to succeed.

The task's hidden-test files are also listed as protected paths, so modifying a
corresponding test file makes the benchmark result invalid even if grading
passes. Raw evaluator logs live under `var/bench/swe/evaluations/`.

This is test hiding, not a hostile-process sandbox: an agent intentionally
searching outside its assigned repository could inspect host files. The three
harnesses are instructed to work only in `{{REPO}}`, matching the trust model of
this local comparison.

## Pilot status

The 10-task sympy pilot has run end-to-end for both bench models (one-shot,
three harnesses): deepseek-v4-flash 9/9/6 (pi/opencode/niffler), glm-5.3-flash
8/7/5. Numbers and protocol notes:
[bench/reports/swe-sympy10-pilot-report.md](../reports/swe-sympy10-pilot-report.md).
Raw result dirs live under `var/bench/results/swe-sympy10-*`.
