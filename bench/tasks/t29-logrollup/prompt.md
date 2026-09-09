You are working in the git repository at {{REPO}}.

Task: Produce `summary.json` at the repository root: a roll-up of all 36
files under `logs/` (line counts, per-level counts, first/last timestamps),
in the exact canonical form specified in `README.md` (and enforced
byte-for-byte by `check.py`, which you may read as the normative spec). The
logs total ~450KB — reading them all into the conversation would be waste;
use whatever your harness provides for bulk, mechanical work.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `check.py`, `test.sh`, `logs/**`, or `README.md`.
- Work only inside the repository. When the check passes, reply with a
  one-line summary of what you produced.
