# Worktree acceptance — what the live run covers, and what needs a human

Two halves. The **harness half** is scripted and repeatable
(`scripts/worktree-acceptance.sh`). The **client half** needs a person at a
terminal, because the point of it is an approval prompt, a bottom-row chip and a
conversation switch.

Neither substitutes for `make test`: the bus-contract suite proves the logic
(`t_git`, `t_roots`, `t_locks`, `t_agentfork`), and this run proves the pieces
still fit together in a live harness with a real store and real approvals.

## Before you start: restart the harness

A running harness keeps executing the binary it **started** with. Every result
is meaningless against a stale core, and the failure mode is confusing — a tool
that exists in the source simply does not answer. The acceptance script refuses
to run in that state (`exit 3`, with the elapsed-time comparison), but do it
yourself and save the round trip:

```bash
make down-here && make build && ./var/bin/niffler &
```

## The harness half (scripted)

```bash
scripts/worktree-acceptance.sh --auto        # --auto permits the approval grant
scripts/worktree-acceptance.sh --auto --keep # keep the scratch repo to poke at
```

It builds a scratch repository under `mktemp -d` — **deliberately outside
`$NIF_ROOT`**: a sandbox inside the harness root sits within whichever
conversation owns that tree, and its opaque `bash` claim then blocks the run with
`[E_WRITE_BUSY]`. That is arbitration working correctly, against the test.

What it checks, in order:

| Step | Assertion |
|---|---|
| 1 | the scratch repo is clean and on `main` |
| 2 | the conversation is born in it; `approvals: auto` is an explicit opt-in |
| 3 | isolation starts as `shared` |
| 4 | `git_worktree add` reports a tree at `<repo>.wt/<name>`, the primary stays clean with **no ignore rule**, the component lists it, and it is **locked with a reason** |
| 5 | the conversation repins into the tree; `session_info.workspace` reports `linked`, `primaryRoot`, `branch` |
| 6 | **the fence**: a write to the primary is refused `[E_WRITE_OUTSIDE]` and writes nothing; a write inside its own tree succeeds |
| 7 | **reads are not narrowed**: the primary is still readable |
| 8 | `git_commit` in the tree returns a commit; `git_merge_preview` is clean; **a bad ref is an error, never a conflict list**; the merge lands |
| 9 | (noted, not asserted) this conversation was *moved*, so it has no origin and no notice is due |

It does **not** start a model turn on purpose: a turn can run for minutes and
leaves the runner answering `mid-turn` to every control call after it, which
turns the rest of the run into a timing test.

## The client half (a human, once per release)

Prerequisites: `niffler-tui` built and installed, a test repository that is
clean and on `main`, and the harness restarted as above.

**1. Move (pristine/unpinned → move)**

```
/worktree add try-isolation
```

Expect: `move → ../<repo>.wt/try-isolation (branch try-isolation)`, an approval
prompt you accept, then the bottom row showing `⧉ try-isolation · isolated`.

**2. The fence, from the model's side**

Ask the agent to *"create a file in the primary checkout"* → expect
`[E_WRITE_OUTSIDE]`. Then *"create a file here"* → expect success. This is the
same assertion as the script's step 6, but through the model rather than a
control call.

**3. Merge — see the refusal first**

```
/worktree merge
```

Before committing anything, expect a refusal (nothing to merge). Commit in the
tree, then merge. Expect the preview to be clean and the merge to land.

**4. Back to the origin**

```
/worktree close
```

Expect: the tree is removed, the branch is kept, and the client switches back to
the origin conversation. If the origin shows the merge notice with the commit
id, slice 6's durable lane is working end to end.

**5. Fork (chosen conversation → fork)**

Start a second conversation, send one message, then `/worktree add second`.
Expect **fork**, not move — the exploration stays its own record and the new
conversation has read it.

**6. Dirty tree → refuse, offer fork**

In the primary, edit a tracked file without committing, then `/worktree add
dirty`. Expect a refusal naming the paths and offering `--fork`.

### What each failure means

| Symptom | Most likely cause |
|---|---|
| `/worktree` is an unknown command | the client binary is stale — `make build install` in the tui repo |
| the approval prompt never appears | the control call did not carry the session; check `var/logs/git.log` for an `unknown` owner |
| `session_info.workspace` is absent | the harness core is stale (the binary was rebuilt, the process was not) — restart |
| the chip never shows `· isolated` | `isolation` did not reach the header; `/workspace` should still print it |
| `close` removes the tree but does not switch | the origin edge is missing — the conversation was moved, not forked |
| `[E_WRITE_BUSY] … being modified by conversation X` | another conversation holds a claim on that tree; that is arbitration, not a bug |

## Recording a run

Copy the script's summary into a file next to this one
(`docs/WORKTREES-ACCEPTANCE-<date>.md`), the way
[FLEET_RUN9_ACCEPTANCE.md](FLEET_RUN9_ACCEPTANCE.md) does: configuration,
provider/model, the checks that passed, and anything that needed a retry. A run
that is not written down is a run nobody can compare against later.
