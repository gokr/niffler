You are working in the git repository at {{REPO}}.

Task: Implement the ustar reader in `tarpeek.nim` per `README.md` (header
layout, checksum verification, octal parsing, prefix/name joining,
512-block skipping). The test embeds three base64 fixtures produced by
GNU-compatible tar; all must behave exactly as asserted.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test_tarpeek.nim`, `test.sh`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
