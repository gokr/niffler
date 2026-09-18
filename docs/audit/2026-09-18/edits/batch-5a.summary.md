# batch-5a — consolidation result

Slices: `sections/component-edit.md` (16), `sections/environment-variables.md`
(14), `sections/the-env-file.md` (1) — **31 rows**.

| status | n | ids |
|---|---|---|
| apply | 18 | A025, A262, A298, A299, A300, A301, A302, A303, A306, A386, A387, A394, A398, A421, A440, A441, A442, A453 |
| already | 3 | A026, A408, A028 |
| skip | 8 | A024, A294, A295, A296, A307, A308, A309, A311 |
| code | 2 | A310, A312 |
| unclear | 0 | — |

All 18 `old_string`s were verified against the **current** `docs/MANUAL.md`
(2566-line revision): each occurs exactly once, and applying them in file order
leaves every later anchor unique (simulated). Nothing outside
`edits/batch-5a.json` and this file was written.

## Already fixed since the audit (18 h old)

- **A026** — the `.env.example` sentence is already softened ("not exhaustive
  in either direction … the table is authoritative", MANUAL:401-408).
- **A408** — the `NIF_LSP_BIN_DIRS` row already says "used verbatim — `~` is
  **not** expanded here; use absolute paths" (MANUAL:337), so the false
  "(tilde-expanded)" claim is gone.
- **A028** — the `.env` loading rules already state the per-binary order and
  the UI-bridge exception (MANUAL:402-406).

## Needs a human decision

1. **A262 has a second site.** The applied edit fixes the `NIF_AUTO_APPROVE`
   row (MANUAL:365). The prose at **MANUAL:571** (`NIF_AUTO_CONTINUE=1`
   answers every keep-going question with yes) still credits only
   `NIF_AUTO_CONTINUE`; it needs "(or `NIF_AUTO_APPROVE=1`)". The two sites are
   ~200 lines apart, so one row cannot carry both as a single `old_string`.
2. **A311 is folded into A299.** The undo store's retention sentence (one
   record per file, no cap or eviction, safe to delete) lives inside the state
   table row A299 inserts (MANUAL:271) — a second edit anchored at the same
   site would be ambiguous at apply time. A311 therefore carries no edit of its
   own.
3. **A310, A312 are code fixes**, not prose:
   - A310: `components/edit/main.nim:1333` hardcodes "Cap 900KB" in `write`'s
     schema description while `NIF_WRITE_MAX_BYTES` can change the real cap.
   - A312: `read` declares `parallel: true` with no `"effect": "read"`, so the
     fabric batch host classifies it as a write and serializes it — either add
     the effect or state the serialization in the fabric section.
   Both were located by grep only; the parent should verify before patching.
4. **A386/A387/A394/A398/A421** (llm/mcp rows) apply the reports' code claims
   verbatim; no Go source was re-read in this pass (budget steer: docs-only).
