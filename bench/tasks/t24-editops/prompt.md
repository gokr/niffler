You are working in the git repository at {{REPO}}.

Task: Implement `lib/editops.mjs` (editOps, cost, applyOps). The alignment
must be minimal AND deterministic: the tie-break rule in `README.md`
(keep > sub > ins > del) decides equal-cost paths — tests assert exact op
sequences.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify anything under `tests/`, `test.sh`, `package.json`, or
  `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
