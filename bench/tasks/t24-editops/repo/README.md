# editops — Levenshtein alignment with deterministic tie-breaking

`editOps(a, b)` computes a minimal edit script (ops array) from `a` to `b`:

- Costs: keep 0, sub/ins/del 1. `cost(ops)` counts non-keep ops and equals
  the Levenshtein distance.
- Op encoding (indices refer to positions in `a` / `b`):
  - `{op:"keep", a}` — `a[a]` kept
  - `{op:"sub", a, b, ch}` — `a[a]` replaced by `ch` (which is `b[b]`)
  - `{op:"ins", b, ch}` — `ch` inserted (which is `b[b]`)
  - `{op:"del", a}` — `a[a]` deleted
- Ops are emitted left to right; both cursors advance monotonically.
- **Tie-break rule**: when several moves lead to the same minimal total
  cost, choose in this order:
  1. `keep` (only when `a[i] === b[j]` and the diagonal is minimal),
  2. `sub`,
  3. `ins`,
  4. `del`.
- `applyOps(a, ops)` reconstructs `b`. It must throw `Error` on
  inconsistent input: out-of-range or non-advancing indices, unknown op
  names, or ops that fail to consume the whole of `a` / produce all of `b`.
