You are working in the git repository at {{REPO}}.

Task: Implement `cron.py` (parser + matches + next_after) so every rule in
`README.md` holds and the suite passes. Pay attention to the vixie
day-matching rule (dom/dow OR when both are restricted), dow 7 = Sunday,
month-length skipping, leap days, and the NoNext case.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test_cron.py`, `test.sh`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
