You are working in the git repository at {{REPO}}.

Task: Implement the binary codec in `wire.go` (AppendUvarint, AppendVarint
with zigzag, AppendField, Decode) exactly as specified in `README.md`,
including the precise error taxonomy. All tests must pass.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `wire_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
