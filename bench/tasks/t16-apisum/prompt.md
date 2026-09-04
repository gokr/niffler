You are working in the git repository at {{REPO}}.

Task: Write `solution.py` that fetches the JSON dataset from the local API
server (started for you by `./test.sh` on port 8765, see `README.md`) and
writes `result.json`: the sum of `value` over records with an even `id`,
and the count of those records. Use whatever your harness provides to
inspect HTTP APIs while developing.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `check.py`, `test.sh`, `server.py`, or `README.md`.
- Work only inside the repository. When the check passes, reply with a
  one-line summary of the values you computed.
