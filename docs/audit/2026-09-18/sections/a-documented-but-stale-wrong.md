# Worklist slice: A. Documented but stale / wrong

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A260 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:340 `NIF_MCP_PROBE_TIMEOUT_MS` "…(overrides the 30s default and the call's own `timeoutMs` when higher)"
- CODE: components/mcp/main.go:463-474 — `timeout := 30s`; `cfg.TimeoutMs` used only `if > 30_000`; the env value is then assigned **unconditionally last** (`if raw := os.Getenv("NIF_MCP_PROBE_TIMEOUT_MS"); ms > 0 { timeout = ms }`), so a *lower* env value wins too (mcp-bridge probes: components/mcp-bridge/main.go:437)
- FIX: drop "when higher" → "(overrides both the 30 s default and the server's configured `timeoutMs`)"

## A263 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:367-369 "Loading rules (identical in the Nim SDK, Go SDK and the UI bridge): existing shell environment **always wins** over `.env`; `.env` is loaded from the current directory and from `$NIF_ROOT`, in that order."
- CODE: the order is *reversed* in the UI bridge — ui/bridge.go:71 `sdk.LoadDotEnv(filepath.Join(harnessRoot(), ".env"), ".env")` (root first, cwd second); since the first-loaded value wins (sdk/go/dotenv.go:24 `if os.Getenv(key) == ""`, sdk/dotenv.nim `if … not existsEnv(key)`, sdk/ts/src/dotenv.ts:36 `=== undefined`), the **harness-root `.env` wins in the UI** while the **launch-directory `.env` wins in the SDKs**
- FIX: state the winner explicitly and split the UI out: "the first file that defines a key wins, so a launch-directory `.env` beats the root one — except in the UI bridge, which loads the root first (ui/bridge.go)".

## A264 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:240 (state table, Environment/.env row) "components read env once at boot; a config change is `core.kill` + `core.spawn`" (repeated MANUAL:336 and MANUAL:879)
- CODE: the supervisor passes **no env** to children — core/supervisor.nim:118-120 comment + :160 `startProcess("/bin/sh", workingDir = sup.root, …)` inherits core's environment, so a variable **exported in core's shell env** cannot be changed by kill+spawn at any level; children do re-read `.env` itself at their own boot (sdk/niffler/sdk.nim:771, sdk/go/component.go:414, sdk/ts/src/component.ts:242, core/session.nim:37)
- FIX: "`.env` edits apply when the component is respawned (`core.kill` + `core.spawn`); a change to a variable *exported in the shell environment* requires restarting the harness — children inherit core's environment and shell env beats `.env`."

## A265 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:296 `NIF_SKILLS_BUNDLED_DIR` default "`<repo>/skills`" is right but the *resolution source* is the build checkout, not `NIF_ROOT`
- CODE: components/skills/main.nim:185-198 — no override → `currentSourcePath().parentDir.parentDir.parentDir / "skills"` (compile-time source path), falling back to `root / "skills"` only when the repo tree is absent
- FIX: "(compiled-in source path of the component; `$NIF_ROOT/skills` only as fallback)".

