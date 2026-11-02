# WORKTREES — making Niffler worktree-aware

> Status: **proposal, nothing implemented.** Basis: local `main` at `v0.5.0`
> (`6f95a20`). Every claim about current behaviour below was read from the code
> at that commit, and every claim about git was measured on git 2.43 in a
> throwaway repo — where the two disagreed, the measurement wins and the note
> says so. Adopted as the substrate for `docs/PLAN.md` pillar 2 (0.6.0); §10
> records where PLAN and this document still differ.

## 0. The problem, stated as four separate failures

"Worktrees are hard in Niffler" is really four defects that happen to share a
workflow. They need different fixes, so they are counted separately.

**F1 — a worktree that appears mid-conversation is invisible.**
`workspaceRootsFor` (`core/dispatch.nim:1817`) caches the workspace set in
`NestedState.workspaceRoots`, keyed by `rootsKey`, and the only cache
invalidation in the tree is a *grant* (`core/conversation.nim:5779`). Measured
with a real git repo: create the worktree after the first dispatch and the set
never changes again for the life of the runner:

```
first set:  @["/tmp/.../primary"]
second set: @["/tmp/.../primary"]     # after `git worktree add .worktrees/feat`
worktree .worktrees/feat in set? false
```

A fresh computation *does* see it (`computeWorkspaceRoots` consults `git
worktree list --porcelain`), so the awareness exists and only the cache hides
it. Consequence, for a tree **outside** every existing root (the sibling layout
in F3): every write in it is refused with `[E_WRITE_OUTSIDE] … is outside this
conversation's workspace` (`components/locks/main.nim:282`) until the runner
restarts — and a restart is not something a mid-conversation agent can do. For a
tree *inside* a root the fence is satisfied, so the failure is different and
quieter: the new tree is admitted only because it happens to sit under the
primary, not because anyone noticed it.

**F2 — the agent cannot widen its own scope, by design, and there is no
designed path either.** `session {roots: {add, remove}}`
(`core/conversation.nim:5739`) is the only way in, it is **human-only** (the
`session` tool is `hidden` and does not even declare `roots` in its schema,
`core/catalog.nim:240`), and it is a control call: it applies *between* tool
calls and needs a human at a client. So "work in a worktree" is: the agent asks
the human; the human types `/roots add ../repo-feat`; work proceeds; later the
human types `/roots remove`. Every one of those steps is friction on the *one*
workflow the harness is supposed to delegate.

**F3 — the friction is not just the grant, it is the location.** Both of the
obvious places are wrong, and that is the trap:

- A worktree created as a **sibling** (`git worktree add ../repo-feat`) lands
  outside every root in the set → F1/F2 apply.
- A worktree created **inside** the repo lands inside a root, so the fence is
  happy — but the checkout now contains a second full copy of the tree, and
  `git status` in the primary goes dirty:

```
?? .worktrees/        # a worktree inside the repo is untracked
```

The skill that documents this workflow — `using-git-worktrees`, an
operator-installed skill (`~/.niffler/skills/…`), not shipped in this repo —
answers with "verify the directory is ignored before creating the worktree", so
the agent's first act in a fresh repo is an edit to `.gitignore`: a stray,
committed, unrelated change in the user's repo. That is the friction that
actually gets noticed, and it is pure mechanics, not policy.

The resolution is not to pick one of those two placements: it is to fix F1 so a
sibling is *inside the working set anyway*, leaving the worktree out of the repo's
tree entirely (§4.3 step 1, decided 2026-10-30).

**F4 — merge-back is eight bash rounds with no preview, no claim, and a
silent arbitration hole.** Today the merge runs in `bash` (`components/git`
is read-only by design: "mutations stay in bash"). Consequences, each measured
or read:

- **No preview.** `git merge-tree --write-tree` answers "would this merge
  cleanly, and which paths conflict" *before* touching anything (measured:
  exit 0 clean, exit 1 + `--name-only` conflicted paths). Nothing in Niffler
  surfaces it, so the model discovers conflicts by starting the merge.
- **A dirty target is discovered the same way.** `git merge` refuses only when
  the merge would *overwrite* local changes — measured: with `a.txt` dirty and
  the merge touching it, `error: Your local changes … would be overwritten by
  merge`, exit 1; an unrelated untracked file is fine and the merge proceeds.
  The distinction is exactly what the model needs *before* it starts, and
  `merge-tree` cannot tell it (it never looks at a working tree).
- **The claim is over the wrong tree.** `bash` declares `x-harness.writes:
  {"root": true}`, and `writePathsFor` (`core/dispatch.nim:2089`) returns
  `@[workspace]` — *the conversation's primary*. A conversation pinned to the
  worktree that runs `cd ../repo && git merge feat` writes the primary
  checkout **with a lease over the worktree**. The fence admits it (the primary
  is in the workspace set) but nothing arbitrates it. This is a real hole: two
  worktree conversations merging into one primary have no exclusion at all.
- **A commit message is a guess.** `bash` can commit, but the message has no
  idea what the conversation learned; and `git commit -a` inside a conversation
  that also edited `.gitignore` for F3 commits that too.

And one more, smaller, that belongs with the merge: **removing a worktree can
delete a live conversation's workspace.** `git worktree remove` succeeds
silently on a clean tree, and `-f -f` overrides the lock; nothing checks
whether another conversation is pinned there.

## 1. What exists today

Worth stating precisely, because several pieces are already right and the
proposal is mostly wiring plus one new verb set.

| Piece | Where | What it already gives us |
|---|---|---|
| Workspace **set** | `core/workspace.nim` | primary + `git worktree list --porcelain` trees + same-origin sibling checkouts, deduped, capped at 8. Computed from *any* member: starting in a worktree yields `[worktree, primary]`. |
| Set as private context | `core/dispatch.nim:1839` | `__workspace = {root, roots}` injected for `x-harness.workspace` tools after the model's message — so tree awareness costs **no prompt-cache miss**. |
| Fence | `components/locks` + `writePathsFor`/`acquireWriteLease` | path-stripe leases, TTL, holder-named denials, per-session self-supersede. |
| Human grants | `session {roots}` → `grantedroot` store doc | validated, persisted, cap 7 grants, applied between calls, reported as `grantedRoots`. |
| Workspace immutability | `repinWorkspace` / `workspaceChosen` | pristine → movable; unpinned → movable once; chosen → immutable after a turn. |
| Client awareness | niffler-tui `tui/workspace.go` | branch chip with a `⧉` worktree mark, `/workspace` reporting "linked worktree, primary at X", `/roots` add/remove. |
| Worktree shadow rule | `components/systemprompt/main.nim:240` | parses `.git` file → `…/.git/worktrees/<name>` to avoid applying the main tree's `AGENTS.md` twice. Right idea, **hand-rolled**, and only used for prompt shadowing. |

What does *not* exist: any mutating git verb, any worktree ledger, any
worktree-scoped event, any per-conversation isolation scope, and any way for
the model to learn that it is in a worktree at all (`session_info` copies
`cwd` and nothing else).

## 2. Principles this proposal holds to

1. **Git shape is data, not language knowledge.** Nothing here is per-language;
   worktrees are a git concept and git is already trusted as a seam
   (`core/workspace.nim`, `components/git`, `components/systemprompt`). No new
   per-language branch, no new registry: the AGENTS.md "language X, zero
   edits" test is satisfied trivially.
2. **No volatile fact enters the request prefix.** The tree list, the merge
   preview, "you are in a worktree" — all appendix-only: private dispatch
   context, tool results, status events. The frozen prompt and the frozen tool
   schemas stay byte-identical. A worktree appearing mid-conversation must not
   cost a cache miss (§6).
3. **Authority is a human decision, recorded — never a discovery.** The
   conversation-policy target states it plainly ("discovering a sibling checkout
   or git worktree does not add a root; only a human decision does",
   `SANDBOX-CONVERSATION-POLICY.md`), and shipped code *already* does the
   opposite: `computeWorkspaceRoots` adds every discovered tree and the fence
   admits them. This proposal does not pretend that away, and it does not widen
   it further: the creation becomes an approved act with a store record (§4.3),
   and `isolation: "worktree"` is the restrictive half (§4.5). If the policy
   document is to stay authoritative, that discrepancy is a decision to take —
   §9 Q8.
4. **Friction-free for the agent, auditable for the human.** The agent must be
   able to run create → work → review → merge → remove without a human typing
   in another window, and every step must leave a record the human can read.
5. **Nothing new in core that is component-shaped.** One `sdk/checkout.nim`
   helper (git shape), core's cache fix and one small declaration, and the verbs
   in the `git` component. Read tools keep their contract (approval-free, fixed
   argv, path-scoped); the new verbs are a separate surface, approval-gated, and
   `NIF_GIT_MUTATIONS=off` returns the component to exactly today's five read
   tools for anyone who wants that guarantee by configuration.

## 3. The shape in one paragraph

A worktree becomes a first-class, *recorded* object: created as a SIBLING at
`<repo>.wt/<name>` (`~/git/repo` → `~/git/repo.wt/feat`), locked with a reason
naming the conversation, recorded as a `worktree` store doc, immediately
reachable because core recomputes the workspace set when git says the checkout
graph changed, reviewable without a merge (`git_merge_preview`),
mergeable as an *ordinary claimed write into the primary*
(`git_merge {op: "start"}`), and removable only when nothing is pinned to it.
The sibling placement is load-bearing for arbitration, not cosmetic: two claim
sets on disjoint paths are the only way two sessions can work in parallel (see
§4.3 step 1). The conversation stays pinned to its tree — the merge is a write,
not a move — and an optional `isolation: "worktree"` scope makes the tree a
*fence* rather than a convenience, which is what finally makes "my checkout of
main cannot be touched by this conversation" true.

## 4. The pieces

### 4.1 `sdk/checkout.nim` — one answer to "what is this directory?"

Three places already answer git-shape questions by hand, differently:
`core/workspace.nim` shells `git worktree list` and contains the same-origin
sibling heuristic, `components/systemprompt` parses the `.git` *file* for
`worktrees/<name>`, and `components/lsp/roots.nim` walks markers independently.
Each is correct enough in isolation; together they are three ways to be wrong
about one repository.

New pure module (`std/os` + `std/osproc` only, no NATS, no core imports — the
envelope-codec rule's spirit), one call, one shape:

```nim
type CheckoutKind* = enum ckNone, ckRepo, ckLinkedWorktree, ckSubmodule

type Checkout* = object
  kind*: CheckoutKind
  root*: string          ## the tree containing this path (first marker upward)
  gitDir*: string        ## `git rev-parse --git-dir`, absolute
  commonDir*: string     ## `git rev-parse --git-common-dir`, absolute
  primaryRoot*: string   ## the primary checkout's working tree ("" when unknown)
  branch*: string        ## short branch name, "" when detached
  superproject*: string  ## non-empty inside a submodule
```

`ckLinkedWorktree` is decided exactly as git does (`gitDir != commonDir` **and**
no superproject — the same submodule guard the `using-git-worktrees` skill
spells out, which a bare `gitDir != commonDir` test gets wrong).

Consumers, all of which shrink:

- `core/workspace.nim` — keep `computeWorkspaceRoots`'s *policy* (which trees
  belong together), drop its parsing; `git worktree list` becomes
  `checkout.worktrees(repo)`.
