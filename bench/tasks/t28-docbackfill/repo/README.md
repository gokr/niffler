# docbackfill

This module ships three packages (`alpha`, `beta`, `gamma`) whose exported
API is pinned by `smoke_test.go` — behavior must not change. What is missing
is package documentation: every file must carry its package's doc comment as
the **first line of the file, directly above the `package` clause**, exactly
once, with this exact text (copy it byte-for-byte):

| package | exact doc comment |
|---------|-------------------|
| `alpha` | `// Package alpha provides weighted moving-average primitives.` |
| `beta`  | `// Package beta implements deterministic token-bucket rate limiting.` |
| `gamma` | `// Package gamma scores text similarity with set metrics.` |

Current state, per file:

- some files already carry the exact comment — leave them untouched;
- some files carry no comment — insert the exact line as the new first line;
- some files carry a **drifted** variant (wrong wording or capitalization) —
  replace that first line with the exact text.

Do not modify function bodies, signatures, file names, or the package clause.
`check.py` is the normative spec and checks every file byte-precisely;
`./test.sh` runs the pinned behavior test plus the doc check and must exit 0.
