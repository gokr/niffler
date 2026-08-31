# SWE-bench Verified — status and path forward

[SWE-bench Verified](https://huggingface.co/datasets/princeton-nlp/SWE-bench_Verified)
(500 human-validated GitHub issues across 12 real repos) is the credible
external benchmark for this comparison. As of this first pass we did **not**
run it end-to-end; here is exactly why and what is missing.

## Why not today

The official evaluation stack (`github.com/SWE-bench/SWE-bench`,
`python -m swebench.harness.run_evaluation`) needs, per task:

- a repo-specific docker image (`swebench/sweb.eval.x86_64.<repo>` —
  commonly 2–12 GB each; docker is available here and ~970 GB free, so this
  part is feasible for a subset),
- a Python env at the repo's pinned versions (the official images bake this
  in; building them locally needs pip, which this box currently lacks),
- the `swebench` pip package for orchestration/grading.

So the blocking dependency is a Python package manager (pip/uv), not
hardware. With pip available, the *lite* path below is a weekend, not a
project.

## What exists already

`import.mjs` downloads all 500 Verified task cards via the HF
datasets-server API (no pip/parquet tooling needed):

```bash
node bench/swe/import.mjs --out bench/swe/tasks.jsonl
# starter subset (pure-python repos, lightest envs):
node bench/swe/import.mjs --out bench/swe/tasks-sympy.jsonl --repos sympy/sympy
```

Each card carries `instance_id, repo, base_commit, problem_statement,
test_patch, FAIL_TO_PASS, PASS_TO_PASS` — everything this runner needs.

## How it plugs into this runner (hidden-test mode)

Unlike the bench tasks (tests visible in the repo), SWE tasks must hide the
tests from the agent and apply `test_patch` only at verification time. The
runner supports this via a task-level `verify` script: put a `verify.sh`
next to `prompt.md` and reference it from `meta.json` (`"verify":
"verify.sh"`); the runner executes it with the agent's repo as cwd and
treats exit 0 as green. A SWE `verify.sh` would:

1. `git apply` / `git checkout` the card's `test_patch` onto the workdir
   repo (the agent never sees these files during its turn),
2. run the repo's pinned test command,
3. check the FAIL_TO_PASS list went red→green and PASS_TO_PASS stayed green.

## Remaining work, in order

1. Install pip/uv (`python3 -m ensurepip` is disabled on this Ubuntu box;
   `curl get-pip.py | python3` or a standalone `uv` binary both work).
2. For a starter repo (sympy is pure-Python), script per-task env setup:
   clone at `base_commit`, `pip install -e .` + test deps into a venv.
3. Generate task dirs from `tasks.jsonl` (clone + prompt from
   `problem_statement` + `verify.sh` from `test_patch`).
4. Pilot with ~10 sympy tasks × 3 harnesses; then scale via the official
   docker images for the full 500.
