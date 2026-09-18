# Worklist slice: Recovery

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A090 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2148-2156 "`--recover` does three things, in order: rebuilds the shipped binaries from source (`make build`, falling back to `nimble all`) … wipes the store's component records … boots the requested profile … **Conversations and messages survive**"
- CODE: `core/niffler.nim:245-265` (`rebuildShipped` tries `make build` then `nimble all`, 600 s wait), `:432-433`, `:584-592` (wipe with a warning on failure); `Makefile:557-560` (`recover: build` then `./var/bin/niffler --recover`) ✔
- FIX: none.

## A091 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2150 "If the agent (or a bug) breaks a shipped component — overwrote a binary in `var/bin`…" + the `git restore components/ core/ sdk/` recipe
- CODE: consistent with `scripts/with-build-lock.sh` and the Makefile build targets; note `make clean` is the sanctioned artifact remover (AGENTS.md) and `git restore` does not touch `var/`
- FIX: add "(never `rm -rf var` — use `make clean`; a stale `var/store.db.lock` or `var/barrel-db.lock` is what makes a fresh store refuse to start, see `make down`)" — the flock symptom is the one operators hit and it is currently in AGENTS.md only.

## A111 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **MANUAL 2323** — the agent-modified-sources recipe (`git restore components/ core/ sdk/`) does not cover `manifest.yaml`/`Makefile`, the two files whose edits most often break a boot; the Recovery section's own `git checkout -- .` is the honest form.

## A204 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2163 "# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)"
- CODE: `ui/main.go:51` (`OnShutdown: app.shutdown`) → `ui/bridge.go:85-88` (`comp.Close()`); the autostarted core then sees the client count fall to zero (`core/niffler.nim:678-690`)
- FIX: accurate; no change.

