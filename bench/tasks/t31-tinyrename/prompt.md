You are working in the git repository at {{REPO}}.

Task: rename the exported function `Drain` to `DrainAll` everywhere it is used as a name, so the full test suite passes.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test.sh`, `queue_test.go`, `go.mod`, or `CHANGELOG.md`.
- Prose that documents the current API (README.md) follows the rename; the CHANGELOG records history and does not.
- Work only inside the repository. When the tests pass, reply with a one-line summary of what you changed.
