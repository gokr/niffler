# Working with worktrees — a tutorial

> Status: **both parts document shipped behaviour.** Part 1 is the manual route
> (shell `git worktree`, `/roots`) — it still works and is the fallback. Part 2
> is the integrated route (`/worktree`, `git_worktree*`, `git_merge*`, `isolation`,
> `origin`), which shipped in slices 0–7 of
> [research/WORKTREES.md](research/WORKTREES.md). Where a step is still manual,
> Part 2 says so instead of implying otherwise.

Two things get confused when people talk about worktrees in Niffler, so this
tutorial keeps them apart:

- the **primary workspace** — the one directory a conversation is pinned to, and
  the directory relative paths resolve against;
- the **workspace set** — the primary *plus* the trees that belong to the same
  project, which is what tools accept and what the write fence admits.

A git worktree is a second checkout of the same repository. Niffler **makes**,
**enters**, **fences**, **merges** and **retires** them now, so Part 2 is usually
the one you want. Part 1 remains accurate for anyone who prefers the shell, works
on an older harness, or wants to see what the verbs do underneath — the integrated
route is a thin layer over exactly those commands.

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
operate there. Your checkout of `main` is untouched, and nothing is added to
`.gitignore` — a sibling tree is not in the repository at all (verified:
`git worktree add ../myrepo.wt/x` leaves the primary's `git status` clean with no
ignore rule anywhere).

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
  isolation — unless the conversation is `isolation: "worktree"`, which narrows
  the *write* fence to its own tree plus explicit `/roots` grants while leaving
  the primary readable (§2.1).

### One exception, and it happens to point the right way

If the opt-in bash guard is on (`NIF_BASH_SANDBOX=on`), a guarded command gets a
*narrower* view than the tool set: the launcher binds the whole host read-only
(`--ro-bind / /`) and makes exactly one tree writable — the conversation's
primary workspace. So in a worktree conversation, guarded `bash` **can write the
worktree and not the primary checkout**, even though `edit`/`write` in the same
conversation still can. Reads of the primary stay possible.

That is shipped behaviour, and the asymmetry is deliberate: the sandbox is
per-workspace, and teaching it about the rest of the set (reviewed runtime/data
roots) is separate 0.6.0 work (PLAN.md pillar 3) rather than part of this one.

`isolation: "worktree"` is a *different* fence from that one, and worth keeping
apart: isolation narrows what the harness will **claim and admit** (so a guarded
or unguarded write to a discovered tree such as the primary is refused with
`[E_WRITE_OUTSIDE]`; explicit `/roots` grants survive, because only automatic
discovery is narrowed); the bash guard narrows what the *process* can see.
Turning one on does not turn on the other.
Note also what the guard does *not* do: it does not pass `/roots` grants to the
launcher, so a granted extra root is writable by the tools and read-only to a
guarded command.

If you want the path-level facts from the model's side, it can call
`session_info`: the `session` status readback carries `cwd`, `cwdPinned` and
`grantedRoots`. What it does **not** carry today is the git shape — branch, or
"this is a linked worktree" — which is §2.2. Components see the roots through
the private `__workspace` context (`{root, roots}`), which is never the prompt
and never a schema, so none of this changes the request prefix.

## 1.4 A tree made *during* a conversation (fixed; the history still explains a lot)

> **Fixed.** The set now recomputes when the repository's checkout graph changes
> (a sub-second `stat`, no `git` call), so a tree created mid-conversation is
> admitted on the next dispatch — no grant, no restart. The section below
> describes the v0.5.0 defect, because its two symptoms still appear whenever
> anything else goes wrong with the set, and they are worth recognising.

In v0.5.0 the set was cached for the runner's lifetime. Its cache key is the primary plus
the grants, and the **only** thing that invalidates it is a *grant change*. So:

```
conversation starts in ~/git/myrepo
agent runs: bash "git worktree add ../myrepo.wt/exp -b exp"     ← works
agent runs: edit "../myrepo.wt/exp/src/x.nim"
        → [E_WRITE_OUTSIDE] …/myrepo.wt/exp/src/x.nim is outside this
          conversation's workspace
```

