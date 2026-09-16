# FAST-APPLY — the "fast apply" edit family, and where each harness sits

> Survey (2026-09-16) of what people mean by **fast-apply diff/patch**. Two
> questions shape it: (1) does the model generate the *whole* result, and
> (2) who does the matching when the model's fragment doesn't line up —
> a deterministic ladder, or a second model?
>
> Basis: the clone shelf `~/git/harnesses/` at the commits in its
> `README.md` (in particular codex `1715e550`, opencode `95daf906`,
> CodeWhale `06b44cca5`, octofriend `6b2159f`, plandex `e2d7720`,
> aider `5dc9490`, dsh `c291e7961a`), plus two sources that are **not** local
> checkouts and are marked as such wherever cited:
> (a) **Claude Code `2.1.268`** — no source is published, so all Claude Code
> claims come from `strings` of the installed 209 MB compiled Bun binary
> (`~/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`) plus
> its generated `sdk-tools.d.ts`;
> (b) **OpenHands's `str_replace_editor` / `file_editor`** — the local
> `~/git/harnesses/OpenHands-python` checkout is the Python *server + app-server*
> tree only (`openhands/app_server/…`; no tool code) and
> `~/git/harnesses/OpenHands` is the frontend-only Agent Canvas, so the editor
> implementation was read from `OpenHands/software-agent-sdk` on GitHub
> (`openhands-tools/openhands/tools/file_editor/editor.py`, `main`). Neither is
> pinned to a commit — treat those two columns as *current upstream*, not as
> reproducible-at-a-sha.
> Niffler baseline: `components/edit` (0.3.0) at this repo's HEAD.
>
> Companion docs: [AIDER.md](AIDER.md) (strategy ladders),
> [OCTOFRIEND-STEAL.md](../OCTOFRIEND-STEAL.md) (the repair-hook proposal),
> [DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) (dsh's *strict* edit tool).

## 0. The term, decompressed

"Fast apply" never means "applying a patch quickly" — patching bytes is
microseconds. It is a claim about **who spends output tokens and who resolves
the mismatch**:

- **Lazy edits** — the main model emits only the lines it touches plus
  placeholders (`// ... existing code ...`), instead of re-emitting unchanged
  context. Output tokens collapse, and the "old_string didn't match" loop
  disappears.
- **A second set of eyes** — some other component merges the fragment into the
  full file. That component is either **deterministic** (normalization tiers,
  line seeking) or **a model** (a fast-applier or a repair model).

Every harness in the shelf does at least one of those; the interesting
question is which, and what happens when the lazy edit is *ambiguous*. Four
families exist, and the naming is a mess because "fast apply" is used for
three of them:

| Family | Lazy edit? | Who matches | Speed claim comes from |
|---|---|---|---|
| **A. Deterministic forgiving apply** | no — model still emits exact text | escalating normalization, no inference | `git apply`-style tolerance; no extra round trip |
| **B. Patch-dialect envelope** | yes — hunk headers + only changed lines | line seeking inside a parser | fewer output tokens, one call for many files |
| **C. Dedicated apply model** (the literal "Fast Apply") | yes — markers/placeholders | a *model* merges fragment into file | a small fast model at ~10.5k tok/s, off the main model's bill |
| **D. Repair hook** (fast apply only on failure) | no | model fixes the *search string* after a failed match | rare by construction; main model never sees the failure |

Families are orthogonal: a harness can ship A *and* B (opencode does), or A
*and* D (octofriend does). Nobody in the shelf ships all four.

## 1. Do Claude Code and Codex use this?

Direct answers, since the original question asked:

- **Codex — yes, family B, and it is the reference implementation.** Codex's
  model-facing edit tool *is* `apply_patch`: a FREEFORM (non-JSON) tool with a
  Lark grammar (`codex-rs/core/src/tools/handlers/apply_patch_spec.rs:5,9,19`,
  grammar at `codex-rs/core/assets/tools/apply_patch.lark`), whose text is the
  `*** Begin Patch` dialect. Applying it is family A inside the envelopes:
  `seek_sequence` tries exact → rstrip → trim → Unicode-folded
  punctuation/spaces (`codex-rs/apply-patch/src/seek_sequence.rs:3-119`), with
  an `eof` bias for patterns meant to anchor at the end of file
  (`file_update.rs:100,145,163`), and a line-ending mode switch
  (`NormalizeToLf` vs `PreserveLineEndings`, `lib.rs:64-94`). The dialect has
  an explicit `*** End of File` marker (`parser.rs:22`, `lib.rs:1239`), and
  codex refuses ambiguity rather than guessing. So: lazy edits yes, apply
  model no.
- **Claude Code — no.** There is no fast-apply path and no apply model in the
  binary. Its `Edit` tool is exact-match `old_string`/`new_string`
  (`sdk-tools.d.ts`, `FileEditInput`), with two *failures modes that are echoed
  verbatim*: `String to replace not found in file.` and
  `Found ${n} matches of the string to replace, but replace_all is false.`
  What it has instead is a small honest fallback chain that is family A but
  *much* narrower than codex's — I found its matcher (`function $me(e,n)`)
  doing four things: exact substring; then smart-quote normalization
  (`Dpn` → `'`/`"`) searched in the normalized file; then `\uXXXX`
  escape-decode when the search contains escapes; then a regex search when the
  search contains non-ASCII (`tst`/`nst` → `Npn`). Plus a **stale-file
  recovery** path: if the file changed on disk since the model last read it and
  the edit still applies cleanly, it lands with `staleRecovered: true` and the
  model is told "(note: the file had been modified on disk since you last read
  it — the edit applied cleanly)". Ambiguity is refused without a fuzz tier.
  Claude Code's "small fast model" (`ANTHROPIC_SMALL_FAST_MODEL`) is used for
  web-fetch summarization and similar side tasks — **not** for applying edits.
  So the answer to "does Claude Code use fast-apply": no; it uses exact match
  + whisper-thin normalization + stale recovery.

  *Caveat, stated plainly:* this is `strings`-based. Control flow that never
  appears as adjacent literals (e.g. a `morph`-style endpoint advertised only
  by config) could hide from me; the `morph` count in the binary is 87 but
  every non-WebKit hit was `isomorphic-fetch`/"Megamorphic" JIT symbols,
  i.e. none. Treat "no" as *strong evidence* about this build, not proof.

