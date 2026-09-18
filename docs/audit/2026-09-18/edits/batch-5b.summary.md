# batch 5b — consolidation result

28 rows in, 28 rows out (`batch-5b.json`). Slices: `component-fabric` (11),
`provider-registry-provider` (8), `wrong-claims-summary` (6),
`y-missing-capability` (3).

## Counts

| status | n | ids |
|---|---|---|
| apply | 16 | A047, A176, A252, A253, A254, A255, A336, A337, A338, A339, A342, A343, A466, A473, A474, A478 |
| already | 4 | A175, A251, A333, A335 |
| skip | 6 | A048, A049, A050, A334, A344, A345 |
| code | 2 | A177, A259 |
| unclear | 0 | — |

All 16 `apply` rows were re-checked against the **current** `docs/MANUAL.md`
after writing: every `old_string` occurs exactly once (script check, not a
by-eye pass).

## Things the parent should know

1. **`docs/MANUAL.md` was being edited while this batch ran** (2403 lines when it
   started, 2566 when it finished). Two of my initial anchors died that way and
   were re-anchored on the live text:
   - A343 (Self-extension step 4 grew a runner-kill sentence) — re-anchored.
   - A252/A253/A255 were re-read in the approval section; A255 is now only
     *half* open (the bare `spawn`/`kill`/`remove` names are already fixed; my
     edit adds only the "gated by name, not by schema" bullet).
   Apply soon, or re-run the uniqueness check.
2. **A251 and A175 were already fixed** by whoever edited the manual in the
   meantime. A251's approval list now contains all ten tools the report called
   missing (only the optional "…and any plugin tool that sets it" clause is
   absent); A175's thinking/effort documentation already sits in the `session`
   tool bullet (601-605), so no "Effort/thinking" subsection was added.
3. **A047 deviates from the written FIX on purpose**: the row asks for a flags
   column in the 17-row provider tool table. A column would reformat every row
   and collide with A466/A473/A474/A478 (which edit rows of that same table),
   so the same facts are added once as an "Exposure flags" legend line under
   the table. If you prefer the literal column, drop A047 and do it as its own
   change.
4. **Two `code` rows, no prose change**: A259 (`components/hooks/main.nim:2`
   cites `docs/HOOKS.md`, which does not exist — verified missing) and A177
   (core's `thinking` enum lacks `"max"`). I did not re-read either `.nim` file
   in this pass (source reading was outside the batch budget), so confirm the
   line before fixing — A177's enum value is the one to double-check.
5. **A344 skipped**: the `make test-bash` example list is illustrative and
   already omits test-grep/test-edit/test-mcp/test-agent*; adding only
   test-fabric would keep it non-exhaustive while looking complete.
6. A334 is the same structural finding as A337 (fabric bullets nested under
   `### Fork`); the single edit lives in A337. A333/A335 are deltas with no
   proposed change.
