# Working with worktrees — a tutorial

> Status: **Part 1 documents shipped behaviour (v0.5.0).** Part 2 documents what
> the 0.6.0 proposal in [research/WORKTREES.md](research/WORKTREES.md) will add, and is labelled
> as such throughout: nothing in Part 2 exists yet. Where an example in Part 2
> would fail today, it says so.

Two things get confused when people talk about worktrees in Niffler, so this
tutorial keeps them apart:

- the **primary workspace** — the one directory a conversation is pinned to, and
  the directory relative paths resolve against;
- the **workspace set** — the primary *plus* the trees that belong to the same
  project, which is what tools accept and what the write fence admits.

A git worktree is a second checkout of the same repository. Niffler has been
worktree-*aware* for a while: it discovers trees you make and admits them. What
it cannot do yet is *make* one for you, or move a conversation into one. Part 1
is therefore a manual workflow; Part 2 is the one that stops being manual.

---

# Part 1 — what works today

## 1.1 The five-minute version

```bash
# In your shell, in the repo you are working on:
git worktree add ../myrepo.wt/fix-flaky-test -b fix-flaky-test

# Start the client in the new tree:
cd ../myrepo.wt/fix-flaky-test
niffler-tui
```

That is the whole setup. The new conversation's primary workspace *is* the
worktree, so `read`, `edit`, `bash`, `grep`, the sandbox and the undo ledger all
operate there. Your checkout of `main` is untouched and needs no `.gitignore`
edit — verified: `git worktree add ../myrepo.wt/x` leaves the primary's
`git status` clean.

You do **not** need to grant anything. Say that twice, because the obvious
question is the wrong one: `/roots add` grants extra roots *on top of* the primary
workspace. A conversation born in the worktree already has the worktree as its
primary, and its set also contains the primary checkout automatically (see §1.3).

## 1.2 Where the conversation thinks it is

Type `/workspace` to see it. The report answers the question a bare path cannot —
a worktree and a normal checkout look identical as directories:

```
/workspace
workspace: ../myrepo.wt/fix-flaky-test
not chosen — this is the harness-root default — /workspace <path> pins it while nothing has been chosen
git branch: fix-flaky-test — this is a LINKED worktree, not the primary checkout
primary checkout: ../myrepo
granted roots: 0 (/roots lists them)
```

