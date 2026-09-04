You are working in the git repository at {{REPO}}.

Task: The test suite of this project fails under `go test -race`. Find and
fix the bug(s) in `pool.go` — the worker pool must return the correct sum
and pass the race detector. Do not work around the bugs in the tests or
change what the function is documented to do — fix the implementation.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `pool_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary naming each bug you fixed.