Nothing is wrong with the worktree: `computeWorkspaceRoots` would see it. The
cache hid it. The v0.5.0 ways out were:

- **Grant it** — `/roots add ../myrepo.wt/exp`. The grant changes the cache key,
  so the next dispatch rebuilds the set and the write is admitted. The grant
  persists (store kind `grantedroot`, one document per conversation) and is
  capped at 7 alongside the primary.
- **Start the conversation in the tree** (§1.1), which is the saner route.

A grant takes effect **between tool calls**, never during one: a `bash` that is
already running keeps the reach it started with.

## 1.5 The exploratory-then-implement workflow, done by hand

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
gap is exactly what §2.1 removes — it forks the transcript instead.

## 1.6 Merge back and clean up, done by hand

This is the shell equivalent of `/worktree merge`. From the worktree
conversation:

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
- the merge itself is a write into the primary checkout. Driving it through
  `bash` keeps it unclaimed (the opaque claim is the conversation's own root), so
  a concurrent `edit` elsewhere in that primary is not excluded.
  `git_merge {op: "start"}` takes a real lease over the primary, which is a
  reason to prefer it even when you are comfortable in a shell (§2.4).

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
| `[E_WRITE_OUTSIDE] …` for a path you believe is in the set | either the path really is outside it, or the conversation is `isolation: worktree` and you named a `cwd`/path in a discovered tree such as the PRIMARY (isolation refuses, by design) | `/workspace` shows `writable`; `/roots add` grants an extra tree (grants survive isolation), or set `isolation` back to `shared` |
| `conversation cwd is immutable once turns exist` | `/workspace <path>` after a chosen workspace | start a conversation *in* the target directory, or grant it as an extra root |
| A worktree's files show up twice in search or the repo map | both trees are in the set, so both are searched | expected; `isolation` (§2.1) and the census hint in §2.2 reduce it |
| `git worktree remove` refuses | dirty tree, or the branch is unmerged | commit/discard, then merge or use `-D` |
| A guarded `bash` cannot write the primary checkout from a worktree conversation, though `edit` can | the guard makes only the primary workspace writable (§1.3) | intended for now; the guard is narrower than the tool set. Commit from the worktree and merge in a primary conversation, or turn the guard off for that call |
| The agent talks about the wrong tree | it has not called `session_info` yet — the git shape is reported there, not in the frozen prompt (deliberately: the prompt must stay byte-stable) | ask it to call `session_info`, or check `/workspace` yourself |

---

# Part 2 — the integrated workflow

> Everything here ships. The verbs are approval-gated writes, so you see the
> layout, path and lock before anything happens.

## 2.1 The exploratory-then-implement workflow

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
| **Known gap, stated in the output** | a `/compact` checkpoint is not copied. A parent that compacted hands the child the raw pre-compaction records, so the child may summarize differently. The fork result says so explicitly (`checkpointCopied: false`) rather than letting "all context copied" stand |

So: a new conversation id, with your conversation's messages in it, its own
configuration — you continue where you left off with the full argument still in
front of the model, not a summary of it.

`isolation: "worktree"` becomes available at birth too: the primary checkout
stays **readable** (diff, search, compare) but is no longer writable from this
conversation. That is the flag that makes "my checkout of `main` cannot be
touched" true, and it is a fence around the conversation, not a mutex around the
tree: two conversations in one tree still proceed on different files
(`locks`' "disjoint stays parallel" rule is unchanged — WORKTREES.md §10).

*If you would rather drive it yourself:* §1.5, which costs you a second
conversation and a written note.

## 2.2 What changes underneath

Three mechanics make the commands above honest:

- **The set goes live.** `workspaceRootsFor` recomputes when the git graph
  changes — a sub-second `stat` on `<commonDir>/worktrees`, not a `git` call — so
  a tree created mid-conversation is admitted on the **next dispatch** with no
  grant and no restart. §1.4 disappears as a workflow rule. (Sub-second matters:
  two trees created inside one second share a second-granularity mtime, so a
  coarse signature would drop the second — WORKTREES.md §4.2a.)
- **The conversation learns its own shape.** `__workspace` gains
  `primary`/`worktree` and `session_info` gains a `workspace` block, so the model
  is told "you are in a linked worktree of `~/git/myrepo` on branch `fix-race`"
  instead of inferring it from paths or hitting a refusal.
- **One answer about git shape.** `sdk/checkout.nim` replaces three hand-rolled
  parses (`core/workspace.nim`, `systemprompt`, `lsp/roots.nim`), so "is this a
  worktree, and of what?" has one answer in the codebase.

*If you need it:* `/roots add` still works for a tree outside the project, and
`session_info` reports the whole `workspace` block above.

## 2.3 The working loop

Creating and entering a tree becomes a verb instead of a shell out plus a grant:

```
git_worktree {op: "add", name: "fix-race"}         ← approval-gated; you see the
                                                    layout, path and lock first
                                                    (lands in ../myrepo.wt/)
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

`/worktree add` is the client's single key: it creates the tree and then either
moves this conversation into it or forks, and says which (§2.1). `/worktree` with
no argument is the readback — workspace, primary, branch, isolation and origin.
The layout is always a SIBLING (`<repo>.wt/<name>`): an in-repo tree would sit
inside the primary's own `bash` claim, serializing every write, and would dirty
`git status` besides.

## 2.4 Merge back and clean up

```
/worktree merge
```

is the ritual, in these steps:

1. **preview** — `git_merge_preview`, a read (`git merge-tree`), so no
   approval prompt: clean or the conflicting file list *before* anything is
   touched. A bad ref is reported as an error, never as a conflict list.
2. **merge** — `git_merge {op: "start"}` takes a real lease over the primary, so
   two merges into one primary serialize and §1.6's unclaimed write is gone. It
   refuses up front when the target has local changes to a path the merge
   touches, naming those paths.

**Commit first, in the worktree.** `/worktree merge` merges what is committed on
the branch; it does not invent a message for you. Use `git_commit {repo, message,
paths}` — it stages exactly the paths you name, so an unrelated edit stays out,
and returns the commit id.

The merge receipt (commit, files, into, from) lands in the conversation's
history, so "what came out of this exploration?" has an answer months later.

And then you go back:

```
/worktree close
→ worktree removed; branch kept; returned to origin
```

`/worktree close` removes the tree and **switches the client back to the
conversation that forked you there**. It refuses — via git's own rule — while the
tree is dirty, and via the harness's guard while the branch is unmerged or
another live conversation owns the tree; each refusal names the override.

*Can't I just `/session` back to the parent myself?* Yes, and that is most of
what `close` does — but the parent would then have no idea any of this happened,
so its transcript reads as if you stopped mid-thought. That is what `origin` and
the merge notice fix:

- the fork is recorded (`sessionmeta.origin`), so the parent's `session_info`
  lists it under `descendants` — "what came of this?" is one call from where the
  work started;
- the merge **settles into the parent's notice lane**. `drainNotices` folds
  notices into history at the top of every turn, marked as runtime machinery
  rather than something you said, and a merged worktree joins that lane. So
  returning to the parent shows *"the worktree `fix-race` was merged into `main`
  as `9cba035` (4 files)"* — the commit id being exactly what the next step
  (push, PR) needs.

The notice is durable, so an idle parent is not interrupted: it is folded in on
the parent's next turn. Nothing is lost while you are away.

So the whole loop, end to end: explore in the parent → `/worktree add fix-race`
(moves or forks, says which) → work in the tree → `/worktree merge` (preview,
commit, merge, remove) → `/worktree close` returns you to the parent, which now
knows the commit. Push and open the PR from there, with the argument and the
decision still in context.

*If you prefer the shell:* §1.6 — remembering that its merge is unarbitrated —
then `/session` back to the parent and paste the commit id.

## 2.5 How linked conversations relate

A conversation's `parent` edge means *subagent*: depth-capped, approvals routed
up, idle retirement. That is the wrong relationship for "the same piece of work,
now in its own tree", because you keep talking to that conversation as your main
thread — and a worktree fork inheriting subagent supervision would make your main
thread unable to spawn children and route its approvals to the wrong client.

So the two relations are named separately:

| Edge | Meaning | Authority |
|---|---|---|
| `parent` | supervision — spawned to do a job for another conversation | depth rules, approvals route up, idle retirement (unchanged) |
| `origin` | provenance — this transcript was seeded from another, and it is your main thread | **none**; it may spawn its own children, and its approvals stay with its own client |

`sessionmeta.origin = {session, atSeq, reason, worktree}` is the one key; a
supervised fork keeps both edges (`parent` for supervision, `origin` for
provenance), and a worktree fork carries only `origin`. Neither edge is ever
rewritten.

A fork's `session_info` says *"seeded from `conv-abc123` at message 84; working
tree `../myrepo.wt/fix-race` (branch `fix-race`, primary `../myrepo`)"*, and the
originating conversation lists its descendants
(`{sessionId, supervised, origin?, fork?, closed?}`). That
is what makes the exploration → worktree → merge trail readable instead of three
unrelated transcripts. Provenance grants no authority: an origin-only fork may
spawn its own children and keeps its own approvals.

Deliberately **not** planned: a shared mutable context between linked
conversations, or one conversation holding several workspaces. Both would put a
changing list into the request prefix, which is the one thing the frozen-prompt
discipline forbids.

*Without it:* you are the link. Keep the conversation id in your note.

## 2.6 Cheat sheet

| Want | Integrated (§2) | By hand (§1) |
|---|---|---|
| Start working in a tree | `/worktree add x` (alias `new`) | `git worktree add ../repo.wt/x -b x`, start the client there |
| Keep exploring, then switch | `/worktree add x` moves or forks, and says which | write a note, new conversation, paste it |
| A tree created mid-conversation is writable | automatic on the next dispatch | `/roots add ../repo.wt/exp` |
| See where I am / what I can touch | `/workspace`, `/worktree` | `/workspace`, `/roots` |
| Stop writes to `main` | `isolation: "worktree"` (chip shows `· isolated`) | not possible |
| Commit in the tree | `git_commit {repo, message, paths}` | `git commit` in bash |
| Merge back | `/worktree merge` (preview, then merge) | `git merge --no-ff` in the primary |
| Clean up | `/worktree rm x` or `close`, guarded | `git worktree remove`, `git branch -d` |
| Relate two conversations | `sessionmeta.origin`, reported by `session_info` | keep the id in a note |
| Come back to the parent afterwards | `/worktree close`, merge notice waiting | `/session` back, paste the commit id |

## 2.7 Where the pieces live

- [research/WORKTREES.md](research/WORKTREES.md) — the proposal: problem
  statement, the nine slices and their tests, the invariant checklist,
  non-goals, and §5 the same three moments written for the implementer.
- [PLAN.md](PLAN.md) pillar 2 — what the release requires of it and why.
- [MANUAL.md](MANUAL.md) — the operating reference for what ships (this
  tutorial's Part 1 duplicates the *workflow*, not the reference).
- [WORKTREES-ACCEPTANCE.md](WORKTREES-ACCEPTANCE.md) — the live run that verifies
  the pieces still fit together in a real harness, and which half of it needs a
  human at a terminal.
- [research/SANDBOX-BASH-STATUS.md](research/SANDBOX-BASH-STATUS.md) — what the
  bash guard does today, including the single-writable-root rule from §1.3.
- [WIRE.md](WIRE.md) — the exact contract: `__workspace`, `isolation`,
  `sessionmeta.origin`/`descendants`, the peer fork and the merge notice.