(The strings above are the client's own, so what you see will match them.) The
`⧉`-style worktree line and the `primary checkout:` line come from git, not from
a Niffler setting: the client asks `git rev-parse` / `git worktree list` at
birth. `/roots` alone has no opinion about git shape — it reports the primary
plus grants:

```
/roots
primary workspace: ../myrepo.wt/fix-flaky-test
no granted roots — /roots add <dir> grants one (a grant widens what tools accept and what the write fence admits)
```

Two commands, two questions: `/workspace` is *where and in what shape*,
`/roots` is *what extra scope has a human granted*.

## 1.3 What a conversation can actually touch

The set is computed by `core/workspace.nim` and, in order:

1. **the primary workspace** — always first, always the base for relative paths;
2. **every linked git worktree of that repo**, in git's order
   (`git worktree list --porcelain`);
3. **same-origin sibling checkouts** — other directories next to the primary
   whose `origin` matches (`~/git/myrepo` and `~/git/myrepo-deployed`);
4. **human grants** from `/roots add`.

The list is deduped, capped at 8 entries, and *stable*: the same set every
dispatch, so nothing silently widens under you.

So a conversation started in a worktree can:

- read and write **its own tree** (the primary);
- read **your checkout of `main`** and any other worktree of the repo — this is
  how you diff branches, and it is deliberate: refusing it would make the tree a
  cage;
- write the `main` checkout **too**, because the set is about reach, not about
  isolation. There is no per-conversation fence in v0.5.0 (§2.1 adds one).

### One exception, and it happens to point the right way

If the opt-in bash guard is on (`NIF_BASH_SANDBOX=on`), a guarded command gets a
*narrower* view than the tool set: the launcher binds the whole host read-only
(`--ro-bind / /`) and makes exactly one tree writable — the conversation's
primary workspace. So in a worktree conversation, guarded `bash` **can write the
worktree and not the primary checkout**, even though `edit`/`write` in the same
conversation still can. Reads of the primary stay possible.

That is the shipped behaviour, and it is worth knowing because it is exactly the
asymmetry 0.6.0 makes deliberate: the sandbox is per-workspace, and the sandbox
work in pillar 3 is what teaches it about the rest of the set (reviewed
runtime/data roots) instead of "everything read-only plus one writable tree".
Note also what the guard does *not* do: it does not pass `/roots` grants to the
launcher, so a granted extra root is writable by the tools and read-only to a
guarded command.

If you want the path-level facts from the model's side, it can call
`session_info`: the `session` status readback carries `cwd`, `cwdPinned` and
`grantedRoots`. What it does **not** carry today is the git shape — branch, or
"this is a linked worktree" — which is §2.2. Components see the roots through
the private `__workspace` context (`{root, roots}`), which is never the prompt
and never a schema, so none of this changes the request prefix.

## 1.4 The catch: a tree made *during* a conversation is invisible

This is the single most surprising behaviour in v0.5.0, and it is a real defect
(fixed in §2.2 — until then it is a workflow rule).

The set is cached for the runner's lifetime. Its cache key is the primary plus
the grants, and the **only** thing that invalidates it is a *grant change*. So:

```
conversation starts in ~/git/myrepo
agent runs: bash "git worktree add ../myrepo.wt/exp -b exp"     ← works
agent runs: edit "../myrepo.wt/exp/src/x.nim"
        → [E_WRITE_OUTSIDE] …/myrepo.wt/exp/src/x.nim is outside this
          conversation's workspace
```

Nothing is wrong with the worktree: `computeWorkspaceRoots` would see it. The
cache hides it. Two ways out today:

- **Grant it** — `/roots add ../myrepo.wt/exp`. The grant changes the cache key,
  so the next dispatch rebuilds the set and the write is admitted. The grant
  persists (store kind `grantedroot`, one document per conversation) and is
  capped at 7 alongside the primary.
- **Start the conversation in the tree** (§1.1), which is the saner route.

A grant takes effect **between tool calls**, never during one: a `bash` that is
already running keeps the reach it started with.

## 1.5 The exploratory-then-implement workflow (today)

You have been discussing an approach for twenty minutes and now want to make
changes without touching your checkout of `main`.

1. `/compact` if the conversation is long. The new conversation will not inherit
   history, so anything you want carried over has to be written down or carried
   by you.
2. Note what matters — the decision, the files, the plan. A short message like
   *"writing this down for the worktree conversation: fix the race in
   `queue.nim`, do not touch the retry logic"* is enough; you will paste it.
3. `git worktree add ../myrepo.wt/fix-race -b fix-race` in a terminal (or let
   the agent run it with `bash` — but see §1.4: from *this* conversation the new
   tree is then outside the set, so you would have to grant it, and the grant is
   the client's call: `/roots add ../myrepo.wt/fix-race`).
4. Start `niffler-tui` in `../myrepo.wt/fix-race` and paste the note back.
5. Work. `/workspace` and `/roots` answer "where am I" and "what can I touch".

The cost is honest and worth naming: **a second conversation that did not read
the first one.** The model gets the summary you wrote, not the transcript. That
gap is exactly what §2.1 removes.

## 1.6 Merge back and clean up (today)

From the worktree conversation, the merge is ordinary git through `bash` — there
is no merge verb yet:

```bash
# in the worktree
git add -A && git commit -m "fix the queue race"     # or use the edit/undo tools
git log --oneline main..HEAD                          # what am I merging
git diff --stat main...HEAD                           # how big is it
```

then, in the **primary** checkout (from this conversation that is
`~/git/myrepo`, which the workspace set lets you read and write):

```bash
git merge --no-ff fix-race
git status                                            # conflicts, if any
git worktree remove ../myrepo.wt/fix-race             # refuses if dirty or unmerged
git branch -d fix-race                                # only when merged
```

Things that will bite, all of them git's own rules rather than Niffler's:

- `git worktree remove` refuses a dirty tree (`contains modified or untracked
  files`) — commit or discard first;
- `git branch -d` refuses an unmerged branch; `-D` is the override;
- the merge itself is a write into the primary checkout, and from a worktree
  conversation that write is **unclaimed** by the lock component today: the
  opaque claim is the conversation's own root, so a concurrent `edit` in another
  conversation over the same primary is not excluded. §2.4 fixes this.

Once the tree is gone, the worktree conversation is pointing at a directory that
no longer exists. It does not crash: `read`/`edit` refuse with a clear error, and
the transcript stays as the review record. Continuing that work means a new
conversation in the primary.

## 1.7 What `/roots` is for, and when not to use it

`/roots add <absolute path>` exists for the legitimate case where the work really
does span two directories: a sibling checkout, a generated-output tree, a second
repository you own. It is **human-only** — the model cannot call it, it is not in
`session`'s schema, and it is a control call.

Rules worth knowing before you grant:

| Rule | Why |
|---|---|
| Core takes absolute paths only; `/` is refused; the directory must exist | a relative grant would depend on where the harness runs. The **client** is friendlier: it expands `~` and resolves a relative path against the workspace before sending |
| Cannot grant the primary itself | it is already the first entry |
| The grant list is capped at 7 (grants beyond that are silently dropped: `roots[0 ..< min(len, maxWorkspaceRoots-1)]`) | past that the extra roots stop being "the same project" — and this shares one constant with the *discovery* cap, which is WORKTREES.md §9 Q3 |
| Persistence first, then effect | a store failure refuses the grant rather than activating a policy that would not survive a restart |
| Applies between tool calls | a running `bash` is not retroactively widened |
| Revocation is immediate for the next call | `/roots remove <path>`; the set rebuilds on the next dispatch |

A grant is not a sandbox boundary: it widens what the fence admits. The sandbox
work in 0.6.0 is what turns "the set" into a boundary (PLAN.md pillar 3).

## 1.8 Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `[E_WRITE_OUTSIDE] … is outside this conversation's workspace` right after you created a worktree | the set is cached; a new tree is invisible until a grant or a restart (§1.4) | `/roots add ../myrepo.wt/exp` (the client expands `~` and workspace-relative paths; core requires the absolute result) |
| `conversation cwd is immutable once turns exist` | `/workspace <path>` after a chosen workspace | start a conversation *in* the target directory, or grant it as an extra root |
| A worktree's files show up twice in search or the repo map | both trees are in the set, so both are searched | expected; `isolation` (§2.1) and the census hint in §2.2 reduce it |
| `git worktree remove` refuses | dirty tree, or the branch is unmerged | commit/discard, then merge or use `-D` |
| A guarded `bash` cannot write the primary checkout from a worktree conversation, though `edit` can | the guard makes only the primary workspace writable (§1.3) | intended for now; the guard is narrower than the tool set. Commit from the worktree and merge in a primary conversation, or turn the guard off for that call |
| The agent insists it is "in the repo" when you started it in a worktree | the frozen prompt carries the path, not the git shape, and `session_info` copies `cwd` only | tell it; §2.2 puts the shape in `session_info.workspace` and in its private `__workspace` context |

---

# Part 2 — how it will work (0.6.0)

> Nothing in this part is implemented. It is the deliverable list from
> [research/WORKTREES.md](research/WORKTREES.md) §4–§5 and [PLAN.md](PLAN.md) pillar 2. Every
> example below is marked with what to do *instead* until it ships.

## 2.1 The exploratory-then-implement workflow (after)

You have been discussing an approach and now want to make changes. You stay in
the same window:

```
/worktree add fix-race
```

That one command creates `../myrepo.wt/fix-race` and then does one of two things,
depending on your conversation — and tells you which:

- **moves** this conversation into the tree when that is safe (no turn has
  chosen a workspace, or the conversation is still pristine, and the old tree is
  clean). Same transcript, same context, new working directory. It costs no
  prompt-cache rebuild: the frozen prompt embeds the harness root and never the
  workspace path.
- **forks** into a new conversation seeded with this one's transcript when a move
  is not safe (you pinned a workspace already, or the old tree has uncommitted
  changes that a move would strand). The new conversation is born *in* the
  worktree and has *read* the exploration rather than being told about it.

Either way you are not asked about workspace immutability, and nothing is
silently abandoned: a fork leaves the parent untouched, a move keeps the
motivation in the same transcript.

**What the fork carries, exactly** — because "all context copied" would be an
overstatement, and this is the shipped `forkHistory` behaviour rather than a new
promise:

| | |
|---|---|
| **Copied, verbatim** | every completed turn as real messages: `role`, `content`, `tool_calls`, `tool_call_id`, `name`, `createdAt`. Tool calls travel with their results, so the child's first request is a valid provider history. The cut is always on a turn boundary and never includes the turn in flight |
| **Dropped on purpose** | per-message token `usage` (the child's accounting is its own), `summary` records (a derivation of records also copied), `error` records (the parent's turn audit) |
| **The child's own, not inherited** | system prompt (re-resolved at birth, so a persona or `AGENTS.md` change is picked up), frozen toolset, model/provider pin, approval mode, budgets, granted roots, `isolation` |
| **Known gap** | a `/compact` checkpoint is not copied, so a parent that compacted hands the child the raw pre-compaction records and the child may summarize differently. 0.6.0 should either copy the checkpoint forward or say so in the command's output |

So: a new conversation id, with your conversation's messages in it, its own
configuration — you continue where you left off with the full argument still in
front of the model, not a summary of it.

`isolation: "worktree"` becomes available at birth too: the primary checkout
stays **readable** (diff, search, compare) but is no longer writable from this
conversation. That is the flag that makes "my checkout of `main` cannot be
touched" true, and it is a fence around the conversation, not a mutex around the
tree: two conversations in one tree still proceed on different files
(`locks`' "disjoint stays parallel" rule is unchanged — WORKTREES.md §10).

*Until it ships:* §1.5, which costs you a second conversation and a written note.

## 2.2 What changes underneath

Three changes make the commands above honest:

- **The set goes live.** `workspaceRootsFor` recomputes when the git graph
  changes — a `stat` on `<commonDir>/worktrees`, not a `git` call — so a tree
  created mid-conversation is admitted on the **next dispatch** with no grant and
  no restart. §1.4 disappears as a workflow rule.
- **The conversation learns its own shape.** `__workspace` gains
  `primary`/`worktree` and `session_info` gains a `workspace` block, so the model
  is told "you are in a linked worktree of `~/git/myrepo` on branch `fix-race`"
  instead of inferring it from paths or hitting a refusal.
- **One answer about git shape.** `sdk/checkout.nim` replaces three hand-rolled
  parses (`core/workspace.nim`, `systemprompt`, `lsp/roots.nim`), so "is this a
  worktree, and of what?" has one answer in the codebase.

*Until it ships:* `/roots add` after creating a tree, and `session_info` for the
path-level facts only.

## 2.3 The working loop (after)

Creating and entering a tree becomes a verb instead of a shell out plus a grant:

```
git_worktree {op: "add", branch: "fix-race"}      ← approval-gated; you see the
                                                    layout, path and lock first
edit "../myrepo.wt/fix-race/src/queue.nim"        ← just works: the set is live
```

Inside the tree nothing else changes: `read`, `edit`, `replace_across`, `bash`,
undo, the sandbox policy and the readscope masks all address *this* checkout, and
`git_worktree_list` answers "whose tree is this, is it dirty, is it
locked" from git plus the store ledger — the fact git cannot know, because the
ledger records which conversation a tree belongs to.

The human's side is one command with one sentence of feedback:

```
/worktree
repo:  ../myrepo (main, clean)
trees: ../myrepo.wt/fix-race (branch fix-race, mine, dirty: 2 files, ahead 1)
this conversation: ../myrepo.wt/fix-race
origin: conv-abc123 (84 msgs)
```

*Until it ships:* `git worktree add` in a terminal plus `/roots add`.

## 2.4 Merge back and clean up (after)

```
/worktree merge
```

becomes the whole ritual, in four visible steps:

1. **preview** — `git_merge_preview`, a read (`git merge-tree`), so no
   approval: `{clean: true, ahead: 3, behind: 1, files: 12}`, or the conflict
   list *before* anything is touched.
2. **commit** — the conversation already knows what changed and why; the verb
   takes the message instead of guessing it in a later round.
3. **merge** — a claimed write into the primary, so two merges into one primary
   serialize, and a worktree conversation merging home holds a lease over the
   tree it writes into. §1.6's unclaimed write is gone.
4. **remove** — refuses on evidence (another live conversation pinned to the
   tree, or an unmerged branch) and names the flag that overrides it.

The merge receipt (commit, files, into, from) lands in the conversation's
history, so "what came out of this exploration?" has an answer months later.

And then you go back:

```
/worktree close
→ merged into main as 9cba035 (4 files); back in conv-abc123 — the
  conversation that started this
```

`/worktree close` is the closing key: it refuses while the branch is unmerged or
the tree is dirty, removes the tree, and **switches the client back to the
conversation that forked you there**. Which raises the fair question: *can't I
just `/session` back to the parent myself?* Yes, and that is all `close` is doing
underneath — but the parent then has no idea any of this happened, so its
transcript reads as if you stopped mid-thought.

That is the part 0.6.0 fixes, using machinery that already exists:

- the fork is recorded (`origin`), so the parent's `session_info` lists it as a
  descendant — "what came of this?" is one call from where the work started;
- the merge **settles into the parent's notice lane**. `drainNotices` already
  folds `agent_notices` / `process_notices` / `fleet_notices` into history at the
  top of every turn, marked as runtime machinery rather than something you said.
  A merged worktree joins that lane, so returning to the parent shows *"the
  worktree `fix-race` was merged into `main` as `9cba035` (4 files)"* — the
  commit id being exactly what the next step (push, PR) needs.

So the whole loop, end to end: explore in the parent → `/worktree add fix-race`
(moves or forks, says which) → work in the tree → `/worktree merge` (preview,
commit, merge, remove) → `/worktree close` returns you to the parent, which now
knows the commit. Push and open the PR from there, with the argument and the
decision still in context.

*Until it ships:* the shell sequence in §1.6, remembering that its merge is
unarbitrated; then `/session` back to the parent and paste the commit id.

## 2.5 How linked conversations will relate

Today a conversation's only parent edge is `sessionmeta.parent`, which means
*subagent*: depth-capped, approvals routed up, idle retirement. That is the wrong
relationship for "the same piece of work, now in its own tree", because you keep
talking to that conversation as your main thread.

0.6.0 names the distinction rather than adding a second relation. A fork already
writes both `sessionmeta.parent` and `sessionmeta.fork = {source, uptoId,
copied}` today, which is a problem in itself: every worktree fork would inherit
**subagent** supervision — depth rules, approvals routed to the original caller,
idle retirement — which is wrong for your main thread. The proposal is therefore
to separate them:

| Edge | Meaning | Authority |
|---|---|---|
| `parent` | supervision — spawned to do a job for another conversation | depth rules, approvals route up, idle retirement (unchanged) |
| `origin` | provenance — this transcript was seeded from another, and it is your main thread | **none**; it may spawn its own children, and its approvals stay with its own client |

So yes: the fork is a `peer`, which is the thing that makes it usable as your
main thread rather than a supervised helper.

So a fork's `session_info` will say *"seeded from `conv-abc123` at message 84;
working tree `../myrepo.wt/fix-race` (branch `fix-race`, primary `../myrepo`)"*,
and the originating conversation will list its descendants. That is what makes
the exploration → worktree → merge trail readable instead of three unrelated
transcripts.

Deliberately **not** planned: a shared mutable context between linked
conversations, or one conversation holding several workspaces. Both would put a
changing list into the request prefix, which is the one thing the frozen-prompt
discipline forbids.

*Until it ships:* you are the link. Keep the conversation id in your note.

## 2.6 Cheat sheet

| Want | Today (§1) | 0.6.0 (§2) |
|---|---|---|
| Start working in a tree | `git worktree add ../repo.wt/x -b x`, then start the client there | `/worktree add x` (alias `new`) |
| Keep exploring, then switch | write a note, new conversation, paste it | `/worktree add x` moves or forks, and says which |
| A tree created mid-conversation is writable | `/roots add ../myrepo.wt/exp` (the client expands `~` and workspace-relative paths; core requires the absolute result) | automatic on the next dispatch |
| See where I am / what I can touch | `/workspace`, `/roots` | same, plus the tree list and origin |
| Stop writes to `main` | not possible | `isolation: "worktree"` |
| Merge back | shell: `git merge --no-ff` in the primary | `/worktree merge` (preview → commit → merge → remove) |
| Clean up | shell: `git worktree remove`, `git branch -d` | `/worktree rm x`, guarded |
| Relate two conversations | manually | `origin` origin edge, reported by `session_info` |
| Come back to the parent afterwards | `/session` back to it, then paste the commit id | `/worktree close` switches back, and the merge notice is waiting there |

## 2.7 Where the pieces live

- [research/WORKTREES.md](research/WORKTREES.md) — the proposal: problem
  statement, the nine slices and their tests, the invariant checklist,
  non-goals, and §5 the same three moments written for the implementer.
- [PLAN.md](PLAN.md) pillar 2 — what 0.6.0 requires of it and why.
- [MANUAL.md](MANUAL.md) — the operating reference for what ships (this
  tutorial's Part 1 duplicates the *workflow*, not the reference).
- [research/SANDBOX-BASH-STATUS.md](research/SANDBOX-BASH-STATUS.md) — what the
  bash guard does today, including the single-writable-root rule from §1.3.
- [WIRE.md](WIRE.md) — the exact contract for `git_worktree_list`,
  `git_worktree`, `git_merge_preview`, `git_merge`, `git_commit`,
  `__workspace`, `sessionmeta.fork` and `isolation`, once implemented.
