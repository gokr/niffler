# apisum

The repository ships a tiny local API server: `server.py` serves a JSON
dataset at `http://localhost:<port>/data.json` — records of `{"id": n,
"value": v}`. Write `solution.py` that fetches the dataset from the server
(started for you by `./test.sh` on port 8765) and writes `result.json` with
the sum of `value` over all records whose `id` is even, and how many such
records there were:

    {"sum": <n>, "count": <m>}

Use whatever your harness provides to inspect HTTP APIs while developing.