## 2. Family A — deterministic forgiving apply (the norm)

Every harness except dsh has one; the *ladders* differ in depth:

| Harness | Ladder (in order) | Ambiguity policy |
|---|---|---|
| **Codex** | exact → rstrip → trim → unicode-fold | refuse; `fuzz` not configurable upward |
| **opencode** | 9 replacers: `Simple`, `LineTrimmed`, `BlockAnchor`, `WhitespaceNormalized`, `IndentationFlexible`, `EscapeNormalized`, `TrimmedBoundary`, `ContextAware`, `MultiOccurrence` (`packages/opencode/src/tool/edit.ts:695-703`) | refuses if the matched span occurs twice; **plus** an `isDisproportionateMatch` guard that throws when the found span dwarfs `oldString` (≥ old+3 lines and ≥ 2×) |
| **CodeWhale** | unified diff + `fuzz` (default **3**, max **50**) scanning ±fuzz lines from the hunk's stated position; `matches_at_position` is `trim_end`-only (`crates/tui/src/tools/apply_patch.rs:25,30,1513,1591`) | if the hunk didn't match and carries ≥ 4 anchor lines, relocate to a **unique whole-file** match; refuse when the context matches at multiple locations (reports candidate lines) |
| **gemini-cli** | `exact` → `flexible` (per-line trim) → `regex` → `fuzzy` (Levenshtein, ≥10-char old_string, 4e8 complexity cap) (`packages/core/src/tools/edit.ts:320-345,1366-1400`) | flexible path refuses on multiple occurrences unless `allow_multiple` |
| **Qwen Code** | literal `indexOf` → Unicode-equivalent map → line-based with passes `[identity, trimEnd]` then normalized compare (`packages/core/src/utils/editHelper.ts:55-115,172-196`) | keeps leading indentation strict deliberately ("to avoid matching at incorrect scope levels") |
| **Pi** | exact → `normalizeForFuzzyMatch` (NFKC, per-line trimEnd, smart quotes, dashes, special spaces) re-search (`packages/coding-agent/src/core/tools/edit-diff.ts:30-52,203-240`) | refuses on >1 occurrence |
| **OpenHands** (`str_replace_editor`) | literal regex → **strip only `old_str`** and retry (`file_editor/editor.py:215-231`, from software-agent-sdk on GitHub; see basis note) | refuses on >1 occurrence, *and reports the matching line numbers* |
| **Kimi CLI** | none — plain `str.replace` (`src/kimi_cli/tools/file/replace.py:_apply_edit`) | refuses if nothing replaced; no ambiguity check at all |
| **aider** | a strategy×preproc ladder including `relative_indent` (rewrite indentation into relative form so blocks match across indent levels) and reversed-line search (`aider/coders/search_replace.py:565-615`) | depends on strategy |
| **DeepSeek-Reasonix** | exact → narrow fuzzy: `trimTrailing` → `expandTabs` → (only if the old string carries `read_file` line prefixes) strip-those-prefixes × same two (`internal/tool/builtin/encoding_helpers.go:224-268`) | fuzzy must yield exactly **one** range, else no change |

