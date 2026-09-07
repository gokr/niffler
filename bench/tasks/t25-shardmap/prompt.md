You are working in the git repository at {{REPO}}.

Task: Implement the sharded concurrent map in `shardmap.go` per `README.md`.
The suite runs under `-race` with concurrent writers — real per-shard
locking is required (a single global mutex also passes correctness, but
keep the documented FNV-1a sharding exact).

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `shardmap_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary.
