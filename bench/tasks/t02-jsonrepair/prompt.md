You are working in the git repository at {{REPO}}.

Task: Implement `repair(text)` in `src/repair.py` so the full test suite passes.

`repair` converts "almost JSON" into valid JSON. The input may contain:
- single-quoted strings and keys (convert to double quotes, honoring escapes)
- `True`, `False`, `None` literals (convert to `true`, `false`, `null`)
- trailing commas after the last element of objects and arrays (remove them)

Content inside string literals must be preserved exactly (a comma, brace or
the word True inside a string is data, not syntax). Valid JSON input should
come through unchanged. The output must parse with `json.loads`.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify anything under `tests/`, `test.sh`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line summary.
