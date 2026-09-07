You are working in the git repository at {{REPO}}.

Task: Implement the LRU+TTL cache in `cache.go` so that every rule in
`README.md` holds and the full test suite passes. The method skeletons are
in place — fill in correct semantics (recency order, TTL expiry, purge
before evict, disabled zero-capacity mode).

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `cache_test.go`, `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line
  summary of the trickiest rule you implemented.
