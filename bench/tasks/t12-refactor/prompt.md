You are working in the git repository at {{REPO}}.

Task: A recent refactor extracted the shared `row()` helper in `report.go`
and the test suite stopped passing. Find and fix what the refactor broke.
Do NOT revert the refactor — keep the shared helper; fix the logic around
it so `./test.sh` passes.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `report_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary naming each bug you fixed.
