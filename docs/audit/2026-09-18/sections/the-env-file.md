# Worklist slice: The .env file

From `worklist.tsv` (1 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A028 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 370-372 "Loading rules (**identical** in the Nim SDK, Go SDK and the UI bridge): existing shell environment always wins over `.env`; `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order"
- CODE: the *order* differs — Nim SDK `loadDotEnv(".env", NIF_ROOT/.env)` (`sdk/niffler/sdk.nim:771`), Go SDK the same (`sdk/go/component.go:414`), but the UI bridge passes the **root first** (`ui/bridge.go:71` `sdk.LoadDotEnv(harnessRoot()/.env, ".env")`)
- FIX: state the per-binary order: "components and core load `./.env` then `$NIF_ROOT/.env` (cwd wins — the first file loaded sets the key); the UI bridge is the exception and loads the harness root first, so in the desktop app the repo's `.env` wins over a cwd one."

