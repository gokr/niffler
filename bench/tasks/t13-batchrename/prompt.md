You are working in the git repository at {{REPO}}.

Task: Rename the function `OldName` to `NewName` across the entire
codebase: the definition in `def.go` and every call site in the `fNN.go`
files. The test suite verifies the rename is complete and that behavior is
unchanged. There are many call sites — use whatever your harness provides
for mechanical, repetitive work.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `rename_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary of what you changed.
