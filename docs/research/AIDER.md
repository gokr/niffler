# Aider — what to steal from a dormant classic

> Analysis of [Aider](https://github.com/Aider-AI/aider)
> (`~/git/harnesses/aider`, `5dc9490`, Python — last upstream push 2026-05-22;
> **effectively dormant**, which makes it a harvest target rather than a moving
> reference). Aider is the oldest idea-dense harness in the set: repo maps,
> edit formats as a measurable dimension, git-first discipline, and a
> self-repair loop that predates most of the field. Companion docs:
> [../PI-VS-NIFFLER.md](../PI-VS-NIFFLER.md),
> [../PI-NEXT.md](../PI-NEXT.md), [REMOTE.md](REMOTE.md).

## The one-paragraph shape

Aider is a pair-programming CLI built around **edit formats as first-class,
swappable strategy objects** (~17 coder classes: `wholefile`, `editblock`,
`udiff`, `patch` (an `apply_patch` port), `architect`, `context`, …), a
**reflection loop** that turns every failure into a typed retry, **git as the
safety net** (auto-commit per change, `/undo`), a **repo map** for attention
allocation, and a **weak/editor model split** for cheap auxiliary calls. No
process isolation, no bus, no discovery — none of that is the point. The point
is that it made harness *decisions* measurable.

## Steal list, ranked

### 1. The repo map — attention allocation for big repos (the big one)

`aider/repomap.py`: tree-sitter tags per file (disk-cached by mtime,
`.aider.tags.cache.v*`) → a symbol reference graph (`nx.MultiDiGraph`, file→file
weighted by identifier references) → **personalized PageRank** seeded from the
files in chat → render the highest-ranked files' key definitions within a token
budget (default 1024, adaptively multiplied when no files are in chat,
`map_mul_no_files`; the `context` coder forces `refresh: "always"` and a bigger
map). The rendered form is the distinctive bit: not file lists, not embeddings —
the *critical lines* of each ranked symbol (`class Coder:` / `def create(…)`
signatures), so the model sees shape, not just names.

Why Niffler should care: Niffler's context tools are `grep` (needle search) and
`read` (page files) — fine once you know where to look, but the *orientation*
problem ("what does this repo even contain, what's load-bearing?") costs the
model turns in anything larger than a toy. This is the same class of fix as the
frozen-prefix doctrine: spend a small, bounded token budget to make every later
decision cheaper. Bench evidence exists — Aider's polyglot benchmark measured
map on/off (Niffler's `bench/` can replay the same A/B).

Niffler shape: an **on-demand `repomap` component** (`x-harness.onDemand`) —
tree-sitter for a handful of languages (the lsp component already models
"language support is data"; a Nim tree-sitter binding or ctags fallback keeps
the language-agnostic core invariant), PageRank (no networkx needed for a first
cut — the graph is small; a simple weighted-degree or eigenvector pass will do),
and the renderer respecting a token budget. Cache tags in `var/`. Call it
explicitly, or teach the systemprompt when to reach for it. Two hard rules from
the doctrine: the map is a **tool result** (append-only, cache-safe — never a
system-prompt injection, which would either freeze stale shape into the header
or bust the prefix), and it must be **deterministic** for a given repo state
(Aider's ranking is deterministic given the graph; keep tie-breaks stable) so
the same call stays byte-identical across turns.

### 2. The reflection loop — every failure becomes a typed retry, with a cap

`base_coder.py:925`: `while message:` — after each turn, if
`self.reflected_message` is set, feed it back; hard cap `max_reflections = 3`
with a visible warning when exhausted. What sets it:

- **edit-format parse failures** (`base_coder.py:2315`) — the error text
  becomes the retry prompt (Aider's formats carry specific fix hints: "did you
  forget the filename?", "search is not unique"),
- **lint errors after edit** (`:1606`) — `auto_lint` runs the linter on every
  edited file, and (with a confirm) feeds the errors back,
- **test failures** (`:1622`) — `auto_test` + `test_cmd` likewise,
- **file-set mismatch** (`context_coder.py:45`) — the selector phase re-asks
  until the mentioned file set stabilizes.

Niffler already returns tool errors to the model, and the edit component has a
stronger *deterministic* fallback cascade than anything here — but Aider's
insight is that **verification failures should be automatically fed back as a
structured retry, with a budget**. Niffler shape: this is a runner/session
policy, not a component — "after a mutating tool succeeds, run the configured
verify command; on failure, inject the output as the next round's steering with
`maxRounds`-style budget accounting already in place." The budget half is free
(`maxRounds`/`maxCalls` exist); the policy half is a systemprompt/skill plus
optionally a `verify` hook on the edit component. Keep the *cap and the visible
exhaustion warning* — that is what stops the loop from silently burning tokens.

### 3. Weak/editor model split — cheap models for auxiliary calls

`models.py` gives every model a `weak_model_name` and `editor_model_name`;
commit messages, history summaries and title generation go to the **weak**
model (`repo.py:361` via `simple_send_with_retries`), while `architect` mode
splits *reasoning* (main model proposes) from *editing* (editor model applies a
simpler edit format).

Niffler already has the seams: `agent_run {model}`, `thinking`, and the expert
judge. What it lacks is the *convention* that auxiliary calls default cheap:

- **commit messages** → weak model (Niffler has no auto-commit story at all,
  see 4),
- **the COMPACTION.md summarization call** → explicitly a cheap/fast model;
  the compaction proposal already warns summaries cost tokens/latency
  ([COMPACTION.md](COMPACTION.md) §4.3) — a `summarizeWith: weak-model` default
  makes that cost deliberate,
- **architect/editor at the edit level**: `reasoner proposes → editor applies`
  is exactly Niffler's `agent`-drives-`edit` split, minus the ceremony — worth
  noting in the fabric/agent docs as a named pattern rather than building
  anything.

### 4. Git-first discipline — auto-commit per change, `/undo` as the safety net

`git.md`: every AI edit is committed with a generated message; `/undo` is
`git revert` of the last AI commit; attribution flags (`--attribute-co
-authored-by`, commit-message prefixes) keep the audit trail honest.

For a single interactive session this is convenience. For the **fleet/remote
work in [REMOTE.md](REMOTE.md)** it is closer to a requirement: a long-running
agent on a VM that *commits as it goes* gets crash-recoverability, reviewable
history, and a clean story for "what did the agent do while I was away" for
free — git is already the audit trail; the harness just has to use it.

Niffler shape: the `git` component is deliberately read-only with mutations in
bash, and that should stay. The steal is a **convention with teeth**: a bundled
skill (or systemprompt discipline) "commit after each verified change with a
generated message", plus the weak-model commit-message call from (3). If fleet
work makes it load-bearing, promote to an edit-component post-commit hook
(`x-harness` on the write path) — but convention-first; dsh's lesson about not
shipping vocabulary without a producer applies.

### 5. Cost surfaced per message (cheap, and PI-NEXT-adjacent)

`base_coder.py:2046` accumulates `total_cost` and reports it per message and
session-wide; Aider's model settings carry pricing so this works across
providers. Niffler's bench computes cost, the harness does not — the same
"[verified] no write axis" shape as the cache finding in
[../PI-NEXT.md](../PI-NEXT.md) §3.2. The `models` component already carries
prices; the conversation header already accumulates token meters. Steal: a
`cost` meter next to `cacheRead`, rendered where the cache chips are. Small.

### 6. ChatSummary — the minimal viable compaction strategy

`history.py`: recursive halving — keep the newest tail under half the budget,
summarize the head (via the weak model), force the split boundary to an
assistant message, recurse to depth 3. ~60 lines, no lockfile, no checkpoint
machinery.

Worth having as a named option inside the compaction work, not as the design:
[COMPACTION.md](COMPACTION.md) deliberately wants replaceable strategies with
validation/persistence in the runner and recall links — ChatSummary is the
right *floor* strategy when recall links are not yet built, and its
"split at an assistant message" rule is the same whole-turn discipline Niffler's
trim already follows.

### 7. Watch mode — the file as a channel (recorded, not endorsed)

`watch.py`: the agent watches files for `// AI!` / `// AI?` comment
conventions and turns them into prompts — the IDE becomes the chat surface.
Cute and genuinely useful for an editor-centric human. For Niffler this would
be a `watch` component subscribing to nothing but fs events — but Niffler's
steer + web UI already cover the need; recorded so the idea is not re-derived.

## Parity — already covered, do not steal

| Aider | Niffler |
|---|---|
| polyglot benchmark as the measuring culture | `bench/` (full30, DeepSWE, SWE-bench Verified importer) — strictly stronger: it races harnesses, not just edit formats |
| edit-format fallback cascade with fix hints | `edit` component's deterministic cascade + `[E_*]` codes |
| per-model settings table (quirks, caps) | `models` component (models.dev + plugins + overrides) |
| `--message` one-shot scripting, `--message-file` | `cli` component (plus it is bus-addressable, not just CLI) |
| `/undo` | `undo_last_edit` (single-level; git discipline in (4) is the general answer) |
| unified-diff edit format | `patch` coder is the `apply_patch` port; Niffler chose exact-match + cascade — the ladder idea (§2) is the transferable half, not the format |

## What to explicitly *not* steal

- **In-process everything** — the reason Aider cannot do any of
  [REMOTE.md](REMOTE.md)'s layer C; also its extension story is config flags,
  not composition.
- **The single-repo assumption** — Aider is one git repo, one cwd. Niffler's
  workspace doctrine is already broader.
- **Confirm-ask as the default safety posture** (`Attempt to fix lint errors?`)
  — right for interactive pairing, wrong for long-running autonomy; Niffler's
  approval-gate + budget model is the better default for unattended work.

## Order

1. `repomap` component (§1) — highest value, fits the on-demand/tool-result
   doctrine, measurable in `bench/`.
2. Reflection policy with budget (§2) + weak-model commit/summarize defaults
   (§3) — mostly conventions and wiring; pairs naturally with the compaction
   work (the summarizer wants a weak model anyway).
3. Cost meter (§5) — trivial, closes a PI-NEXT gap.
4. Git discipline (§4) — convention now, load-bearing when fleet work lands.
5. ChatSummary as a compaction strategy option (§6); watch mode (§7) only if a
   user asks.