- `components/systemprompt` — the shadow rule becomes
  `checkout.primaryRoot`, deleting the hand-rolled `.git`-file parse.
- `components/lsp/roots.nim` — `deriveRootUnbounded` starts at
  `checkout.root` instead of a marker walk (markers still decide the
  *language's* project root; git decides where the tree is).
- the new `git` verbs (§4.3) — the same answer they act on.

This is the mechanical slice: no behaviour change intended, so it is the one
that can land first and be judged by the existing suite.

### 4.2 Core: make the set live, and make it say what it is

**(a) Recompute on git-graph change, not never.** Two complementary changes,
both cheap:

- `workspaceRootsFor` recomputes when the *graph signature* changes: the tuple
  `(primary, commonDir, presence+mtime of <commonDir>/worktrees)`. A `git
  worktree add/remove` creates or deletes a directory under
  `<commonDir>/worktrees/`, so this is one `stat`, not a `git` call, on the
  dispatch path. A full recompute (three git invocations) still happens only
  when the signature moves — the current cost profile is preserved for the
  ordinary case.

  Three measured details that decide whether this works, all found before
  implementation:

  1. **Sub-second precision is required.** `git worktree add a` then
     `add b` inside one second gives the same `st_mtime` at *second*
     granularity and different `st_mtime_ns` — measured:
     `…0030507445` vs `…0037507375`. A signature built from
     `getLastModificationTime().toUnix` (seconds — what `core/dispatch.nim`
     already does elsewhere for binary mtimes) would miss the second tree
     entirely, which is exactly the "a worktree appeared and nobody noticed"
     bug F1 exists to kill. Use nanosecond stat (`getFileInfo().lastWriteTime`
     plus `size`, or `st_mtime_ns` on posix) and keep `size` in the signature as
     a coarse backstop for filesystems with coarse timestamps.
  2. **Absence is a value.** Git **deletes** `<commonDir>/worktrees/` when the
     last worktree goes (measured: `stat` fails after `worktree remove`). The
     signature must therefore encode "no such directory" as its own state, not
     as an error that leaves the previous signature (and the stale set) in
     place.
  3. **The cache is per-runner and the field is on `NestedState`.** That is
     fine — `ct.nested` is the live-turn object — but note `workspaceRootsFor`
     already recomputes whenever `rootsKey` differs, and `rootsKey` is only
     reset on a grant. The graph signature is a *second*, independent condition
     (`rootsKey != key or graphSig != cachedSig`), not a replacement: a grant
     must still rebuild even when the graph is unchanged.
- `ev.worktree.changed {repo, path, branch, sessionId, action}` published by
  the `git` component after every mutating worktree verb. The runner clears
  `rootsKey` on it, the same way a settings change clears a config mirror
  (`ev.config.updated`): an event for the state that *must* follow another
  component, a poll only for the state that must survive a missing one.

With (a) alone, F1 disappears: create a worktree (by any means — bash, the new
verb, or by hand in another terminal) and the *next* dispatch sees it. Verified
that a fresh `computeWorkspaceRoots` already returns the right set for both
directions (from the primary, and from inside the worktree).

**(b) Say the shape in the private context.** Extend the `__workspace` payload
(non-prefix, appendix-only):

```jsonc
"__workspace": {
  "root": "/home/me/repo.wt/feat",
  "roots": ["/home/me/repo.wt/feat", "/home/me/repo"],
  "primary": "/home/me/repo",
  "worktree": {"linked": true, "branch": "feat", "primaryRoot": "/home/me/repo"}
}
```

`root`/`roots` are unchanged — this is purely additive, so components that do
not read the new keys keep working. Two consumers are worth naming, and only one
of them needs anything today: `bash`'s guard reads `__workspace.root` for the
sandbox root and has no way to know that root is a *linked worktree* of another
checkout (`components/bash/guard.nim`), which is exactly what the `worktree`
block answers; `lsp` needs nothing (it already indexes the tree as *that* tree
from `roots`), and `repomap` needs nothing either (its auto-append maps the
workspace that `ev.workspace.opened` named, not the whole set, so a worktree
conversation already maps only its own tree).

**(c) Make the model able to see it.** `session_info` gains a read-only
`workspace` block: `root`, `roots`, `linked`, `branch`, `primaryRoot`, the merge
candidates, and a bounded `trees` array (§7.5 Q3). It is a **tool result**, so it
appends to history and never touches the prefix — and it is the only way an agent
learns "I am in a linked worktree whose primary is X", which today it cannot
learn at all. It is a core tool, so it builds the shape from
`sdk/checkout.nim` directly rather than calling the `git` component; cost is one
`git worktree list` plus one `git status` per tree, bounded, nothing cached.

### 4.3 The `git` component grows a mutation surface (declared, approval-gated)

The read tools stay exactly as they are. A second, separately-declared surface
is added — `onDemand: true`, and every mutating op `approval: "always"` and
`effect: "write"` — **gated by a declared setting**
(`config_declare`, domain `git`, key `mutations`, env fallback
`NIF_GIT_MUTATIONS`, application `component restart`). Default on; `off` stops
the component registering the verbs at all, which is the honest way to keep
today's read-only contract for an operator who wants it by configuration rather
than by trust. Declaring it (rather than reading the env var alone) is the rule
`CONFIG-CONTRACT.md` sets: an env var a component enforces is a setting, and
`NIF_*` stays only as the migration fallback (`settingBool`).

One tool per *workflow* reads better than nine for the model — `lsp` already
proves an `op`-dispatch tool works — but the claims differ per op, so the split
below is by claim shape, not by taste. Note the structural constraint that comes
with `x-harness.writes`: a declaration is static per TOOL, so `list` (a read)
cannot live in the same schema as `add` (a write). Hence `git_worktree_list` is
its own small read tool and `git_worktree` carries only the three mutating ops.

#### `git_worktree_list {repo?}` (read) and `git_worktree {op, repo?, path?, branch?, base?, name?, force?, delete_branch?}` (write)

| op | approval | claim (`x-harness.writes`) | notes |
|---|---|---|---|
| `list` (`git_worktree_list`) | no (`effect: read`) | none | `git worktree list --porcelain`, parsed: path, branch, HEAD, locked (with reason), prunable, bare, isCurrent, plus the ledger's owner conversation per tree |
| `add` | always | `paths: ["repo", "path"]` | creates `path` (default `<primary>.wt/<name>` — see the orientation rule below), branch from `base` (default the primary's current branch), then **writes the store record and locks the tree**. No ignore rule is needed for the sibling layout. `repo` is claimed because `add` also writes git metadata (`<commonDir>/worktrees/<name>`, `refs/heads/<branch>`) |
| `remove` | always | `paths: ["repo", "path"]` | refuses when (i) another *live conversation* is pinned there (the ledger, which git cannot know), (ii) the branch is not merged into its base — each refusal names the flag that overrides it. A dirty tree is already refused by git itself (measured: exit 128, "contains modified or untracked files"); surface that message verbatim rather than re-implementing it. The `repo` in the claim is not decoration: removal deletes `<commonDir>/worktrees/<name>`, so it writes the repository's own git metadata |
| `prune` | always | `paths: ["repo"]` | `git worktree prune` for trees deleted out from under git |

`add` is where F3 dies, in two live steps (the third is now a no-op, kept
because it records why), each verified:

1. **Layout.** `<repo>.wt/<name>` — a SIBLING of the repo, one shared
   container directory (`~/git/repo` → `~/git/repo.wt/feat`). **Revised
   2026-10-30 (owner decision): always the sibling, never in-repo, and no
   convention detection** — `git config niffler.worktreeDir` and the existing
   `.worktrees/` probe are both dropped. One rule everywhere is worth more than
   honouring a repo's local habit, and the probes bought nothing that the
   sibling does not already give.

   **Orientation: the container hangs off the PRIMARY, never off the current
   workspace.** `<primary>.wt/<name>`, where `<primary>` is
   `checkout.primaryRoot` — not `parentDir(workspace)/name(workspace).wt`.
   Measured why: a conversation already in `~/git/repo.wt/feat` that computed a
   sibling from its own path would create `~/git/repo.wt/feat.wt/<name>` — one
   level deeper on every hop (`repo.wt/a.wt/b.wt/…`), a container per worktree
   instead of one per repository, and a path nobody can predict. One container
   per repository is the whole point, and it is what makes the claim sets
   disjoint from the primary by construction. Three consequences to implement
   explicitly:

   - from the **primary**, `repo.wt/<name>` — the ordinary case;
   - from a **worktree**, still `repo.wt/<name>` (the primary's container), so a
     conversation in a tree can cut a second tree next to itself;
   - and `add` must refuse when the resolved `path` would be **inside** an
     existing worktree of the same repo (`pathInWorkspace` against the set),
     which is the mistake this rule exists to prevent.

   Why the sibling, in order of weight:

   - **Arbitration.** `overlaps` (`components/locks/main.nim:135`) treats two
     claims as conflicting when one is an ancestor of the other across a
     separator boundary. An opaque writer claims its workspace ROOT, so with an
     in-repo layout the primary's `bash` claim on `~/git/repo` is an ANCESTOR of
     `~/git/repo/.niffler/wt/feat/x.nim` — every `bash` call in the primary
     serializes against every write in every worktree, which is the exact
     opposite of parallel lanes. As a sibling,
     `~/git/repo.wt/feat` does not start with `~/git/repo/` (the byte after
     `repo` is `.`, not `/`), so the two claim sets are disjoint by
     construction and the separator boundary does the work.
   - **No hidden second tree.** The worktree is not inside the primary at all,
     so it cannot be traversed by `grep`/`files`/`repomap` whatever their
     ignore rules do — the hygiene problem is removed rather than managed.
   - **No ignore bookkeeping.** With no tree inside the repo, `info/exclude`
     needs no entry and the user's `.gitignore` is never touched. Step 2 below
     becomes a no-op, not a step.
   - **Legible and durable.** One sibling entry per repo (`repo.wt/`) rather
     than N, named after its owner, visible in `ls ..` and an editor's project
     list, outside `$NIF_ROOT/var` so `make clean` cannot delete uncommitted
     work, and it survives a harness reinstall.
   - **Same filesystem by construction,** so `git mv`, hardlink-adjacent
     tooling and a sandbox bind mount all behave.

   Honest limits this creates, stated rather than discovered later:

   - **A shared git object store.** Worktrees of one repo share
     `<commonDir>` (`objects/`, `refs/`, and the per-worktree `gitdir` files),
     so two sessions committing in different worktrees still meet there. That
     contention is git's own lock discipline, not ours: our lease covers the two
     trees, and `git_worktree {op: add|remove}` keeps claiming BOTH `repo` and
     `path` for exactly this reason (see the table above).
   - **The `niffler-tui` cwd flow changes shape:** a client started inside a
     worktree now sits in `../repo.wt/<name>`, not `../repo/.worktrees/…`.
     Nothing in the resolution logic cares (it is the workspace either way), but
     docs and examples must say `repo.wt`.
   - **A name collision is possible** where an in-repo layout could not have
     one: if `~/git/repo.wt` already exists and is not ours, `add` refuses and
     names it rather than adopting it. Grafting an existing checkout into our
     git metadata is the one mistake here that feels irreversible.
   - **Discovery pressure:** a sibling worktree occupies one of the 8 slots in
     `computeWorkspaceRoots`, one per conversation. See Q3 below — the
     discovery cap now matters more than it did for the in-repo layout.
2. **Hygiene: nothing to do (was `info/exclude`).** The earlier revision appended
the worktree pattern to `$(git rev-parse --git-path info/exclude)`, because an
in-repo worktree showed up as `?? .niffler/` in `git status`. A sibling tree is
not in the repository at all, so there is no status entry to suppress and
neither the user's `.gitignore` nor the repo's `info/exclude` is ever touched.
Keep this step only as a note for the future: if anyone reintroduces an in-repo
layout, the `info/exclude` route is the one that works (verified: one file,
shared by every worktree, and `git check-ignore -v` names the rule), *not*
`.gitignore`.
3. **Ownership.** `git worktree lock --reason "niffler conversation <id>"`
   (verified: a locked tree refuses `git worktree remove` with the reason
   quoted, and only `-f -f` overrides it), plus a `worktree` store doc
   `{repo, path, branch, sessionId, base, createdAt, state}`. The store doc is
   the ledger: `list` merges it with git's own view so a human sees *whose*
   tree each one is, and `remove` refuses on a live pin using it — the fact git
   cannot know.

   **Prerequisite the component does not have yet (verified 2026-10-30).** The
   component never touches the store, so the ledger needs two things — and, to
   be precise about what it does *not* need, no new handler shape: the
   block-form `comp.tool` macro sets `comp.sessionContext` on every call
   (`sdk/niffler/sdk.nim:1259`) and `git/main.nim:76` already binds a
   module-level `comp`, so a plain `proc` can read the session and call
   `comp.storeGet`/`storePut` exactly as `builder` does (`comp.sessionContext`,
   `components/builder/main.nim:249`). Compile-checked before writing this down.

   - the new verbs declare `x-harness.sessionId: true`, so core injects
     `__session.session`; without it `comp.sessionContext` is `""` and the
     ledger cannot record *whose* tree it made, which is the whole point of the
     "another live conversation is pinned here" refusal;
   - the store being unreachable must degrade honestly: `add` still creates the
     tree and locks it (git's own lock already names the conversation in its
     reason), but the result says the ledger write failed, and `remove`'s
     live-pin check then falls back to the lock reason it can read from git.
     **Failing closed** (refusing to create a tree because the store is down) is
     the wrong trade — the git-level lock is the durable half, and a
     conversation must not lose the ability to start work because a metadata
     write failed.

   So the step is real but small: the `git` component stops being purely
   read-only, while staying handler-shape-identical to today.

#### `git_merge_preview {repo?, into?, from?}` (read) and `git_merge {op, repo?, into?, from?, strategy?, allow_dirty?}` (write)

Same split, same reason: a declaration is per tool, so the read half cannot ride
with the write half.

| op | approval | claim | notes |
|---|---|---|---|
| `preview` (`git_merge_preview`) | no (`effect: read`) | none | **the missing verb.** `git merge-tree --write-tree --name-only <into> <from>` — but see the exit-code trap below before implementing. Plus `rev-list --left-right --count` for divergence and `git diff --stat into...from` for the shape of the change. |
| `start` | always | `paths: ["repo"]` | refuses up front when the target tree has local changes to a path the merge touches (the `preview` file list intersected with `git status --porcelain`), so the refusal names the paths instead of quoting git's abort; `allow_dirty: true` proceeds anyway. Then `git merge --no-ff --no-edit <from>` → `{merged: true, head, files}`. Unrelated dirt is allowed, which is git's own semantics |
| `abort` | always | `paths: ["repo"]` | `git merge --abort` — the honest answer to a conflict the model cannot resolve |

#### `merge-tree`'s exit codes: 1 means two different things (found 2026-10-30)

The obvious reading — "exit 0 clean, exit 1 conflicted" — is wrong, and the
wrong reading is the dangerous one. Measured on git 2.43:

| Situation | exit | stdout | stderr |
|---|---|---|---|
| clean merge | 0 | tree OID | (empty) |
| real conflict | 1 | tree OID, then conflicted paths, then the `CONFLICT` lines | (empty — `--name-only` goes to stdout, `2>&1` is fine) |
| **`from` does not exist** | **1** | **empty** | `merge-tree: <ref> - not something we can merge` |
| both refs identical / already merged | 0 | tree OID, no paths | (empty) |

So `exit == 1` covers both "conflicts in these files" and "you typo'd the
branch". A `preview` that maps `exit 1 → {clean: false, conflicts: <parsed
paths>}` therefore reports a **fabricated clean-nothing conflict** for a bad
ref, and the model's next move is to try to resolve a conflict in a branch that
does not exist. (The same shape would also let a *missing* `git` — exit 127,
`findExe` returns "" and `runGit` reports it — read as "conflicted" if the
mapping were `!= 0`.)

The rule for the implementation, stated so it cannot be re-derived wrongly:

```
code 0   -> clean; parse the tree OID, no conflict paths
code 1   -> REQUIRES a positive discriminator before claiming a conflict:
            the first stdout line must be a 40/64-hex tree OID **and** the
            output must contain "CONFLICT" (or `--name-only` produced paths).
            Otherwise -> {ok: false, error: "cannot preview <into>...<from>: " +
                          stderr verbatim, exit: 1}
code 124 -> timed out (the component's own convention)
code 127 -> git missing (runGit already answers this)
other    -> error, stderr verbatim, never "conflicts"
```

`--messages` is the alternative discriminator (it is on by default for
`--write-tree`); the point is that ONE exit code must never map to one verdict
without inspecting output, and that a bad ref must never present as a conflict.
This belongs in `t_git`: a preview against a nonexistent branch must fail with an
error naming the ref, and must NOT return a conflict list.

The claim is `paths: ["repo"]` — the resolved target tree. That is the hole
from F4 closed *without* a new declaration shape, because lock stripes use
prefix containment (`components/locks/main.nim:135`): a directory path
claims everything beneath it. Two conversations merging into one primary now
exclude each other, and a *worktree* conversation merging into the primary
holds a lease over the primary — which is exactly the intent.

One default deserves its own sentence, because it is the merge-back friction in
its purest form: for `repo` absent in a conversation whose workspace is a
**linked worktree**, `repo` defaults to that worktree's **primary** root
(`checkout.primaryRoot`, §4.1) — "merge this branch back" is what a worktree
conversation almost always means, and making the model name the primary path
(which it may only have learned from `session_info`) is the step that gets
skipped and turns into a merge into the wrong tree. `into` defaults to the
primary's current branch, `from` to the workspace's own branch.

**The default and the claim disagree unless core helps (found 2026-10-30,
before implementation).** `writePathsFor` derives the claim from the argument
values it can see (`x-harness.writes.paths` names fields), while the *default*
is applied by the component, after the gate has already run. Measured against
the real function:

```
git_merge {from: "feat"}          -> claim @["/home/me/repo.wt/feat"]   ← the WORKTREE
git_merge {repo: "/home/me/repo"} -> claim @["/home/me/repo"]           ← the primary
bash (opaque root)                -> claim @["/home/me/repo.wt/feat"]
```

So the friction-free call would take a lease over the tree it is *not* writing —
the exact F4 hole this section claims to close, re-created by the convenience
default. Two ways out, and the plan must pick one rather than let the
implementer discover it:

1. **`repo` is required on `git_merge`** (and `git_commit`) — no default. Simple,
   honest, and it makes the claim provably the write. Cost: the model must name
   the primary path, which §4.2(c)'s `session_info.workspace.primaryRoot` gives
   it in one call.
2. **A core-side default**: `applyWorkspace` gains a `defaultPathFields`-style
   rule for `cwdField` when the conversation is in a linked worktree, so the
   value the gate sees is already the primary. This keeps the convenience and the
   claim consistent — and it is the better answer *if* the same default is
   meaningful for other tools, which it is not: `bash`'s `cwd` must stay the
   workspace, never silently jump to the primary.

**Recommendation: option 1.** Required `repo` for the merge/commit verbs, plus a
refusal text that prints the primary path it thinks you meant (`checkout.primaryRoot`)
so the model's next call is unambiguous. A silent default that changes which tree
gets locked is the kind of thing that is invisible until two conversations
collide.

#### `git_commit {repo, message, paths?, all?, amend?}`

| approval | claim | notes |
|---|---|---|
| always | `paths: ["repo", "paths"]` | `git add` the named paths (or `-a`), then `git commit -m`, returning `{commit, files, insertions, deletions}`. `repo` belongs in the declaration because `writePathsFor` falls back to the *conversation workspace* when a path-bound declaration matches nothing — and committing into the primary from a worktree conversation would then claim the wrong tree, which is precisely the defect §4.4 fixes for opaque writers. Naming `repo` makes the claim the tree the commit lands in |

Why this deserves a verb rather than "bash can do it": the **message**. The
conversation has just spent a turn learning what changed, why, and which tests
passed; a `bash git commit -m "..."` throws that away and the model
reconstructs it from `git_diff` in a later round. The verb lets the caller
supply the message it already knows, and the result carries the receipt
(`commit`, `files`, counts) that the merge step, the review receipt
(`review_receipt`, already shipped) and `activity_list` can point at. It also
solves F3's stray `.gitignore`: `commit` refuses to stage paths outside the
named set, so the model cannot silently commit an unrelated ignore edit it made
an hour ago.

**Not in scope** (bash remains the escape hatch, and should): `rebase`,
`cherry-pick`, `reset`, `push`, `tag`, `submodule`. Each is a workflow of its
own and none of them is the worktree flow.

### 4.4 Fix the opaque claim: it must follow the resolved cwd

A one-function fix in core, independent of worktrees but essential to them.
Today an opaque writer's claim is `@[workspace]` — the conversation's primary —
regardless of what it actually touches. `bash` with `cwd: <sibling>` therefore
writes the sibling **unclaimed** (the fence admits the sibling because it is in
the set, but no lease covers it). Measured by reading `writePathsFor` and
`acquireWriteLease`; the consequence is F4's merge hole and its general form.

```nim
proc opaqueClaimRoot*(schema, args: JsonNode, roots: openArray[string],
                      primary: string): seq[string]
  ## The tree an opaque writer really writes: the workspace-set root that
  ## CONTAINS its resolved cwdField (deepest match wins), else the primary.
```

Rules:

- `cwdField` resolved to a path inside root R of the set → claim R. (`bash`,
  `builder`, `fabric`, and anything else declaring a `cwdField`.)
- no `cwdField`, or a cwd outside every root → claim the primary, exactly as
  today (fail-safe: keep the coarse claim rather than guard nothing).
- With the sibling layout the containing-root test is unambiguous (no root is
  inside another); "deepest match wins" is kept anyway so the function stays
  correct if a nested layout ever comes back, and so `cwd` deeper inside one
  tree still resolves to that one tree.
- `writes: {"roots": true}` — a new, explicit declaration for a tool that
  legitimately touches **every** root (a whole-repo formatter, a cross-tree
  build): claim them all. Nothing shipped needs it today; it exists so that
  "claim everything" is a statement, not an accident.

This is the fix that makes "the agent worked in a worktree and the primary was
never touched without a lease" true, and it costs one stat-free comparison:
`pathInWorkspace` (`core/workspace.nim`) already performs exactly this
containment test on already-normalized, already-cached roots.

### 4.5 Conversation birth in a worktree, and `isolation: "worktree"`

**Birth (F2's answer, client side).** Nothing in core changes: a client that
starts inside a linked worktree sends `cwd = <launch dir>` exactly as today,
and core's set *already* ends up `[worktree, primary]`. What is new is that the
client can also say what it discovered:

```jsonc
session {sessionId, cwd: "<worktree>", checkout: {"primaryRoot": "<repo>",
                                                  "branch": "feat"}}
```

`checkout` is birth-only, advisory, and recorded in the header
(`checkout.primaryRoot`, `checkout.branch`) — it is what a `session_info` /
UI readback can show without shelling git, and what a *later* runner (which may
have been started without a cwd) can still answer "which primary owns me".
A value that contradicts git is ignored with a warning: git is the authority,
the client is a shortcut.

**Isolation (the real win, and the reason to bother).** Right now "work in
worktree W of repo R" means "W and R are both writable", because discovery puts
R in the set and the fence honours the set. That is the opposite of what a
worktree is for. Add one per-conversation scope, human-only (never in the
`session` tool schema for the model, next to `roots`):

```jsonc
session {sessionId, isolation: "shared" | "worktree"}   // default "shared"
```

- `shared` — today's behaviour, unchanged: the whole set is writable.
- `worktree` — the **write fence** narrows to the conversation's own workspace,
  `roots[0]`: `workspaceRootsFor` returns just that entry, so `lock_acquire`
  refuses a claim anywhere else. The refusal keeps the code it already emits
  (`[E_WRITE_OUTSIDE]`, `components/locks/main.nim:282`) and gains the two ways
  out in the text: `session {roots: {add: [...]}}` for a deliberate one-off, or
  `isolation: "shared"`. Without this a worktree conversation can edit the
  primary in place, which is the one thing a worktree is supposed to prevent.
  No new code is needed for the refusal itself: `lock_acquire` already answers
  "outside the declared working set: not ours to grant or deny" whenever the
  claim escapes the roots core sends it — the change is which roots core sends.

  Note what this deliberately does **not** narrow: reads. There is no read fence
  in `locks` — `read`/`grep`/`git_diff` take no claim — so comparing against the
  primary keeps working, which is the whole reason to keep the primary in the
  set at all. `__workspace.roots` still carries the full set for components that
  use it to *accept* work (`lsp` indexes a primary file under its own root
  rather than refusing it); only the claim path is narrowed.

Mutable between calls like a grant (it is not in the prompt, so no cache
rebuild), persisted in the header, reported as `isolation` on the status
readback, and shown by the client. Recording *why* it exists matters: this is
the property that makes a fork/subagent born into a worktree safe to leave
running, which is the deferred "worktree-per-conversation" item in
`docs/PLAN.md` and `OPENHANDS.md` §3.15.

`agent_spawn {isolation}` then becomes a two-line follow-on in the `agent`
component (pass the key through on the birth call), so a delegated child can be
given its own isolated tree — which is the capability `CODEWHALE.md` D1 asks
for, delivered as data through the existing seam rather than as new machinery.

**Prerequisite, shipped ahead of the rest (2026-11-01): subagents now inherit
the caller's workspace and grants.** This was not in the plan and should have
been — it is the defect that makes a worktree fleet impossible. `agent_run`/
`agent_spawn` had no `cwd` argument at all, so every child was born at
`NIF_ROOT`: all 13 subagents in the store had the harness root as their
workspace while 26 parent conversations lived elsewhere, and each child's
opaque `bash` claim then locked an unrelated repository out from under every
other conversation (`[E_WRITE_BUSY]`, observed live). `inheritSandboxPolicy`
existed for the grant half and had no production caller. Both halves now travel
at birth (docs/WIRE.md "Subagent workspace and grant inheritance"), asserted by
`tests/t_agentinherit.nim`. Slice 5's `isolation` key rides the same seam, and
`agent_spawn {isolation: "worktree"}` is now genuinely two lines.

### 4.6 Starting a client inside a worktree: what already works, and what doesn't

The user-facing question is "if I start niffler-tui in a worktree, does Niffler
understand?" — so state the answer precisely, because it is part-true today and
the gap is not where it looks:

| Behaviour | Today |
|---|---|
| The conversation's workspace is the worktree | **works** — the client sends its launch dir as `cwd` on birth (`niffler-tui` repo, `tui/main.go`: `m.sessionNeedsCreate` → `args["cwd"] = m.cwd`), core pins it. |
| The primary is also writable (so a merge is possible at all) | **works** — `computeWorkspaceRoots` from inside a worktree returns `[worktree, primary]` (verified). |
| The client *says* it is a linked worktree | **works** — the bottom row shows the branch with a `⧉` mark (`niffler-tui` `tui/workspace.go:loadBranchCmd`), and `/workspace` names the primary. |
| The model is told | **does not work** — `session_info` copies `cwd` and nothing else; the model can only infer it by running git itself. |
| Writes in the primary are *prevented* | **does not work** — the fence admits the whole set, so a conversation in a worktree can edit the primary in place (that is what `isolation: "worktree"` is for, §4.5). |
| A worktree created *after* the conversation started is usable | **does not work** — F1's stale cache. |
| Merge back has a verb, a preview, or a claim | **does not work** — F4. |

So the client-side setup the user asks for is already there for the *fresh*
case; what is missing is (a) the model's view, (b) the fence, and (c) everything
about coming back. That ordering matters for the plan: it is why slice 5 alone
(one header field and one dispatch filter) delivers the most user-visible
behaviour change, and why no client work is a prerequisite for it.

One genuine wrapper gap, worth fixing whether or not the rest lands:
`resolveNATSURL()` in the client falls back to a **cwd-relative** `var/nats-url`
(`niffler-tui` `tui/main.go:4012`), which inside a worktree is a path that does
not exist. Today it is masked because the wrapper always exports `NIF_NATS_URL`;
the SDKs resolve against the clone (`sdk/go/harness.go:ResolveNatsUrl`) and the
client should too.

### 4.7 The client surface itself (niffler-tui, separate repo)

Small, and mostly reading what core now reports:

- **Bottom row**: the `⧉` mark already exists; add `· isolated` when
  `isolation: "worktree"`, so the human can see that main is protected.
- **`/workspace`**: report `linked worktree of <primary> on <branch>`,
  `isolation: shared|worktree`, and the merge candidate (`<primary> ← <branch>`,
  ahead/behind) — a one-line preview, not a command.
- **`/worktree`** (new, mirrors `/roots`): the single key for the ritual —
  readback, `add`, `merge`, `rm`, `close`; the exact rendering and the decisions
  behind each subcommand are §5.5, and `close` (switch back to the origin) is
  §5.3b.

## 5. How people actually work in a worktree (the ideal setup)

The three moments that matter, and what the harness should do in each. The
design rule throughout: **a human says what they want ("work in a worktree",
"merge it back") and the harness picks the mechanism, then says which one it
picked.** Nothing here asks a person to reason about workspace immutability or
conversation lifecycle; those are consequences the harness explains.

### 5.1 Moment 1 — "I have been exploring; now let's change code"

You started a conversation in the repo, read files, argued about approaches,
and have decided to implement. You do **not** want to lose that context, and you
do not want the edits landing in your checkout of `main`.

**You are not forced to start a new conversation, and you are not forced to keep
the old one.** One command decides:

```
/worktree add fix-flaky-test
```

What it does, in order:

1. Creates `../repo.wt/fix-flaky-test` (sibling, branch from the current one),
   locks it, records it (§4.3).
2. Looks at the **conversation** and the **tree**, and picks one of two
   outcomes:

   | Conversation state | Tree state | Outcome |
   |---|---|---|
   | pristine, or unpinned (nobody ever chose a workspace) | clean | **MOVE** — the same conversation continues, now pinned to the worktree. `repinWorkspace` already allows exactly this case. A pristine one re-resolves the constitution (nothing was cached yet, so nothing is lost); an unpinned one with turns keeps the prompt it froze, which is safe because the frozen prompt names the harness root and never the workspace path |
   | chosen (a workspace was picked, or it already moved once) | clean | **FORK** — a new conversation seeded with this one's transcript (`agent_spawn {fork: true}`, shipped), born in the worktree. The exploration stays as its own record |
   | any | dirty (uncommitted changes in the old tree) | **REFUSE the move, offer fork** — moving would strand the edits in a tree nobody is looking at any more. The refusal names the dirty paths and the two ways forward: commit first, or fork and leave the old tree as it is |

3. Reports one line: `moved this conversation to ../repo.wt/fix-flaky-test
   (branch fix-flaky-test)` or `forked into a new conversation on branch
   fix-flaky-test — this one stays at ../repo`.

So the answer to "am I forced to create a new conversation?" is **no, and usually
you will not notice either way**: a fresh exploration is moved, a
long-lived/pinned one is forked, and the harness tells you which. Nothing is
silently abandoned either way — a fork leaves the parent untouched, and a move
keeps the transcript that motivated it.

**What a fork actually carries — exactly** (verified against
`components/agent/main.nim` `forkHistory`, so the promise above is not a guess):

- **Copied verbatim:** the parent's completed turns as real `message` records
  under the child's id — `role`, `content`, `tool_calls`, `tool_call_id`, `name`
  and `createdAt`. Tool calls travel with their results, so the child's first
  request replays a valid provider history, and the model has literally *read*
  the conversation rather than being told about it. The copy always cuts on turn
  boundaries (`fork: true`, `{lastK: n}` or `{maxChars: n}`), never mid-tool-round,
  and excludes the turn in flight.
- **Deliberately dropped:** per-message `usage` (the child's accounting is its
  own — copying the parent's meters would lie twice), `summary` records (a
  derivation of records also being copied) and `error` records (the parent's turn
  audit).
- **Not inherited — the child's own:** the system prompt (re-resolved at the
  child's birth, so a persona/AGENTS change between the two is picked up), the
  frozen toolset snapshot, the model/provider pin, the approval mode, the budget
  limits, the granted roots and `isolation`. A fork is a *new conversation with a
  history*, not a clone of the old one's configuration.
- **Known gap to close in this slice:** a compaction checkpoint is **not**
  copied. A parent that `/compact`ed hands the child the raw pre-compaction
  records, so the child may summarize differently. Either copy the checkpoint
  forward as the projection seed, or state it in the command's output — silently
  re-deriving a summary the human already accepted is the wrong default. This is
  the one place where "all context copied" would be an overstatement today.

**Why not simply always fork?** Because a fork splits attention: two conversations,
two transcripts, and the "which one am I in?" moment every time you switch. Move
when it is safe, fork only when there is a reason (a chosen workspace, dirty
edits).

Why not simply always move? Because `repinWorkspace`'s immutability rule is
load-bearing: a chosen workspace is how a resume resolves paths exactly as the
original turns did, and a dirty tree means the work already exists somewhere
that is not the new tree.

### 5.2 Moment 2 — the working loop

This is where the two verbs earn their keep. Today (6+ steps, a human in another
window):

```
agent: bash "git worktree add ../repo-feat -b feat"   (approval)
agent: "please /roots add ../repo-feat"               (human, another window)
agent: bash "cd ../repo-feat && ..."                  (works: bash's cwd claim
                                                       is wrong, but unguarded)
agent: edit ../repo-feat/src/x.nim                    (refused until the grant)
… human /roots remove …                               (cleanup nobody remembers)
```

After this proposal (2 steps, no human window):

```
agent: git_worktree {op: "add", branch: "feat"}       (approval; human sees
                                                       layout, path, lock)
agent: edit "../repo.wt/feat/src/x.nim"               (works: the set is live)
```

With `/worktree add` the first line is already done, so the agent simply works.
Inside the tree, everything else is unchanged: `read`, `edit`, `bash`, the
sandbox policy, the undo ledger — all scoped to *this* checkout, and the primary
stays readable (compare, diff, search) but not writable when
`isolation: "worktree"` is on.

Starting the client inside the tree instead (`cd ~/repo.wt/feature &&
niffler-tui`) reaches the same place with no commands at all; §4.6 lists exactly
which parts of that already work today and which three do not.

Note the asymmetry that makes this worth doing: **reading** the primary is how
you compare branches, so it stays; **writing** it is what a worktree exists to
prevent, so `isolation: "worktree"` closes exactly that half (§9 Q6).

### 5.3 Moment 3 — "merge it back and clean up"

Today (~8 bash rounds, no preview, an unclaimed write into the primary):

```
agent: bash "cd ../repo && git log --oneline feat"
agent: bash "cd ../repo && git diff main...feat"
agent: bash "cd ../repo && git status"                (dirty? find out)
agent: bash "cd ../repo && git merge feat"            (conflicts? find out)
agent: bash "cd ../repo && git status"                (which files conflicted)
… resolve, commit, merge --continue …                 (and a stray .gitignore)
```

After this proposal, `/worktree merge` is the whole ritual:

```
preview:  git_merge_preview              → {clean: true, ahead: 3, behind: 1, files: 12}
          (a one-line sentence to the human, no approval needed — it writes nothing)
commit:   git_commit {message: "…"}      → {commit: "9cba035", files: 4}
merge:    git_merge {op: "start"}        → {merged: true, head: "…", files: 12}
cleanup:  git_worktree {op: "remove", delete_branch: true}
```

and in the conflict case the preview says so *before* anything is touched:

```
→ {clean: false, conflicts: ["src/x.nim", "docs/y.md"], next: "resolve then commit"}
```

The rules that make this safe, and what the refusals say:

- **Preview first, always.** `git_merge_preview` is a read (`merge-tree`), so it
  needs no approval and the model may call it freely. The human sees the shape of
  the change and the conflict list before authorising a write into the primary.
- **`repo` defaults to the primary.** In a conversation whose workspace is a
  linked worktree, "merge this branch back" is what you mean; making the model
  name the primary path is the step that gets skipped and merges into the wrong
  tree.
- **The merge is a claimed write into the primary** (`paths: ["repo"]`), so two
  merges into one primary serialize, and a *worktree* conversation merging home
  holds a lease over the tree it writes into.
- **Removal refuses on evidence, not vibes:** another live conversation is still
  pinned to the tree (the store ledger — the fact git cannot know), or the
  branch is not merged into its base. A dirty tree is refused by git itself and
  that message is surfaced verbatim. Each refusal names the flag that overrides
  it (`force`, `delete_branch`).
- **The conversation is not deleted, and not repinned.** After `remove` it is
  *detached*: its transcript is the review record, and `session_info` says the
  tree is gone rather than silently refusing every write. Continuing the work is
  a new conversation in the primary, or a `recreate` of the tree — never an
  automatic move (§7).
- **Nothing cleans up implicitly.** No `prune` at end of turn, no removal when a
  child settles, no merge because the branch "looks done" (§7).

### 5.3b Returning to the parent afterwards

The merge does not end the story, because the merge is not the end of the work:
the branch still has to be pushed, a PR opened, reviewers answered, a release cut.
The natural question is *"and now I go back to the conversation I came from?"* —
so the answer has to be designed, not left to luck.

**Today (no new machinery): yes, `/session`.** The client's session browser
switches conversations and rebuilds the transcript from the store
(`switchSessionWithHistory` + `bootstrapBackendCmd`), so picking the parent puts
you back in exactly the conversation you left, with its own workspace still
pinned. Nothing about the fork changed the parent: no messages were added to it
by the fork, and its workspace is still the primary.

What is missing is *why you would know to do that*: the parent has no record that
a fork exists, so its transcript reads as if you simply stopped mid-thought.

**In 0.6.0, three things make the loop whole:**

1. **The fork is recorded in the parent.** `sessionmeta.origin` is written on the
   child (`{session, atSeq, reason: "worktree", worktree: {path, branch,
   primary}}`) and the parent's `session_info` lists its `descendants`, so
   "what came of this?" is one call from the conversation that started it. The
   client shows it in the session list, the way it already shows lineage.
2. **The merge settles into the parent's notice lane.** `git_merge` appends a
   durable `worktreemerge` notice to the **origin** conversation once the merge
   lands (`{worktree, branch, commit, files, into}`). That lane already exists and
   already drains at the top of every turn — `drainNotices` folds
   `agent_notices`, `process_notices` and `fleet_notices` into history, marked as
   runtime machinery rather than something the user said. So the parent does not
   poll and does not need a new mechanism: when you return (or when it next runs
   a turn), the first thing it sees is *"the worktree `fix-race` was merged into
   `main` as `9cba035` (4 files)"* — with the commit id, which is what a push or
   a PR needs next. Delivery is push-or-pull, deduplicated against canonical
   history, exactly like a fleet settlement.
3. **`/worktree close` returns you to the origin deliberately.** One command
   that (a) refuses while the branch is unmerged or dirty, (b) removes the tree,
   and (c) *switches the client back to the origin conversation* and says what it
   did — `merged into main as 9cba035; back in conv-abc123 (the conversation that
   started this)`. It is a client-side convenience over `/session` plus the
   facts above, and it exists so the ritual has one closing key instead of "now
   remember which conversation this came from".

Two deliberate non-goals: the parent never gets the child's *transcript* (that is
what `/session` and the `origin` link are for — copying it in would double the
history in one conversation), and the parent's workspace is never repinned by a
merge (a merge is a write into the primary, not a move, §7).

### 5.4 How conversations relate to each other

They already relate, and the records exist — but they encode the wrong thing
for this workflow. Today `agent_spawn {fork: true}` writes BOTH
`sessionmeta.parent = <caller>` and `sessionmeta.fork = {source, uptoId,
copied}` (verified, `components/agent/main.nim:635`), and `session_info` reports
the `fork` block. That is nearly what §5.1's FORK needs, with one consequence to
accept or change: `parent` means **supervision** — the child may not spawn its
own children (`NIF_AGENT_MAX_DEPTH`), its approvals route to the original
caller, and its runner retires when idle — whereas a worktree fork is a *peer*:
the same piece of work, in its own tree, which you keep talking to as your main
thread.

So the proposal is to name the distinction rather than invent a new relation:

| Edge | Meaning | Authority | Used by |
|---|---|---|---|
| `parent` | supervision: this conversation was spawned to do a job for another | depth rules, approvals route up, idle retirement | `agent_spawn`/`fleet_task_submit` (unchanged) |
| `origin` | provenance: this conversation's history was seeded from another | **none** — it is a peer, so it may spawn its own children and its approvals stay with its own client | a fork (new); `agent_spawn {fork}` records it too, alongside the `parent` it already has |

The mechanism, deliberately small: `sessionmeta.origin = {session, atSeq,
reason: "worktree"|"fork", worktree: {path, branch, primary}}`, written at birth
and never rewritten. A supervised fork (`agent_spawn {fork: true}`) carries BOTH
edges — `parent` for supervision, `origin` for provenance — which is the honest
description of what it already is; a worktree fork carries only `origin`, because
nothing is supervising it. One new key, no duplicate relation, and
`source`/`uptoId`/`copied` stay where they are in the existing `fork` block.

Both directions are then answerable, which is what makes the experience coherent:

- **Forward:** `session_info` in the fork reports *"seeded from conv-abc123 at
  message 84; working tree ../repo.wt/fix-flaky-test (branch fix-flaky-test,
  primary ~/repo)"*. That is one call, and it is what lets the model reason about
  which tree it is in without guessing from paths.
- **Backward:** the origin's `session_info` lists `descendants` — today a
  `children` count derived from `sessionmeta.parent`
  (`core/dispatch.nim:1009`), extended to also count records whose
  `origin.session` names this conversation — so "what came out of this
  exploration?" is answerable, and the client's session list can show a `⧉`
  marker with the origin, the way it already shows lineage.
- **Across a merge:** the merge receipt (`commit`, `files`, `into`, `from`)
  lands in the worktree conversation's history, so the pair (exploration → fork →
  merge) is a readable trail rather than three unrelated transcripts. A future
  `activity_list` row can point at the merge commit for the origin conversation
  too, which is the honest version of "linked".

What is deliberately *not* proposed: a shared mutable context between linked
conversations, or one conversation with several workspaces. Both would put a
changing list into the request prefix (the frozen-prompt invariant) and neither
answers a question a human actually asks.

### 5.5 What the human sees

One command, one line of feedback, and a status block that answers "where am I".

```
/worktree                    → repo: ~/repo (main, clean)
                               trees: ../repo.wt/fix-flaky-test (branch
                               fix-flaky-test, mine, dirty: 2 files, ahead 1)
                               this conversation: ../repo.wt/fix-flaky-test
                               origin: conv-abc123 (84 msgs)
/worktree add <name>         → created + moved|forked (says which, see §5.1)
                               (`new` stays as an alias — `add` is the verb
                               that matches git and `git_worktree {op: "add"}`)
/worktree merge              → preview line, then y/N over the merge, then a
                               notice to the origin conversation (§5.3b)
/worktree rm <name>          → guarded removal, names what blocks it
/worktree close              → remove if unmerged/dirty-free, then switch back
                               to the origin (says the commit it landed as)
```

It exists so that the "eight bash rounds" become one visible sentence and one
approval, and so the human's ritual has a single key. The model gets the same
information as `session_info.workspace` (a tool result, never prompt text), so
it never has to discover the layout by hitting a refusal.

## 6. Invariant checklist (what this proposal is *not* allowed to break)

| Invariant | How this proposal keeps it |
|---|---|
| Frozen prefix byte-stable | Nothing added to the system prompt: the worktree shape lives in `__workspace` (private, post-message), `session_info` (tool result), and `ev.worktree.changed` (event). The one prompt-visible thing that exists today — systemprompt's `<workspace>` tail — is unchanged, and its content depends on `cwd != root`, not on the set. |
| History append-only | Every worktree fact arrives as a tool result or an appended user/notice message. No splice, no rewrite. |
| No silent escalation | Discovered trees were already admitted by shipped code; this stops pretending otherwise — the creation becomes an approved, recorded act (§4.3) — and adds `isolation: "worktree"` as an opt-in **restriction**. `roots` grants stay human-only, so the model still cannot widen scope through the control channel. The one new scope-changing action the model *can* take (`worktree_add`) is `approval: "always"`, so it is a human's yes, not the model's decision. The move/fork in §5.1 is a client command (`/worktree add`), not a model tool — and `close`'s switch-back only changes which conversation the CLIENT is showing, never a workspace. |
| `x-harness.writes` claims are real | `git_worktree`/`git_merge`/`git_commit` name `repo` as a claimed path (the tree the write lands in), and the opaque-claim fix closes the cross-root hole that exists today. |
| Nothing about a write-only tool is silent | Every new verb is `approval: "always"` and records what it did (a store doc, or a commit/merge receipt in the result). `worktree_add` is the one place where an approved write also **widens** what later calls reach — stated plainly rather than hidden: the widening is the human's approved act, it is recorded, and `isolation: "worktree"` is the control that refuses it. |
| Component-local concurrency | All new verbs are serial handlers in one process; worktree creation is a shell-out, not a thread. |
| Language-agnostic core | Nothing per-language; `sdk/checkout.nim` is git, not language. |
| Absence is not failure | No `git` binary → `checkout.kind = ckNone` → today's behaviour (set = primary). No store → no ledger, verbs still work. |
| One tool per fact | git owns git shape; core owns the set and the fence; the client invents nothing (it reports what core said). |

## 7. Where worktrees must *not* leak

Worth writing down, because each is a plausible "helpful" change that would
undo the above:

- **No automatic conversation move on merge.** "Merge done → also repin the
  conversation to the primary" would violate the immutability rule and rewrite
  a chosen workspace. A merge is a write into another root; continuing in the
  primary is a new conversation. (The one move that IS automatic is §5.1's, and
  it happens *before* any turn in the new tree: a pristine or never-chosen
  workspace, which `repinWorkspace` already permits. Never after a merge, never
  once a workspace was chosen.)
- **No worktree per conversation by default.** Allocation stays explicit
  (`worktree_add`, or `agent_spawn {isolation: "worktree"}`, or a fleet task
  asking for one). The evidence for defaulting exists in `OPENHANDS.md` §3.15
  and is not yet strong enough to pay for GC, disk and a directory nobody asked
  for.
- **No tree list in the prompt.** Tempting ("tell the model about every
  worktree"), and it would change the prefix on every `worktree add`.
- **No hooks that silently `git worktree prune`.** A removed tree's record is
  a decision; the sweep should report, not delete (`worktree {op: prune}` is
  approval-gated for the same reason).
- **`worktree remove` never runs implicitly** at end of turn, on `session
  close`, or on `agent` child settlement: the tree is where the work is, and a
  child that settles must leave its tree for review.

## 7.5 Implementation readiness (audited 2026-10-30, before any code)

Written because "is the plan ready?" deserves a checkable answer rather than an
impression. Five questions an implementer hits on day one were re-verified
against the code and against git; every one of them changed the plan above.

**Verdict: the design is ready — the shape, the invariants and the slice order
hold up — but four previously-unstated details had to be settled first, and one
of them (`repo` required on `git_merge`) is a decision, not a detail. Slices 0–2
are ready to start today; slices 3–4 needed the fixes recorded below; slices 5–7
have three open sub-questions (bottom of this section) that block only their own
slice.**

| Question the implementer will hit on day one | Answer found | Where it lands |
|---|---|---|
| Does `git` component code have a session id and store access for the ledger? | **Session yes, store unused.** The macro sets `comp.sessionContext`, `git/main.nim:76` binds `comp`, so a plain proc can do both (compile-checked) — but no `git` tool declares `sessionId` today, and the component has never written a store doc | §4.3 step 3; slice 3 costed |
| Does the claim follow a *defaulted* argument? | **No** — `applyWorkspace` runs before the gate, but a component-side default is invisible to it. Measured: `git_merge {from}` claims the **worktree**, not the primary | §4.3: `repo` is **required** |
| Is "exit 1 = conflicts" true for `merge-tree`? | **No** — a bad ref also exits 1, with empty stdout; mapping it to a conflict list fabricates a conflict | §4.3 `merge-tree` trap |
| Is an mtime signature on `<commonDir>/worktrees` good enough? | **Only at sub-second precision** — two adds in one second share `st_mtime` seconds; and git deletes the directory when the last tree goes | §4.2(a) |
| Is `<repo>.wt/<name>` well-defined when the conversation is already in a tree? | **No** — the naive sibling gives `repo.wt/feat.wt/`, one deeper per hop | §4.3 step 1, orientation rule |

Two more findings that did **not** change the plan, recorded so they are not
re-litigated:

- **`git merge-tree --name-only` writes conflict paths to stdout on git 2.43**
  (`2>&1` not required), and the first stdout line is a tree OID in both the
  clean and conflicted cases — that OID is the discriminator the trap section
  relies on, so the check is cheap rather than heuristic.
- **`git worktree add` creates its container directory itself** (`repo.wt/` need
  not pre-exist), so `add` does not need a `mkdir` step — but it *does* need the
  collision refusal when `repo.wt/` already exists and was not ours (§4.3 step 1).

What is **not** yet decided, and blocks only the slices it touches:

1. **`/worktree new`'s move-vs-fork table: client or core?** Recommend
   **client** to start — the table is a pure function of `cwdPinned`, the
   transcript's turn count and the tree's dirtiness, and the two actions it picks
   between (`session {cwd}` and `agent_spawn {fork}`) are already core calls, so a
   client implementation ships without touching core and can move behind
   `/worktree` later if a second client needs it. Blocks slice 7 only.
2. **`isolation`: birth-only or mutable?** Recommend **mutable between calls**,
   on the `roots` precedent: it is not in the prompt, so changing it costs no
   cache rebuild, and a conversation that discovers it needs the primary (a
   dependency bump, a generated file) should not have to be recreated. Blocks
   slice 5's readback shape only.
3. **Does `session_info` list the conversation's trees?** Recommend **yes, as a
   `workspace.trees` array** (path, branch, mine, dirty, ahead/behind), because
   §4.2(c)'s promise is "one call answers where am I" and a model that must call a
   second tool for the sibling trees has not got that. Constraint this creates:
   `session_info` is a **core** tool (`core/dispatch.nim:969`), so it may not
   call the `git` component's tool `git_worktree_list`; the shape comes from
   `sdk/checkout.nim` (slice 0) plus `git status --porcelain` per tree, stays
   `effect: read`, and caches nothing. Two trees cost two `git` calls, so cap the
   list (the ledger's own entries first, then git's, bounded like
   `maxWorkspaceRoots`). Blocks slice 5.

None of the three blocks slices 0–2, which is why those remain the recommended
start — and none of them is a design risk: each already has a recommendation
above that the implementer can take as the default.

## 8. Slices, tests, effort

Each slice is independently shippable and testable; the order is the dependency
order.

| # | Slice | Touches | Test |
|---|---|---|---|
| 0 | ~~`sdk/checkout.nim` + three consumers~~ **SHIPPED** | sdk, core/workspace, systemprompt, lsp/roots | `t_workspaces` (checkout kind for clone/worktree/submodule/plain, `primaryRoot` from inside a worktree, `pathInRoots` boundary, `containingRoot`); `t_lsp` gains `treeRoot` (a worktree file resolves to the worktree, never the primary); `t_systemprompt` green on the delegated shadow rule |
| 1 | ~~live set: graph signature + `__workspace.primary/worktree`~~ **SHIPPED** (the `ev.worktree.changed` event is folded into slice 3, where the component that publishes it lives) | core/dispatch | `t_liveset`: `graphSignature` moves on add/remove/last-removed and distinguishes two trees created in the SAME second; `workspaceRootsFor` admits a tree created after the first dispatch with no grant and no restart, notices its removal, and caches the conversation's checkout shape |
| 2 | ~~opaque claim follows resolved cwd (+ `roots: true`)~~ **SHIPPED** | core/dispatch | `t_locks` pure (claim root per cwd: primary, worktree, deep-inside, outside-set fail-safe, same-prefix sibling, `roots: true`, empty set); `t_arbitration` (a worktree `bash` and a primary `bash` hold leases in parallel, while two writers in the SAME tree still collide) |
| 3 | ~~`git_worktree_list` + `git_worktree {add,remove,prune}` + layout + lock + store ledger + remove guards~~ **SHIPPED** | components/git | `t_git` (add lands a sibling that leaves `git status` clean with no ignore edit; orientation from INSIDE a worktree; collision/in-repo/nested refusals; unmerged-branch and primary refusals; force + branch-kept; prune of a hand-deleted tree; ledger owner in `list`) |
| 4 | ~~`git_merge_preview` + `git_merge {start,abort}` + `git_commit`~~ **SHIPPED** | components/git | `t_git` (clean preview with divergence counts, conflict preview naming files, **a bad ref is an error and never a conflict list**, required `repo`, clean merge, dirty-target refusal naming paths, commit staging only named paths while leaving an unrelated untracked file alone, nothing-to-commit as a normal answer) |
| 5 | `isolation: "worktree"` + `checkout` birth hint + `session_info.workspace` | core/conversation, core/dispatch, core/catalog | `t_roots` (isolation refuses the primary, grant escapes it), `t_controls` / `t_core_requests` (status readback) |
| 6 | peer `origin`: `sessionmeta.origin` (+ the `worktree` block), `session_info` forward+backward, `descendants`, depth/approval exemption for an origin-only fork, and the merge notice into the origin's `drainNotices` lane | components/agent, core/dispatch, components/git | `t_agentfork` (an origin-only fork is a peer, not a supervised child; a supervised fork keeps both edges), `t_core_requests` (descendants include forks; the merge notice reaches the origin), `t_git` (merge writes the notice) |
| 7 | client: the move-vs-fork decision (§5.1), `/worktree add` / `merge` / `rm` / `close` (with `close` switching back to the origin), chip, `/workspace` lines, nats-url fix | niffler-tui repo | its own Go tests (the decision table is pure and testable without a bus; `close` asserts the switch-back target) |
| 8 | docs: MANUAL ("Worktrees"), WIRE (`ev.worktree.changed`, `__workspace` fields, `isolation`, `checkout`, `sessionmeta.origin`, the merge notice kind), a refresh of [../WORKTREES-TUTORIAL.md](../WORKTREES-TUTORIAL.md) so Part 1 becomes Part 2, FEATURES, PLAN, then the zh/zh-TW refresh | docs | — |

The user's own ordering is worth respecting over the dependency order: slice 5
(one header key, one dispatch filter, one `session_info` block) is what makes
"I started in a worktree and Niffler understood" *feel* true, and slices 0–2 are
what make it *stay* true and be arbitrated. Slices 3–4 are the merge half; 7–8
are the surface, and 6 is the only slice that could be dropped without breaking
a §5 promise beyond "the fork is supervised like a subagent".

Effort, honestly: 0 ≈ 1 day, 1 ≈ 1 day, 2 ≈ ½ day, 3 ≈ 2½–3 days (it now carries
the component's first stateful surface, the ledger's store-down fallback and the
orientation rule — §4.3 steps 1 and 3), 4 ≈ 1–2 days, 5 ≈ 1 day, 6 ≈ 1 day,
7 ≈ 1–2 days (the decision table plus four subcommands), 8 ≈ 1 day. Slices 0–2
are ~2½ days and remove F1 and the arbitration hole on their own — worth doing
even if nothing else lands. Slices 3–5 plus 7 are what the "friction-free" claim
actually rests on.

## 9. Open questions, with a recommendation each

1. **Layout: inside the repo or sibling?** **Decided 2026-10-30: sibling,
   `<repo>.wt/<name>`, always.** The earlier recommendation here was the in-repo
   `<repo>/.niffler/wt/<name>`, on the argument that the claim, the ignore rule
   and hidden-dir skipping "come out right for free". That argument is wrong on
   the first of its three points and moot on the other two: an in-repo worktree
   sits INSIDE the primary's opaque `bash` claim, so `overlaps` serializes every
   primary `bash` against every worktree write (the opposite of the goal), while
   a sibling needs no ignore rule and no hidden-dir rule because it is not in the
   tree. See §4.3 step 1 for the full reasoning, the `repo.wt` limits (shared
   object store, name collisions, discovery pressure) and why convention
   detection (`git config niffler.worktreeDir`, an existing `.worktrees/`) was
   dropped: one rule everywhere beats honouring a repo's local habit.
2. **Can the model create a worktree?** Recommend yes, with
   `approval: "always"`. It is a filesystem write with a human in the loop, it
   leaves a store record, and refusing it just moves the friction to bash,
   where it is *worse* (no lock, no ignore rule, no ledger). The human's
   approval of the creation is the authority; the record is the audit.
3. **`maxWorkspaceRoots = 8`.** One primary plus seven trees, and past that a
   worktree silently stops being admitted (`addWorkspaceRoot` refuses with a
   message nobody sees on the discovery path). Recommend raising the discovery
   cap to 32 while keeping the *grant* cap at 7 — the two are different things
   (a scope list vs. a human decision) and today they share one constant.
4. **Merge strategy default.** Recommend `--no-ff` (the branch stays visible as
   a merge commit, which is what `git_worktree`/`git_merge` want to be able to
   point at), with `--ff` and `--squash` selectable per call. Squash loses the
   per-commit story a review receipt would cite; ff loses the fact that a
   worktree was used at all.
5. **Does `git_worktree {op: remove}` delete the branch?** Recommend only when
   `delete_branch: true` **and** `git branch --merged <into>` proves it is
   contained, with the containment check in the refusal text. Deleting a branch
   is the one irreversible thing in the flow.
6. **Should a worktree conversation auto-*read* the primary?** Recommend yes.
   `isolation: "worktree"` narrows the **claim** set only; `read`/`grep`/
   `git_diff` against the primary are how you compare branches, and refusing them
   makes the tree a cage. `__workspace.roots` deliberately keeps the full set for
   components that *accept* work (`lsp` indexes a primary file under its own
   root). If a future sandbox needs read confinement too, that is the
   conversation-policy work in `SANDBOX-CONVERSATION-POLICY.md`, not this.
7. **Do we still need the `.gitignore` advice in `using-git-worktrees`?** Yes —
   for humans and for harnesses that do not have this. But the harness should
   stop *needing* it (that is F3), and the skill's Step 1b "default to
   `.worktrees/` at the project root" now disagrees with the layout used here
   (`<repo>.wt/<name>`, a sibling). Recommend updating the skill to name the
   sibling as the default for harness-driven worktrees, since the in-repo
   placement is what makes the primary's opaque `bash` claim swallow every
   worktree.
8. **Discovered trees vs. "only a human adds a root" — which document wins?**
   `SANDBOX-CONVERSATION-POLICY.md` says a discovered worktree must not add a
   root; `computeWorkspaceRoots` has added them since worktree awareness
   shipped, and the fence honours the set. Both cannot be true. Recommend
   keeping the shipped behaviour (it is what makes "start in a worktree and it
   just works" true) and **amending the policy sentence**, with `isolation:
   "worktree"` as the narrowing control — rather than removing discovery, which
   would put every fresh worktree conversation back into F1/F2. What must not
   happen is the current state: a doc stating a rule the code contradicts, which
   is how an operator ends up trusting a fence that is not there.

## 10. Relationship to the 0.6.0 plan (`docs/PLAN.md` pillar 2)

`docs/PLAN.md` adopts this document as the substrate for worktrees in 0.6.0 and
adds four requirements the other pillars need. Three need nothing from this
document beyond the outputs §4.1–§4.5 already define; two need a note, because
PLAN's wording is looser than the mechanisms.

- **"A claim is parallel-safe only when a REAL isolated worktree backs it … a
  second writer in the SAME worktree is refused before mutation"** was the
  original pillar-2 item 1. PLAN has since adopted this document's position: it
  is **rejected**, and `locks` keeps path striping ("disjoint stays parallel" is
  a stated design rule of the component, and its phase-1 acceptance test is "two
  sessions, different files of one repo: both succeed"). Serializing per tree
  would reverse that, and would have to take `tests/t_locks.nim`'s "disjoint
  claims proceed (striping must not serialize a whole repo)" / "different file,
  different session, both ok" and `WRITE-ARBITRATION.md` §A.4 phase 1's "two
  sessions, different files of one repo: both succeed" with it — a decision
  record, not an application. `isolation: "worktree"` (§4.5) therefore scopes
  *where a conversation may write*, it is not a mutex around a tree.
- **"A worktree child does not see the parent's uncommitted or committed work"**
  (pillar 2 item 3, language borrowed from OpenHands) is only half true, and the
  half that is false is the important one:
  - *uncommitted* — true, and mechanically: `git worktree add` starts from a
    **commit**; the parent's working-tree dirt stays in the parent. This is the
    property that makes a worktree lane safe.
  - *committed* — false for anything committed **before** the worktree was
    created: the new tree's HEAD is that commit, so the child sees all of it.
    Only work committed to the parent branch *after* the child's tree branched
    is invisible. That is desirable (the child starts from the parent's latest
    known good state, which is what "branch from here" means) but it must not be
    written as total isolation, because a child that believes it cannot see the
    parent's commits will re-derive what it already has.
  Stated as the rule the implementation should follow: a worktree child starts
  at the parent's **HEAD commit**, sees no uncommitted work, and never sees the
  parent's subsequent commits unless asked to (`git_merge`/`git_diff` against the
  parent branch, which the workspace set permits as *reads*).
- **Per-worktree state** (undo, repomap census, LSP roots, readscope,
  `__workspace`) is mostly already true by construction and worth verifying per
  path rather than changing: `edit` keys undo/seen by `session:absolute-path`, so
  two worktrees are two keys; `lsp` indexes per root; `repomap` caches by path.
  The one that is *not* automatic is **census cost**: a worktree is a second full
  tree, so a conversation in one may warm servers and build a map that another
  conversation already built for the same content. `__workspace.primary` (§4.2)
  is what lets those components decide — the proposal's job is to hand them the
  fact, not to guess for them.

Everything else in PLAN pillar 2 (fleet `isolation: worktree|shared` lanes,
sandbox writable roots derived from the resolved checkout, the gate) consumes
this proposal's outputs: `isolation` as a per-conversation key it can pass to a
child, `checkout.primaryRoot` as the one answer about where a tree's primary is,
and `__workspace` as the non-prefix context every component already reads.

### §8.0 Slice 0 — implementation notes (shipped 2026-11-01)

What the code does now, and the two findings that changed it while building.

- **`sdk/checkout.nim`** (new, std-only): `checkoutShape(dir)` → `Checkout{kind,
  root, gitDir, commonDir, primaryRoot, branch, superproject}`;
  `worktrees(dir)` → parsed `git worktree list --porcelain` (locked reason,
  prunable, bare, detached); `pathInRoots`/`containingRoot` for workspace-set
  membership; `gitQuery`/`gitLines` shared best-effort helpers.
- **`core/workspace.nim`** now delegates: `normalizeRoot` re-exported,
  `pathInWorkspace` → `pathInRoots`, and the porcelain re-split replaced by
  `worktrees()`. Public surface unchanged, so no call site moved.
- **`components/systemprompt`**: the hand-rolled `.git`-file parse is gone; the
  shadow rule asks `checkoutShape(root).kind == ckLinkedWorktree` and uses
  `primaryRoot`.
- **`components/lsp/roots.nim`**: `normalizeRoot` re-exported; new `treeRoot`
  (git decides the TREE, language markers decide the project dir *inside* it)
  replaces `deriveRootUnbounded` at the out-of-workspace call site. Imported
  bare (`import checkout`) because `sdk/checkout.nim` is std-only — that module
  must stay bus-free or `t_lsp`'s hermetic section would drag NATS in.
- **Finding 1 — the submodule folklore is wrong on git 2.43.** The plan said a
  submodule has `gitDir != commonDir` and therefore needs the superproject
  guard. Measured: a submodule reports `git-dir == common-dir ==
  .git/modules/<name>`, so it looks exactly like a plain clone. Classification
  now decides `ckSubmodule` from `--show-superproject-working-tree` FIRST, and
  the dir comparison only distinguishes clone from linked worktree. The guard
  is kept as defence (an older git, or an exported `GIT_DIR`, can report the
  pair differently — both re-measured), and `t_workspaces` asserts it.
- **Finding 2 — `primaryRoot` is uniform, not "empty for the primary".** The
  first version returned "" for a plain clone, which forced every caller to
  special-case "am I already the primary?" — the same question `kind` already
  answers. It now always answers the parent of `…/.git`; callers branch on
  `kind`. `t_workspaces` asserts both directions.

### §8.1 Slice 1 — implementation notes (shipped 2026-11-02)

- **`graphSignature(primary)`** (`core/dispatch.nim`): `shape.commonDir` plus
  the nanosecond mtime of `<commonDir>/worktrees`, or the literal `absent` when
  git has removed it, or `nodir` outside a repository. One `stat` per dispatch.
- **`workspaceRootsFor`** now rebuilds on `rootsKey != key OR graphSig != sig`
  — two independent conditions, because a grant must rebuild when the graph is
  unchanged and a new tree must rebuild when nothing was granted.
- **`__workspace`** gains `primary` and `worktree {linked, branch, primaryRoot,
  submodule}` alongside the untouched `root`/`roots`, fed from
  `NestedState.checkoutCached` (computed with the set, so one staleness rule).
- **`ev.worktree.changed` is not in this slice.** It belongs with the component
  that publishes it (`git_worktree`, slice 3); the signature makes the event an
  optimisation rather than the mechanism, so a worktree made by bash or by hand
  in another terminal is picked up either way. Worth stating because the plan
  originally listed it here.

Two measurement corrections that changed the design, both now asserted:

- **`st_size` is not a backstop.** The plan proposed `size` in the signature as
  protection against coarse timestamps. Measured across adds and removes, the
  directory's `st_size` stayed **4096** — it reflects the inode, not the entry
  count. mtime alone carries the signal; `size` was dropped rather than left in
  as false comfort.
- **The e2e test had to be rewritten, and the reason is a lesson.** The first
  version created a real worktree mid-conversation and asked the `locks`
  component to admit a write — but it passed `roots` explicitly in the request,
  so `locks` never consulted the conversation's cached set and the test PASSED
  with the bug restored. A test that cannot fail is worse than no test. It now
  drives `workspaceRootsFor` on a real `CoreTools`, which is the actual cache.

Both mechanisms were verified by reverting each in turn:
reverting the cache condition produces 4 failures ("the next dispatch sees the
new tree WITHOUT a grant or restart — set = @[primary]"), and coarsening the
signature to whole seconds produces 2 ("a SECOND worktree in the same second is
still a new signature"). The second one is the sub-second trap the plan
predicted, now demonstrated rather than assumed.

### §8.2 Slice 2 — implementation notes (shipped 2026-11-02)

- **`opaqueClaimRoot(args, wsPolicy, roots, primary)`** (`core/dispatch.nim`):
  the workspace-set root containing the resolved `cwdField`, deepest match
  wins, else the primary. Used for both opaque spellings (`writes.root: true`
  and an undeclared tool) and as the fallback for a path-bound declaration that
  matched nothing. Cost is a normalized string comparison over the
  already-cached set — no stat, no git.
- **`writes: {"roots": true}`** claims every root. Nothing shipped needs it; it
  exists so "I touch every tree" is a statement rather than the accident an
  omitted declaration used to be.
- **The call site passes the set** (`workspaceRootsFor(ct)`) into
  `writePathsFor`, which is what makes the cwd resolvable against roots at all.

Two things worth recording:

- **A wrong-field bug the tests caught immediately.** My first version looked
  for `cwdField` directly under `x-harness`; it is declared under
  `x-harness.workspace` (the same node `applyWorkspace` reads). Three pure
  checks failed with `@["/home/me/repo"]` where a worktree was expected. The
  tests found it in one run — this is the case for writing the pure checks
  before wiring the call site.
- **The fail-safe direction is deliberate.** A cwd outside every root, an
  absent `cwdField`, or an empty cached set all keep the coarse primary claim,
  exactly as before. An oversized claim serializes too much; claiming nothing
  guards nothing, which is strictly worse. Stated in the code so a future
  reader does not "fix" it into a no-claim.

Note on what the e2e test does and does not prove: `t_arbitration` now shows a
worktree `bash` and a primary `bash` holding leases in PARALLEL while two
writers in the same tree still collide. That is the arbitration outcome, at the
locks contract level. The gate's own choice of root is covered by `t_locks`'
pure checks, because a scripted turn cannot vary NIF_ROOT from the workspace in
that sandbox — the same limitation the harness-state section above documents.

### §8.3 Slice 3 — implementation notes (shipped 2026-11-02)

Two tools added to `components/git`, both `onDemand`: `git_worktree_list`
(read, no prompt) and `git_worktree {add, remove, prune}` (write,
`approval: "always"`, `sessionId: true`, claiming `paths: ["repo", "path"]`).
The mutation surface is gated by a declared setting (domain `git.mutations`,
env fallback `NIF_GIT_MUTATIONS`, `application: component restart`); off means
the verbs, the owner tool and the declaration are never registered.

**Three bugs the tests found, each a real one:**

1. **`git worktree prune` skips LOCKED trees.** Measured: with a locked tree
   whose directory was deleted, `prune -v` exits 0 and leaves the record. Since
   `add` locks every tree it creates, prune could never clean up one of ours —
   the exact case it exists for. `prune` now unlocks records whose directory is
   GONE and then prunes; a live tree keeps its lock, so prune still cannot touch
   work that is really there.
2. **`remove` had to unlock before removing.** git refuses to remove a locked
   tree without `-f -f`, and passing `-f -f` unconditionally would also bulldoze
   a DIRTY tree that git refuses on purpose. It now unlocks explicitly (we are
   past the ownership guard, so the lock is ours to drop) and removes with only
   the force the caller asked for — so a dirty tree's refusal is still surfaced
   verbatim.
3. **The lock reason was parsed by slicing a fixed prefix.** The reason is
   `niffler <action> (<branch>) — conversation <id>`, so the marker's offset
   varies with the branch name; slicing produced `tree (feat) — conversation x`
   and then named a conversation that does not exist. It now searches for the
   marker. `"unknown"` (what `add` writes when no session was injected, e.g.
   from `cli`) is explicitly NOT treated as an owner to protect — otherwise
   every scripted call is blocked by a phantom.

**A test lesson worth keeping:** the liveness probe was wrong twice. `catalog
{op: components}` never lists a component started with no spawn record, and
`waitRegistered` only watches announcements that arrive AFTER it subscribes — a
component that has already booted races both. It now probes functionally (does
the read verb answer?), which is what the check actually meant.

**Deliberate choices, stated so they are not "fixed" later:**

- `add` refuses a `path` outside `<primary>.wt/`, and refuses a path inside an
  existing worktree. Both are the layout's whole point: an in-repo tree sits
  inside the primary's opaque claim and serializes every write.
- `remove` keeps the branch unless `delete_branch` is set. Removing a tree and
  discarding its commits are different decisions.
- The ledger write is NOT fatal: the tree is created and git-locked (the
  durable half, naming the conversation in its reason), the result reports the
  ledger miss, and `remove` falls back to the lock reason. Failing closed would
  cost a conversation the ability to start work over a metadata write.
- The ledger is read with `storeListAll`, not `storeList`: a single list is a
  PAGE, and a truncated view would report an owned tree as unowned — the one
  answer this must never give.

### §8.4 Slice 4 — implementation notes (shipped 2026-11-02)

Three tools in `components/git`, alongside the worktree verbs and behind the
same `git.mutations` gate: `git_merge_preview` (read, no prompt), `git_merge
{start,abort}` and `git_commit` (write, `approval: "always"`, claiming
`paths: ["repo", "paths"]`).

**The exit-1 trap, re-measured before implementing.** `git merge-tree
--write-tree --name-only` exits 1 for BOTH a real conflict and a ref that does
not exist. Measured on git 2.43 here: a conflict prints the tree OID, the paths
and the `CONFLICT` lines on stdout; a bad ref prints NOTHING on stdout and
`merge-tree: <ref> - not something we can merge` on stderr. So
`mergeTreeVerdict` requires a POSITIVE discriminator — the first output line
must be a 40/64-hex tree OID — before it will claim a conflict, and otherwise
returns an error carrying git's own message. `t_git` pins it: a preview against
`nosuchbranch` must be an error naming the ref and must carry no `conflicts`
array. Verified load bearing by reverting to `exit 1 → conflict`, which reports
the bad ref as a *clean merge* (the OID check is what saves it) — a worse lie
than a fabricated conflict list.

**`runGit` combines stderr into stdout** (`runCmd` wraps with `2>&1`), so the
streams cannot be told apart. The discriminator is therefore the CONTENT, which
separates cleanly: a bad ref's first line is prose, a conflict's is hex.

**`repo` is REQUIRED on all three**, not defaulted. `writePathsFor` derives the
claim from ARGUMENT VALUES, so a component-side default would take the lease
over one tree and write another — the F4 hole, measured in §4.3. The refusal
names the tree it thinks you meant (the primary, when you are in a worktree), so
the next call is unambiguous.

**Findings from the tests, each a real one:**

- `merge` requires the target branch to be CHECKED OUT; passing `into: main`
  while `feat` is checked out is refused with the actual branch named rather
  than silently retargeted. (My first test did exactly this and "failed" for a
  correct reason.)
- `commit` with neither `paths` nor `all` stages tracked modifications only
  (`git add -u`), so an unrelated UNTRACKED file is not swept in — asserted,
  because that is the verb's whole advantage over `bash git commit -a`.
- git phrases "nothing to commit" several ways ("nothing to commit", "nothing
  added to commit but untracked files present"); all are normal answers now,
  not crashes.
- a `nil` JsonNode indexed with `{"conflicts"}` is a SIGSEGV, not a false — the
  bad-ref assertions inspect the node's kind first.
