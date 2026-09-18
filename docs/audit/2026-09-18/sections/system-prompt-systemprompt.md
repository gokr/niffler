# Worklist slice: System prompt (systemprompt)

From `worklist.tsv` (3 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A083 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1697-1712 (frozen per conversation in header `systemPrompt`, fallback "component absent, slow (500 ms probe, then an 8 s budget when the catalog says it is registered)", "Cap. Answers are truncated at 200 KB (both sides)", agent pre-fetch)
- CODE: `core/conversation.nim:67` (`systemPromptTimeoutMs = 8_000`), `:78-97` (500 ms probe then the full budget only if registered, truncation at 200 000 bytes), `:2394-2401` (header/args), `components/systemprompt/main.nim:29` (`maxPromptLen = 200_000`) ✔
- FIX: none.

## A084 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1713-1727 ("`baseprompt.txt` … `${ROOT}`-substituted, baked into the binary at compile time via `staticRead`. Editing it is rebuild + respawn")
- CODE: `components/systemprompt/main.nim:36` (`staticRead("baseprompt.txt")`) ✔
- FIX: none.

## A085 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1727-1740 (context files: `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`, ancestor walk, worktree shadow rule, `<workspace>` tail only when cwd ≠ root)
- CODE: `components/systemprompt/main.nim:8-17,44,114-190,248-265` ✔
- FIX: none — this is the most accurate mechanism section in the file.

