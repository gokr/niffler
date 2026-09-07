You are working in the git repository at {{REPO}}.

Task: Implement `lib/jsonpatch.mjs` (diff, apply, deepEqual, escapeToken,
unescapeToken) so every rule in `README.md` holds and the suite passes.
The array alignment must be minimal (LCS) and op order must match the
README exactly — the tests assert exact op sequences.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify anything under `tests/`, `test.sh`, `package.json`, or
  `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
