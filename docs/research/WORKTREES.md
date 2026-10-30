# WORKTREES — making Niffler worktree-aware

> Status: **proposal, nothing implemented.** Basis: local `main` at `v0.5.0`
> (`6f95a20`). Every claim about current behaviour below was read from the code
> at that commit, and every claim about git was measured on git 2.43 in a
> throwaway repo — where the two disagreed, the measurement wins and the note
> says so.

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

**F3 — the friction is not just the grant, it is the location.** A worktree
created as a sibling (`git worktree add ../repo-feat`) lands outside every root
in the set → F1/F2 apply. A worktree created *inside* the repo lands inside a
root, so the fence is happy — but now the checkout contains a second full copy
of the tree, and `git status` in the primary goes dirty:

```
?? .niffler/          # or .worktrees/ — a worktree inside the repo is untracked
```

The skill that documents this workflow — `using-git-worktrees`, an
operator-installed skill (`~/.niffler/skills/…`), not shipped in this repo —
answers with "verify the directory is ignored before creating the worktree", so
the agent's first act in a fresh repo is an edit to `.gitignore`: a stray,
committed, unrelated change in the user's repo. That is the friction that
actually gets noticed, and it is pure mechanics, not policy.

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
graph changed, reviewable without a merge (`git_merge {op: "preview"}`),
mergeable as an *ordinary claimed write into the primary*
(`git_merge {op: "start"}`), and removable only when nothing is pinned to it.
The sibling placement is load-bearing for arbitration, not cosmetic: two claim
sets on disjoint paths are the only way two sessions can work in parallel (see
§4.3 step 1). The conversation stays pinned to its tree — the merge is a write, not a
move — and an optional
`isolation: "worktree"` scope makes the tree a *fence* rather than a
convenience, which is what finally makes "my checkout of main cannot be touched
by this conversation" true.

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
  dispatch path. Measured caveat: git **removes** that directory when the last
  worktree goes, so absence is a signature value too, not an error. A full
  recompute (three git invocations) still happens only when the signature
  moves — the current cost profile is preserved for the ordinary case.
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
`workspace` block (root, roots, linked, branch, primaryRoot, and the merge
candidates below). It is a **tool result**, so it appends to history and never
touches the prefix — and it is the only way an agent learns "I am in a linked
worktree whose primary is X", which today it cannot learn at all.

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
| `add` | always | `paths: ["repo", "path"]` | creates `path` (default `<repo>.wt/<name>`, a sibling of `repo`), branch from `base` (default the repo's current branch), then **writes the store record and locks the tree**. No ignore rule is needed for the sibling layout. `repo` is claimed because `add` also writes git metadata (`<commonDir>/worktrees/<name>`, `refs/heads/<branch>`) |
| `remove` | always | `paths: ["repo", "path"]` | refuses when (i) another *live conversation* is pinned there (the ledger, which git cannot know), (ii) the branch is not merged into its base — each refusal names the flag that overrides it. A dirty tree is already refused by git itself (measured: exit 128, "contains modified or untracked files"); surface that message verbatim rather than re-implementing it. The `repo` in the claim is not decoration: removal deletes `<commonDir>/worktrees/<name>`, so it writes the repository's own git metadata |
| `prune` | always | `paths: ["repo"]` | `git worktree prune` for trees deleted out from under git |

`add` is where F3 dies, in three concrete steps, each verified:

1. **Layout.** `<repo>.wt/<name>` — a SIBLING of the repo, one shared
   container directory (`~/git/repo` → `~/git/repo.wt/feat`). **Revised
   2026-10-30 (owner decision): always the sibling, never in-repo, and no
   convention detection** — `git config niffler.worktreeDir` and the existing
   `.worktrees/` probe are both dropped. One rule everywhere is worth more than
   honouring a repo's local habit, and the probes bought nothing that the
   sibling does not already give.

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

#### `git_merge {op, repo?, into?, from?, strategy?, allow_dirty?}`

| op | approval | claim | notes |
|---|---|---|---|
| `preview` | no | none | **the missing verb.** `git merge-tree --write-tree --name-only <into> <from>`: exit 0 → `{clean: true, files: N, ahead, behind}`; exit 1 → `{clean: false, conflicts: [paths]}`. Plus `rev-list --left-right --count` for divergence and `git diff --stat into...from` for the shape of the change. |
| `start` | always | `paths: ["repo"]` | refuses up front when the target tree has local changes to a path the merge touches (the `preview` file list intersected with `git status --porcelain`), so the refusal names the paths instead of quoting git's abort; `allow_dirty: true` proceeds anyway. Then `git merge --no-ff --no-edit <from>` → `{merged: true, head, files}`. Unrelated dirt is allowed, which is git's own semantics |
| `abort` | always | `paths: ["repo"]` | `git merge --abort` — the honest answer to a conflict the model cannot resolve |

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
- `writes: {"roots": true}` — a new, explicit declaration for a tool that
  legitimately touches **every** root (a whole-repo formatter, a cross-tree
  build): claim them all. Nothing shipped needs it today; it exists so that
  "claim everything" is a statement, not an accident.

This is the fix that makes "the agent worked in a worktree and the primary was
never touched without a lease" true, and it costs one stat-free comparison.

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
  refuses a claim anywhere else (`[E_WRITE_OUTSIDE]`, naming the escape:
  `session {roots: {add: [...]}}` for a deliberate one-off, or `isolation:
  "shared"`). Without it a worktree conversation can edit the primary in place,
  which is the one thing a worktree is supposed to prevent.

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
(`niffler-tui` `tui/main.go:4012`), which inside a worktree is a path that does not exist.
Today it is masked because the wrapper always exports `NIF_NATS_URL`; the SDKs
resolve against the clone (`sdk/go/harness.go:ResolveNatsUrl`) and the client
should too.

### 4.7 The client surface itself (niffler-tui, separate repo)

Small, and mostly reading what core now reports:

- **Bottom row**: the `⧉` mark already exists; add `· isolated` when
  `isolation: "worktree"`, so the human can see that main is protected.
- **`/workspace`**: report `linked worktree of <primary> on <branch>`,
  `isolation: shared|worktree`, and the merge candidate (`<primary> ← <branch>`,
  ahead/behind) — a one-line preview, not a command.
- **`/worktree`** (new, mirrors `/roots`): bare = `git_worktree_list`
  readback (path, branch, whose tree, dirty?); `new <name>` = `op: add`;
  `rm <name>` = `op: remove`; `merge` = `preview` then a `y/N` over `start`.
  It exists so the "eight bash rounds" become one visible sentence and one
  approval, and so the human's ritual has a single key.

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
/worktree new fix-flaky-test
```

What it does, in order:

1. Creates `../repo.wt/fix-flaky-test` (sibling, branch from the current one),
   locks it, records it (§4.3).
2. Looks at the **conversation** and the **tree**, and picks one of two
   outcomes:

   | Conversation state | Tree state | Outcome |
   |---|---|---|
   | pristine, or unpinned (nobody ever chose a workspace) | clean | **MOVE** — the same conversation continues, now pinned to the worktree. `repinWorkspace` already allows exactly this case, and it costs no prompt-cache rebuild because the frozen prompt embeds the harness root, never the workspace path |
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

Why not simply always fork? Because a fork splits attention: two conversations,
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

With `/worktree new` the first line is already done, so the agent simply works.
Inside the tree, everything else is unchanged: `read`, `edit`, `bash`, the
sandbox policy, the undo ledger — all scoped to *this* checkout, and the primary
stays readable (compare, diff, search) but not writable when
`isolation: "worktree"` is on.

If you started the client inside the tree instead (`cd ~/repo.wt/feature &&
niffler-tui`), you get the same place with no commands at all:

```
$ cd ~/repo.wt/feature && niffler-tui
  today:  workspace = the worktree ✓, primary also writable ✓,
          branch shown with ⧉ ✓, model told nothing ✗,
          primary writable in place (no fence) ✗
  after:  same, plus isolation: "worktree" available so the primary is
          READable (compare/diff) but not writable, and session_info
          answers "linked worktree of ~/repo on feature" in one call
```

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
preview:  git_merge {op: "preview"}      → {clean: true, ahead: 3, behind: 1, files: 12}
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

- **Preview first, always.** `preview` is a read (`merge-tree`), so it needs no
  approval. The human sees the shape of the change and the conflict list before
  authorising a write into the primary.
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

### 5.4 How conversations relate to each other

They already relate; the shape just needs to be right for this workflow. Today
`sessionmeta.parent` records a **subagent** child (`agent_spawn`), which carries
supervision semantics: the child cannot spawn its own children, its approvals
route to the original caller, and its runner retires when idle. That is the
wrong relationship for "same piece of work, now in its own tree" — you keep
talking to that conversation as your main thread.

So the proposal splits the edge in two:

| Edge | Meaning | Authority | Used by |
|---|---|---|---|
| `parent` | supervision: this conversation was spawned to do a job for another | depth rules, approvals route up, idle retirement | `agent_spawn`/`fleet_task_submit` (unchanged) |
| `origin` | provenance: this conversation's history was seeded from another | **none** — it is a peer | the fork in §5.1 |

`sessionmeta` gains `origin: {session, atSeq, reason: "worktree"|"fork",
worktree: {path, branch, primary}}`, written at birth and never rewritten. Both
directions are then answerable, which is what makes the experience coherent:

- **Forward:** `session_info` in the fork reports *"seeded from conv-abc123 at
  message 84; working tree ../repo.wt/fix-flaky-test (branch fix-flaky-test,
  primary ~/repo)"*. That is one call, and it is what lets the model reason about
  which tree it is in without guessing from paths.
- **Backward:** the parent's `session_info` lists `descendants` (currently found
  via `sessionmeta.parent`; extended to `origin`), so "what came out of this
  exploration?" is answerable — and the client's session list can show a `⧉`
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
/worktree new <name>         → created + moved|forked (says which, see §5.1)
/worktree merge              → preview line, then y/N over the merge
/worktree rm <name>          → guarded removal, names what blocks it
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
| No silent escalation | Discovered trees were already admitted by shipped code; this stops pretending otherwise — the creation becomes an approved, recorded act (§4.3) — and adds `isolation: "worktree"` as an opt-in **restriction**. `roots` grants stay human-only, so the model still cannot widen scope through the control channel. |
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
  primary is a new conversation.
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

## 8. Slices, tests, effort

Each slice is independently shippable and testable; the order is the dependency
order.

| # | Slice | Touches | Test |
|---|---|---|---|
| 0 | `sdk/checkout.nim` + three consumers | sdk, core/workspace, systemprompt, lsp/roots | extend `t_workspaces` (worktree/submodule/superproject shapes, `primaryRoot` from inside a worktree); `t_lsp`, `t_systemprompt` stay green |
| 1 | live set: graph signature + `ev.worktree.changed` + `__workspace.primary/worktree` | core/dispatch, core/conversation, core/workspace | `t_workspaces` (pure) + a new `t_worktrees` (e2e, `newCoreSandbox` + `mock_llm` like `t_arbitration`: create mid-turn → next dispatch admits) |
| 2 | opaque claim follows resolved cwd (+ `roots: true`) | core/dispatch | `t_locks` (pure: claim root per cwd), `t_arbitration` (two roots, one lease) |
| 3 | `git_worktree` verbs + layout + lock + store ledger + remove guards | components/git, manifest | `t_git` (new ops against a throwaway repo, incl. "dirty/merged/live-pin refusals"; `add` lands the tree as a sibling and leaves `git status` clean with no ignore edit) |
| 4 | `git_merge` preview/start/abort + `git_commit` | components/git | `t_git` (clean, conflict-preview, dirty target, claim visible to `locks`) |
| 5 | `isolation: "worktree"` + `checkout` birth hint + `session_info.workspace` | core/conversation, core/dispatch, core/catalog | `t_roots` (isolation refuses the primary, grant escapes it), `t_controls` / `t_core_requests` (status readback) |
| 6 | client: chip, `/worktree`, `/workspace` lines, nats-url fix | niffler-tui repo | its own Go tests |
| 7 | docs: MANUAL ("Worktrees"), WIRE (`ev.worktree.changed`, `__workspace` fields, `isolation`, `checkout`), FEATURES, PLAN, then the zh/zh-TW refresh | docs | — |

The user's own ordering is worth respecting over the dependency order: slice 5
(one header key, one dispatch filter, one `session_info` block) is what makes
"I started in a worktree and Niffler understood" *feel* true, and slices 0–2 are
what make it *stay* true and be arbitrated. Slices 3–4 are the merge half; 6–7
are the surface.

Effort, honestly: 0 ≈ 1 day, 1 ≈ 1 day, 2 ≈ ½ day, 3 ≈ 2–3 days, 4 ≈ 1–2 days,
5 ≈ 1 day, 6 ≈ 1 day, 7 ≈ 1 day. Slices 0–2 are ~2½ days and remove F1 and the
arbitration hole on their own — worth doing even if nothing else lands.

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
6. **Should a worktree conversation auto-*read* the primary?** Recommend yes
   (`isolation: "worktree"` scopes the **fence** and `__workspace.roots`, but
   `read`/`grep`/`git_diff` against the primary are how you compare branches;
   refusing them makes the tree a cage). If a future sandbox needs read
   confinement too, that is the conversation-policy work in
   `SANDBOX-CONVERSATION-POLICY.md`, not this.
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
adds four requirements the other pillars need. Its item 1 has two halves: the
opaque-claim half is §4.4 here, the per-worktree-exclusivity half is **not** in
this proposal and contradicts a shipped design rule, so it should be settled
deliberately rather than inherited:

- **PLAN pillar 2 item 1**: "a claim is parallel-safe only when a REAL isolated
  worktree backs it … a second writer in the SAME worktree is refused before
  mutation."
  Today `locks` stripes by **path** and never by tree, on purpose — "disjoint
  stays parallel" is a stated design rule of the component
  (`components/locks/main.nim`, design rules) and the phase-1 acceptance test
  is "two sessions, different files of one repo: both succeed". A rule that
  serializes per worktree reverses that: two conversations in one tree would
  conflict even on unrelated files.
  That may still be the right call for 0.6.0 — the sandbox wants one
  unambiguous writable root, and per-tree serialization makes the fence a fence
  rather than a path filter — but it is a **policy change to `locks`**, not an
  application of this proposal: it needs its own decision record, and two
  shipped assertions would have to change with it — `tests/t_locks.nim`'s
  "disjoint claims proceed (striping must not serialize a whole repo)" /
  "different file, different session, both ok", and `WRITE-ARBITRATION.md` §A.4
  phase 1's "two sessions, different files of one repo: both succeed". Editing
  the component while leaving those in place is the failure mode AGENTS.md warns
  about: a green suite certifying the opposite of the component's rule. It is
  also *independent* of §4.4 — the cwd-following claim closes the wrong-tree
  hole without serializing inside a tree, so 0.6.0 can have the hole fixed
  without adopting exclusivity.
- **PLAN pillar 2 item 4** (per-worktree state for undo, repomap census, LSP
  roots, readscope, `__workspace`) is mostly already true by construction and
  worth verifying per path rather than changing: `edit` keys undo/seen by
  `session:absolute-path`, so two worktrees are two keys; `lsp` indexes per
  root; `repomap` caches by path. The one that is *not* automatic is the LSP and
  repomap **census cost**: a worktree is a second full tree, so a conversation
  in one may warm and map the same files twice. `__workspace.primary` (§4.2) is
  what lets those components decide — the proposal's job is to hand them the
  fact, not to guess for them.

Everything else in PLAN pillar 2 (fleet `isolation: worktree|shared` lanes,
sandbox writable roots derived from the resolved checkout, the gate) consumes
this proposal's outputs: `isolation` as a per-conversation key it can pass to a
child, `checkout.primaryRoot` as the one answer about where a tree's primary is,
and `__workspace` as the non-prefix context every component already reads.
