# Worklist slice: (X) Claims that are simply wrong

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A105 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 370-372** — "Loading rules (**identical** in the Nim SDK, Go SDK and the UI bridge): … `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order." The UI bridge passes them the other way round (`ui/bridge.go:71`), so in the desktop app the harness-root `.env` beats a `.env` in the cwd, while components do the opposite (`sdk/niffler/sdk.nim:771`, `sdk/go/component.go:414`).

## A107 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 254** — the repomap/lsp/**skills** marker sentence: `skills` walks no build files (`components/skills/main.nim:200-215`), and the marker sets are language-specific (`components/lsp/roots.nim:29-34`) plus `Cargo.toml` (`components/repomap/main.nim:134`) — not the four files named.

## A108 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 1116-1122** — "≤100 servers per harness" is not enforced anywhere in `components/mcp` (the manager lists up to 1000 records, `components/mcp/main.go:170`).

## A109 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 511-514** — "wall-clock seconds (checked before every tool dispatch, not only between rounds)" reads as applying to all three soft limits; only seconds is (`core/conversation.nim:2190-2196` vs the round-boundary checks at `:1817,1823`).

## A112 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 570** (inherited) — `cacheHitTokens`/`cacheHitRatio` do not exist; the event nests `cache {prompt, read, hitRate}` (`core/conversation.nim:2103-2106`). Also `components/hooks/README.md:35`.

## A113 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: Content-level drift found by the companions and confirmed here: the approval-gated tool list (MANUAL 457-467, ten names missing), `/limit`'s 5-minute claim (obs report), the orphaned-`nats-server` cause (sessions report), and the web UI's delete path that bypasses `conversation_delete` (sessions report). They are listed in (X) terms there; do not re-litigate here.

## A147 (wrong)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~369 "`.env.example` in the repo root is the complete reference: **every** `NIF_*` variable"
- CODE: `grep -oE 'NIF_[A-Z0-9_]+' .env.example | sort -u | wc -l` = 105 vs MANUAL's own table 94 distinct; `.env.example` is **missing** `NIF_AUTO_CONTINUE`, `NIF_REPOMAP_MIN_CENSUS`, `NIF_REPOMAP_MIN_BYTES`, `NIF_REPOMAP_MIN_SYMBOLS`, `NIF_REPOMAP_MIN_FILES` (all real: `core/approval.nim:263`, `components/repomap/main.nim:178-186`)
- FIX: add those five lines to `.env.example`, or soften MANUAL to "the reference copy of the documented variables".