Notable design choices inside family A, because they're cheap and copyable:

- **Ambiguity errors that teach.** OpenHands lists the candidate line numbers;
  CodeWhale lists candidate lines *and* refuses to relocate autonomously
  ("applying to the wrong copy of a repeated block would corrupt the file").
- **Read-prefix tolerance.** Reasonix strips the `123| `-style prefixes its own
  `read_file` emits, but *only* when the old string actually looks prefixed —
  a targeted fix for a self-inflicted failure mode.
- **Disproportionality guards.** opencode's `isDisproportionateMatch`
  (matched span ≥ old+3 lines and ≥2×, or >500 chars more) and Niffler's
  `disproportionate` (`components/edit/main.nim:248-257`) are the same idea
  arrived at independently: refuse a "match" that has clearly swallowed a
  region the model didn't intend.

## 3. Family B — the patch-dialect envelope (Codex-style `apply_patch`)

The dialect itself is the interesting part: the model writes file operations,
not a replacement string, so a patch can add/update/delete/move many files in
one call and never re-emits untouched lines.

- **Adopted by** codex (origin), **opencode** (`apply_patch` is a shipped
  built-in `packages/core/src/tool/builtins.ts:35`, with its own parser
  `packages/core/src/patch.ts` and even a heredoc-unwrapping shim so a model
  that pipes a patch through `cat <<EOF` still works, `patch.ts:200`),
  **CodeWhale** (unified-diff flavour with fuzz, §2), **aider** (`patch` coder
  is an `apply_patch` port), and **DeepSeek-Reasonix** as a shipped tool name.
- **Trap:** emitting the dialect is a *format* choice, not a token-saving one,
  if the model still writes full replacement blocks inside the hunk. Codex's
  own grammar allows `+`/`-` lines only, which is what forces brevity.
- **The failure mode** is stale hunk line numbers: the model regenerates a
  patch from an old read. That is exactly why CodeWhale bolts relocation-with-
  uniqueness onto it (`#5003` comment, `apply_patch.rs:1555-1581`) and why
  codex's `seek_sequence` has an `eof` bias.

## 4. Family C — the dedicated apply model ("Fast Apply", literally)

This is what the phrase means in vendor material, and it has two flavours.

