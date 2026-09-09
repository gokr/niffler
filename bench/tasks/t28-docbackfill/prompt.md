You are working in the git repository at {{REPO}}.

Task: Every file in the `alpha/`, `beta/` and `gamma/` packages must carry
its package's doc comment as the exact first line — see README.md for the
exact per-package text and the current per-file state (some files already
carry it untouched, some have none, some carry a drifted variant that must
be replaced). There are many files with per-file differences — use whatever
your harness provides for mechanical, repetitive work.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `check.py`, `test.sh`, `go.mod`, `smoke_test.go`, or
  `README.md`; do not change any function body or signature.
- Work only inside the repository. When the check passes, reply with a
  one-line summary of what you changed.
