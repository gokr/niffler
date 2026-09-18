# Worklist slice: System prompt (systemprompt)

From `worklist.tsv` (7 rows). `class` is one of
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

## A644 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "1. `components/systemprompt/baseprompt.txt` — the product prompt"
- CODE: `components/systemprompt/baseprompt.txt:44-48`
- FIX: add — "The product prompt is also where the model is taught the replaced-content recourse: it states that pruned tool results, spilled command output and compaction checkpoints are retrievable with `context_recall` by passing the ref quoted in the notice verbatim. Change that sentence and this component's notices stop being followed."

## A788 (trim)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2331 `(self-extension ladder, SDK examples, repo layout), `$ROOT`-substituted,`
- CODE: `components/systemprompt/main.nim:36` (`const basePrompt = staticRead("baseprompt.txt")`), `:240` (`var prompt = basePrompt` — used verbatim; there is no `%`/`replace`/`strformat` pass anywhere in the file), `:262-270` (the root reaches the prompt only through the optional `<workspace>` tail, and as a comment explicitly forbids `$ROOT` in the head)
- FIX: update — "1. `components/systemprompt/baseprompt.txt` — the product prompt (change-scope discipline, tool-selection guidance, the docs pointer), baked into the binary verbatim at compile time via `staticRead` (no substitution, no template). Editing it is rebuild + respawn; there is no runtime file dependency."

## A789 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2340-2341 `- ancestor walk from the conversation's cwd up to `/`, harness root first, deduplicated by path`
- CODE: `components/systemprompt/main.nim:204` (`let stopAbove = if cwd == root or cwd.startsWith(root & "/"): root else: cwd`), `:209-226` (the loop breaks at `stopAbove`, so the walk is cwd→root **inclusive** for an in-root workspace and a single directory for a workspace outside the root; nothing above the harness root is ever read), `:74-84` + `:217-219` (`fileId` = `device:inode`, dedupe by identity, not by path — a symlink farm re-exposing the root would otherwise inject the same `AGENTS.md` twice)
- FIX: update — "- ancestor walk from the conversation's cwd **up to the harness root (inclusive)**, root first, deduplicated by file identity (device:inode, so a symlink farm cannot inject the same file twice) — nearer-to-cwd files appear later, so the most specific instructions are the last thing the model reads. A workspace **outside** the harness root walks its own directory only: nothing above the deployment root leaks into the prompt (an unrelated `AGENTS.md` in `$HOME` in particular)."

## A795 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2322 `- **Cap.** Answers are truncated at 200 KB (both sides).`
- CODE: `components/systemprompt/main.nim:268-270` (200_000 bytes), `core/conversation.nim:96-98` (200_000 bytes)
- FIX: none — verified accurate.

