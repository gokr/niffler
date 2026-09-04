You are working in the git repository at {{REPO}}.

Task: Run `python3 generator.py <seed>` once for every seed from 1 through
12, collect the 12 printed values, and write `stats.json` with their
minimum, maximum and mean (each rounded to two decimal places), exactly as
specified in `README.md`. There are many runs to make — use whatever your
harness provides for repetitive, mechanical work.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `check.py`, `test.sh`, `generator.py`, or `README.md`.
- Work only inside the repository. When the check passes, reply with a
  one-line summary of the values you computed.