**C1. A hosted apply model: Morph.** `morph-v3-fast` / `morph-v3-large` /
`auto` (models-api fixture in opencode lists 16k/32k context, $0.8-0.9/M
input, no tool support — it is a *completion* endpoint, not an agent).
Contract: `<instruction>` + `<code>` (full original file) + `<update>` (the
lazy edit, with `// ... existing code ...` markers) → merged file. Advertised
~10,500 tok/s, 96-98%. In the shelf this appears as **plugins**, never core:
[`JRedeker/opencode-morph-fast-apply`](https://github.com/JRedeker/opencode-morph-fast-apply)
(`morph_edit`, lazy markers, pre-flight validation so a missing marker can't
delete a file, TUI title `Morph: src/file.ts +15/-3 (450ms)`) and the official
[`morphllm/opencode-morph-plugin`](https://github.com/morphllm/opencode-morph-plugin)
(Fast Apply + WarpGrep + compaction). Pi has no Morph in core either — its
ecosystem inventory lists a third-party extension
(`extensions/morph-tools/tools/fast-apply.ts` in `nof0xgiven/pi-coding-agent-eureka`,
found in `pi_agent_rust`'s extension survey, not in pi itself).

**C2. A self-hosted apply model.** **plandex** is the clearest in-repo case:
`build_structured_edits.go:54-105` races `hooks.CallFastApply` with the normal
structured-apply path, passing `{InitialCode, EditSnippet, Language}` and
taking back `MergedCode`. The hook exists precisely so the model provider is
swappable — hence `FastApplyModelConfig *shared.ModelRoleConfig`
(`hooks.go:80`). It is *not* a role in plandex's own enum
(`planner/coder/architect/summarizer/builder/whole-file-builder/names/
commit-messages/auto-continue`), so in practice the hook is supplied by an
integration rather than by a built-in pack. Note the race: fast apply is
started early when the file looks like a replace/overwrite, and *also* started
if structured apply failed and no fast apply was already running
(`build_structured_edits.go:101,129-130`) — so worst case it is a speculative
call on the critical path, not a fallback.

**Does family C need a local LLM? No — but it needs *a* model, and that is a
cost/latency decision, not a technical one.** Three viable shapes:

1. **Hosted** (Morph, or octofriend's Synthetic hosting for its autofix
   models) — no local GPU, but an API key, per-edit cost, a network round trip,
   and code leaving the machine.
   Morph's economics are the pitch: the apply model is small and fast, so one
   apply call costs less than the output tokens the main model would have
   spent re-copying context. That only holds for *large* files with *small*
   diffs; for a small edit the extra call is pure overhead (which is why the
   plugins tell the model to prefer native `edit` for small exact changes).
2. **Self-hosted** — the contract is small enough to serve yourself: the
   fast-apply plugin reads `MORPH_API_URL` (default
   `https://api.morphllm.com`, README config table), so a local
   OpenAI-compatible server implementing `<code>+<update> → merged file` is a
   config change, not a fork. A merge model is a far easier local workload
   than a coding model: it reads one file and emits one file, so a small
   quantized model on a single GPU is sufficient. Note this is a *different*
   task from family D's repair (below), which only needs to return a corrected
   search string and is cheaper again.
3. **No apply model, local or otherwise** — family A/B, which is what codex,
   Claude Code and Niffler do. Free, deterministic, no code egress.

**A naming trap worth flagging:** octofriend's autofix model is
`syntheticlab/diff-apply`, and its training directory is
`training/fast-apply/` — but it is **not** a family-C merger. It is called
*only after a validation failure* and returns a corrected `search` string
(`source/compilers/autofix.ts:autofixEdit`, invoked from
`source/agent/trajectory-arc.ts:339-345` under `validation.error`), leaving
`replace` untouched. So it belongs to family D, and the `fast-apply`
directory name is exactly the loose usage §0 complains about. Everything
about its config is real, though: `diffApply` and `fixJson` are separate
`AutofixModelConfig` entries (`source/config.ts:171-172`), defaulting to
`hf:syntheticlab/diff-apply` and `hf:syntheticlab/fix-json` on Synthetic's
OpenAI-compatible endpoint (`menu.tsx:158,176`), both open weights on Hugging
Face, with a "use a custom diff-apply model" path (any baseUrl, so local
serving is possible). `fixJson` is a third job again — repairing malformed
tool-call JSON (`parse-tool-call.ts:119-127`) — unrelated to edit application
but shipped from the same micro-model family.

## 5. Family D — repair hook (fast apply only after failure)

Flow: deterministic ladder fails → send `{file, broken edit}` to a small model
→ get the **corrected search string** back → re-validate → apply → the failure
never reaches the main model.

One correction worth stating precisely, because the doc's own §0 complains
about the term: "the main loop never learns it happened" is **not** literally
true in the implementations I read. octofriend re-validates the fix and, on
success, continues with the corrected call — but it *does* push a
`tool-skip-output` into the retry trajectory (`trajectory-arc.ts:386`), and the
system prompt explains that "one of your other tool calls was invalid, so no
tool calls were run" (`SKIP_INVALID_REASON`, `:34`). So the main model sees a
*skip notice*, not the raw validation error; it is spared the failure detail,
not the event. That distinction matters if Niffler copies this: the honest
promise is "no error round trip", not "invisible".

- **octofriend**: exactly this (`source/compilers/autofix.ts:autofixEdit`),
  with the failure path returning `null` → the original error surfaces. Its
  `diff-apply` model was trained on real git history by *corrupting* the
  search string (`training/fast-apply/generate-diff-training.ts:146-206`:
  delete or double any of 30 special chars, cut at a random index, insert
  space/tab, `/ +/ → \t`, `\t → "  "`, blank-line insertion), with ~10%
  labelled `{success: false}` so **refusal is trained too** — the same
  taxonomy `../OCTOFRIEND-STEAL.md` proposes for a Niffler repair tier. The
  committed recipe is deliberately small (Llama-3.1-8B + LoRA rank 32,
  1 epoch, `unfat/octofriend-fast-apply/train.py`), which is the useful
  datapoint for anyone considering this tier: the model is cheap, the
  *failure corpus* is the expensive part.
- **gemini-cli**: an LLM edit corrector for escaping damage —
  `correctStringEscaping` with a system prompt that says "Your job is to fix
  the provided parameters to make the edit succeed", plus a deterministic
  `unescapeStringForGeminiBug` for `\\n`-style double escaping
  (`packages/core/src/utils/editCorrector.ts:14-31,79-190`). Cache by content,
  50 entries.
- **plandex**: the same hook doubles as the racing fallback (§C2).
- **Niffler**: *does not have this*; the deterministic cascade is the whole
  ladder (`components/edit/main.nim:259-620`), and
  `../OCTOFRIEND-STEAL.md` §1 is the proposal to add it as a tier *after* the
  cascade with a measurable rescue rate.

## 6. The counter-position: dsh does none of this

DeepSeek's harness is the deliberate outlier and worth stating because it is
the only harness whose edit tool *fails closed*:

- `old_str` must match **exactly** — "Be mindful of whitespaces!" — with
  `FS_EDIT_NOT_FOUND` on 0 and `FS_AMBIGUOUS_EDIT` on >1; no fuzzy rescue
  (`packages/fs/fs-local/src/fsio.ts:797` per DEEPSEEK-HARNESS.md).
- `FS_NOT_OBSERVED` requires the file to have been read *this session*, even
  if unchanged (vs Niffler's `E_STALE`, which refuses only on actual byte
  change).
- The Anthropic-style `str_replace_editor` exists but is **opt-in**, and their
  e2e presets assert it is absent by default.
- Their compensating move is *informational*: ambiguity errors list the
  matching **line numbers** (`lineNumbersAt`), so the model can re-aim instead
  of the tool guessing.

So "fast-apply" is a real fork in the road, not a universal upgrade: dsh bets
that a model with good line-numbered reads doesn't need fuzzy matching, and
spends its engineering budget on validation instead.

## 7. Where Niffler sits, and the gap

`components/edit` (0.3.0) is family A with a deeper ladder than most: exact +
uniqueness, then trailing-whitespace → indentation → unicode-fold →
block-anchors-with-Levenshtein(≥0.65) → double-escape-unescape, each refusing
on multiple matches, with the disproportionality guard and a seen-state digest
(`E_STALE`). It also has features none of the above match: multi-edit per call
against one original, `undo_last_edit` persisted across restarts, verbatim
reads with an `[unchanged]` stub.

What's missing, in the order the evidence supports:

1. **Ambiguity errors with candidate line numbers** (OpenHands, CodeWhale).
   Cheap, strictly more actionable than a count, no semantics change. This is
   the "steal" already recorded in DEEPSEEK-HARNESS.md.
2. **A repair tier after the cascade** (family D, octofriend-style). The seam
   exists (match failure → hook → re-validate → apply); it needs a component-
   side config block and an observe counter for rescue rate, per
   OCTOFRIEND-STEAL.md's option A (~1 day hosted, weeks to train).
3. **A fast-apply provider as a plugin component** (family C), *not* core.
   This is the AGENTS.md-legal shape: a component implementing a generic seam
   (`edit` keeps exact+cascade; a `fastapply` peer takes
   `{path, instruction, lazy_edit}` → merged file, with pre-flight marker
   validation like the Morph plugin's, and falls back to `edit`). Config is
   then one endpoint entry — Morph, a local server, or nothing. It should be
   **opt-in and off by default**, because the token economics only favour it on
   large files with scattered small changes, which is precisely when the
   deterministic cascade is also most likely to drown.
4. **Not worth it:** reimplementing the patch dialect. Niffler's exact-match
   multi-edit already covers the multi-file case through repeated calls, and
   AIDER.md §"what not to steal" already judged the unified-diff format a poor
   fit for this component's shape.

**A note on "fast":** for family C the headline number is a *tokens/sec* figure
for the apply model, which is not the user-visible speedup. The real speedup is
that the main model stopped emitting unchanged lines — measurable as output
tokens per accepted edit, and the honest A/B is rounds-to-green and cost per
task, not tok/s. Family A/B's "fast" is different again: fewer retry rounds.
The three claims are not comparable and vendor material routinely conflates
them.
