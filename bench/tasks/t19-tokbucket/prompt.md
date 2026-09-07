You are working in the git repository at {{REPO}}.

Task: Implement the token-bucket rate limiter in `tokbucket.py` exactly as
specified in `README.md` (refill math, atomic failed takes, retry_after with
microsecond rounding, capacity cap). Replace every NotImplementedError.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test_tokbucket.py`, `test.sh`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
