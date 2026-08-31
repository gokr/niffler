---
name: todo-markdown
description: How to track multi-step work in this project - maintain a TODO.md file in the repository root (or a docs/ subdirectory for larger projects) instead of using any todo tool. Use when starting a task with several steps, when the user asks for a plan or a todo list, or when resuming unfinished work.
---

# Todo Lists as Markdown in the Repository

## Overview

Track multi-step work directly in a markdown file inside the repository — never in
tool state, never in conversation memory. The file is the single source of truth:
it persists across sessions, survives restarts, is visible to the user in any
editor, shows up in diffs and commits, and needs no special tooling.

**Announce at start:** "I'm using the todo-markdown skill to track this in TODO.md."

## When to use

Reach for a todo file when a task has **3 or more distinct steps**, involves
multiple files, or will span more than one exchange. Skip it for one-shot edits
and quick questions — a todo list for trivial work is overhead, not organization.

## File conventions

- **Default location**: `TODO.md` in the repository root.
- **Larger projects**: split by topic under `docs/` (e.g. `docs/todo-roadmap.md`,
  `docs/todo-migration.md`) when the root file would grow past ~100 lines.
- If a `TODO.md` already exists, **extend it** — read it first, don't overwrite.
- Keep it in the repo (committed) when the tasks matter to others; leave it
  untracked only for throwaway session-scratch lists.

## Format

```markdown
# TODO

## In progress
- [ ] Wire the condense tool into core dispatch  ← current

## Blocked
- [ ] Discord channel rewrite (waiting on bot token from @user)

## Up next
- [ ] Add todo-markdown skill to skills component
- [ ] Update MANUAL.md for the new store kinds

## Done
- [x] Survey niffler-old for portable ideas
```

Rules:

- Exactly **one item** may be marked as current (`← current` suffix) — the model
  should finish or explicitly abandon it before starting another.
- Check off items (`[x]`) the moment they are completed, in the same turn.
- Move completed items to **Done** instead of deleting them; prune Done only when
  the section grows past ~20 items.
- New discoveries made during the work get added immediately — the list reflects
  reality, not the original plan.

## Workflow

1. **Read before write**: if any `TODO.md` / `docs/todo-*.md` exists, read it and
   merge your plan into it.
2. **Create or update the file** with the `edit` tool using the format above,
   before starting the first step of work.
3. **Update as you go**: mark the current item, check off completions, add newly
   discovered tasks — after each meaningful step, not in one batch at the end.
4. **Close out**: when the work is finished, check off everything, clear the
   `← current` marker, and mention the final tally (e.g. "5/5 done, see TODO.md").

## Anti-patterns

- Do not maintain todo state in conversation memory or tool results — the file is
  authoritative; if the two disagree, the file wins.
- Do not create a second list file for the same effort (fork the existing one by
  section, not by file).
- Do not restate the whole list in prose every turn; a one-line pointer
  ("TODO.md updated: 2/5 done") is enough.
- Do not commit the todo file as part of feature commits unless the user asks;
  it usually rides along or gets committed separately.
