You are working in the git repository at {{REPO}}.

Task: `lib.mjs` was migrated to a new API, and every `svcNN.mjs` module
still calls the old one. Fix all 24 modules per the migration spec in
`README.md` — each module's own header directives (`// profile:`,
`// width:`) determine its correct arguments, so every module gets a
different edit. There are many files with per-file differences — use
whatever your harness provides for mechanical, repetitive work.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test.mjs`, `test.sh`, `lib.mjs`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a
  one-line summary of what you changed.
