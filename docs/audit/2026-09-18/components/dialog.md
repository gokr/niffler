# Docs audit — `components/dialog/` (bash, 225 LOC, one script)

Read-only audit of the current tree (`docs/MANUAL.md` at **3082 lines**), 2026-09-19.
No component source and no MANUAL file was edited. Every claim cites `file:line`; claims
marked **verified live** were reproduced against isolated buses with instrumented stubs
(a fake `nats`, `zenity` and `notify-send` on `PATH`) so nothing touched a running
harness or the user's desktop.

Line numbers are a snapshot of the 3072-line revision (the consolidation pass is editing
`docs/MANUAL.md` concurrently); the **quotes** are the durable anchor.

## 1. What it offers

A **whole component written in bash — the in-tree proof that the wire contract is the
component** (`dialog.sh:1-19`, `docs/WIRE.md` "JSON envelopes over NATS"). No SDK, no
compile step: `make build` copies the script to `var/bin/dialog`
(`Makefile:297-300`; `nimble:all_internal` does `cp` + `chmod +x`).

- **Two tools on `svc.dialog.call`**: `dialog_show` (info/warning/error box) and
  `dialog_ask` (yes/no question), declared as a hand-written **bare `reg.publish`
  payload** (`dialog.sh:57-103`) — the same shape the SDKs publish
  (`sdk/niffler/sdk.nim:530-535`). Verified live: the payload is
  `{"name":"dialog","version":"0.1.0","pid":N,"language":"bash","tools":[…]}`; core
  ignores `language` (`core/catalog.nim` reads name/version/pid/client/pids/tools only;
  WIRE.md's field list at `docs/WIRE.md:44-47` does not include it) — harmless, per the
  spec's "unknown fields ignored".
- **Not in `manifest.yaml`** (no `dialog` entry): core never spawns it, nothing is
  restored at boot, and the user/admin spawns it explicitly — which is exactly what the
  MANUAL's row says. `make build` produces it; nothing links it onto `PATH`.
- **Delivery mechanism**: `nats reply --command "bash '<self>' handle" svc.dialog.call`
  (`dialog.sh:205-218`), with natscli resolving the binary `PATH` → `$HOME/go/bin/nats` →
  `$NIF_NATS_CLI` (`dialog.sh:37-45`) and the reply being the handler's **combined
  output** (`dialog.sh:202-215`) — hence the strict "logs go to a file, never stderr"
  discipline (`dialog.sh:46-55`).
- **Backend cascade** (`dialog.sh:107-141`): zenity (`--timeout 30` for a box, 60 for a
  question, and only when `DISPLAY` is non-empty) → `notify-send -u normal` → a log line.
  For `dialog_ask` there is **no** notify branch: without zenity it answers `timeout`
  immediately.
- **Stateless**: every request spawns a fresh `bash dialog.sh handle`
  (`dialog.sh:221-225`); no state file, no store use, no ring — one window per call, all
  logs appended to `$NIF_ROOT/var/logs/dialog.log` (`dialog.sh:51`).
- **No test covers it**: there is no `tests/t_dialog*` and no `make test-dialog`
  (`Makefile:81-95` target list, `grep -rn dialog tests/` → nothing). `make doctor` only
  checks the prereqs (`Makefile:628-640`) and can install them
  (`Makefile:589-593` `setup` → `install-natscli install-jq install-zenity`). Every
  behavioural claim below is therefore hand-verified here, not CI-pinned.

## 2. Tools (2, all registered as direct tools)

Signature = the JSON schema in the registration; flags = the `x-harness` block verbatim.

| Tool | Where | Purpose (schema description) | `x-harness` |
|---|---|---|---|
| `dialog_show {message, title?, kind?}` | schema `dialog.sh:71-84`, handler `:167-176` | "Show a desktop dialog (or notification) on the user's screen: an info, warning or error box… The call returns once the dialog is dismissed or times out (30s)." | `{timeoutMs: 45000}` only (`:82`) |
| `dialog_ask {message, title?}` | schema `dialog.sh:85-97`, handler `:177-184` | "Ask the user a yes/no question in a desktop dialog and return their answer (yes, no or timeout)… Blocks until the user answers or the dialog times out." | `{timeoutMs: 120000}` only (`:95`) |

**No `approval`, `onDemand`, `hidden`, `effect`, `sessionId`, `workspace` or `runner` flag**
— so once spawned, both tools are in the **frozen direct toolset** of every new
conversation (nothing marks them on-demand) and the model can pop a window on the human's
desktop with no gate, while the `spawn` that created them *is* gated
(`core/catalog.nim:79-95` carries `{"approval": "always"}` on core's `spawn`; the gate
itself is `core/dispatch.nim:1630-1633`). Verified live: the registration payload contains
exactly the two `x-harness` timeouts and nothing else.

Verified result shapes:

| Call | Backend | Result | Verified |
|---|---|---|---|
| `dialog_show {message, title, kind}` | zenity (`DISPLAY` set) | `{"ok":true,"shown":true,"via":"zenity","kind":"warning"}` and `zenity --warning --title T --text m --timeout 30` | live (stub zenity, argv recorded) |
| `dialog_show` | no `DISPLAY`, notify-send present | `{"ok":true,"shown":true,"via":"notify","kind":"error"}` and `notify-send -u normal T m` | live |
| `dialog_show` | neither | `{"ok":true,"shown":true,"via":"log","kind":"info"}` — nothing was shown | live |
| `dialog_ask` | zenity `--question`, rc 0/1/other | `yes` / `no` / `timeout` (`dialog.sh:133-143`; zenity's man page: "0, 1 or 5 … OK, Cancel or timeout") | live (rc 0/1/2 stubs; rc 2 → `timeout`) |
| `dialog_ask` | no zenity | `{"ok":true,"answer":"timeout"}` **after ~0.1 s** (measured 104 ms) — nobody was asked | live |
| unknown tool | — | `{"ok":false,"error":"unknown tool","code":"no-tool"}` (`dialog.sh:185-187`) | live |
| `dialog_show {kind:"bogus"}` | zenity | shows `--info` but returns `"kind":"bogus"` (`:113-118`, result at `:174-175`) | live |
| `dialog_show {}` (no `message`) | zenity | still `shown: true`, empty text — nothing enforces the schema's `required` (core does not validate args) | live |
| no `nats` CLI at all | — | `nats: command not found` (twice), exit 127 — no diagnostic | live |

## 3. Configuration

| Var | Effect here | Where |
|---|---|---|
| `NIF_NATS_URL` | bus address; wins over the discovery file | `dialog.sh:24-34` |
| `NIF_ROOT` | **only** the log directory (`${NIF_ROOT:-$HOME}/var/logs/dialog.log`); it does **not** affect bus discovery | `dialog.sh:51` |
| `NIF_NATS_CLI` | third fallback for the nats CLI binary, after `PATH` and `$HOME/go/bin/nats` | `dialog.sh:37-45` |
| `DISPLAY` | gates the zenity branch (empty ⇒ no window, even with zenity installed) | `dialog.sh:113`, `:133` |
| `HOME` | fallback log root when `NIF_ROOT` is unset | `dialog.sh:51` |

Bus resolution — **cwd-relative**, verified in four cases with a stub `nats` that logged
its argv:

```
NIF_NATS_URL  →  ./var/nats-url (the CURRENT DIRECTORY's var/)  →  nats://127.0.0.1:4222
```

- `NIF_ROOT` is ignored: with `$NIF_ROOT/var/nats-url` present and the cwd elsewhere,
  dialog still dialled `nats://127.0.0.1:4222`.
- This works for the *documented* usage because core starts every child with
  `workingDir = <NIF_ROOT>` (`core/supervisor.nim:160`) and sets `NIF_ROOT` for it
  (`core/supervisor.nim:129`) — so a spawned dialog reads `<root>/var/nats-url`. A dialog
  started by hand from any other directory silently targets 4222.
- Logging shares a file with the supervisor: core redirects the child's stdout/stderr to
  `<root>/var/logs/dialog.log` (`core/supervisor.nim:131-148`, first instance's
  `childLabel` = `dialog`), which is the same path the script appends its own
  `dialog: …` lines to (`dialog.sh:51-55`).

## 4. How the MANUAL covers it (now)

**Shipped-components row** — `## Layout of a running system` (`### Shipped components`), MANUAL:86 (the whole row):

> | `dialog` | bash | — | demo component written entirely in bash — nats CLI + jq, no SDK, no compile step: `dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer. Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool). Prereqs: natscli, jq, zenity — `make setup` installs all three |

Verified parts: the language and dependency claim ("nats CLI + jq, no SDK, no compile
step"), the fallback cascade, `var/bin/dialog` from `make build`
(`Makefile:297-300`), "not autostarted" (no manifest entry), the spawn invocation (core's
`spawn` takes `{name, binary}`), and "`make setup` installs all three"
(`Makefile:589-593`). Everything the row does **not** say is where the deltas are: the
tools' approval/onDemand status, the two `x-harness.timeoutMs` values, that only two of the
three prereqs are hard, that the spawn itself is approval-gated, and what the two results
actually contain.

**Other mentions (all checked):**

- `MANUAL:994` (`## Component ecosystem (plugins)`) — "`components/dialog/dialog.sh` — a
  whole bash component with no SDK at all." — correct, and the only place the component is
  used as a teaching example.
- `MANUAL:482` (`## Environment variables`) — "`NIF_NATS_CLI` (the nats CLI
  `components/dialog/dialog.sh` drives)" — correct; but MANUAL:387 in the same section
  says the opposite in spirit: the build/script knobs (the list includes `NIF_NATS_CLI`)
  "are never consulted by a running harness". See D7.
- `MANUAL:634` (`## Approvals`) lists core's `spawn` as gated — which is the missing half of
  the row's spawn instruction (D2).
- `make doctor`/`make install-*` prerequisites (`Makefile:589-593`, `:628-640`) are not in
  the MANUAL; the row's "`make setup` installs all three" is enough.

## 5. DELTA list

- **D1 — the tools are ungated and land in the frozen direct toolset.** `dialog_show`/
  `dialog_ask` carry only `x-harness.timeoutMs` (`dialog.sh:82, :95`); no `approval`, no
  `onDemand`. Consequence a user must know: spawning `dialog` puts two un-gated
  "pop a window on my desktop" tools into every new conversation's frozen prefix, while
  the spawn itself needed a human's approval. Nothing in MANUAL:86 says so.
- **D2 — the spawn instruction is silent about its own gate.** "spawn it with
  `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool)" omits that `spawn`
  is approval-gated (`core/catalog.nim:79-95`, `core/dispatch.nim:1630-1633`) — the
  script's own header states it ("Spawning is approval-gated like every new component",
  `dialog.sh:15-17`).
- **D3 — zenity is not a prerequisite.** It is needed only for a real window (and only
  with `DISPLAY`); without it `dialog_show` degrades to a notification, then to a log line,
  and `dialog_ask` answers `timeout` **immediately** (measured 104 ms) rather than asking
  anyone. "Prereqs: natscli, jq, zenity" overstates; natscli + jq are hard, zenity is a
  display nicety (verified live in all three modes).
- **D4 — result semantics are undocumented and partly self-contradictory.** `shown: true`
  is returned when `via: "log"` (nothing was shown) and zenity's/notify-send's exit codes
  are discarded (`|| true`, `dialog.sh:118-125`); `kind` echoes the raw argument while the
  window used a normalized one, so `{kind: "bogus"}` returns alongside an **info** box
  (verified live). A `via`/`shown` description in the MANUAL (or a stricter result) is
  needed before anyone writes a workflow on `shown`.
- **D5 — the headless cliff is invisible to the model.** With no `DISPLAY`/zenity,
  `dialog_ask` reports `{"answer":"timeout"}` instantly — indistinguishable from "the human
  saw it and let it lapse". Verified live (104 ms). Worth both a doc line and a
  distinguishable answer (code).
- **D6 — bus resolution is cwd-relative and `NIF_ROOT` is ignored** (verified in four stub
  cases): `NIF_NATS_URL` → `./var/nats-url` → 4222. It only works when core spawns the
  component (core sets `workingDir = NIF_ROOT`, `core/supervisor.nim:160`); a
  hand-started dialog from elsewhere talks to 4222. The MANUAL's client-discovery sentence
  (MANUAL:2975-2982) describes a *different* chain and never mentions dialog's.
- **D7 — `NIF_NATS_CLI` is misclassified as "never consulted by a running harness".**
  MANUAL:387 excludes it from component use while MANUAL:482 attributes it to
  `components/dialog/dialog.sh`, which does read it (`dialog.sh:44`) — and dialog *is* a
  spawned component. The precedence is also unstated: `PATH` → `$HOME/go/bin/nats` →
  `NIF_NATS_CLI` (verified: the `NIF_NATS_CLI` stub was only consulted after both were
  removed from `PATH`/`$HOME`), so setting it has no effect on the common install.
- **D8 — a missing nats CLI kills the component with no diagnostic**: `nats: command not
  found` twice, exit 127 (verified with a `PATH` without `nats` and no
  `~$HOME/go/bin/nats`). The MANUAL lists natscli first among the prereqs but never says
  the component cannot start without it.
- **D9 — no `reg.depart`, no signal handling** (`grep -c reg.depart dialog.sh` → 0; the only
  trap kills the reply child, `dialog.sh:212`). Spawned through core this is covered (the
  supervisor drops the registration when the child dies, `core/supervisor.nim:193-204`);
  a hand-started instance leaves a stale `dialog` entry with both tools in the catalog
  until core restarts — the same trap as `console` (see `components/console.md` D3).
- **D10 — no `x-harness.effect`**: both tools are classified **write** by the fabric batch
  host (absent ⇒ write, AGENTS.md), so a fabric program that just asks a question runs it
  exclusively rather than in the read concurrency cap. One documented word (or
  `effect: "read"`) would fix it.
- **D11 — the log file is undocumented and unrotated**: `$NIF_ROOT/var/logs/dialog.log`,
  falling back to `$HOME/var/logs/dialog.log` when `NIF_ROOT` is unset (`dialog.sh:51`) —
  and for a spawned instance that is the *same* file core redirects the child's
  stdout/stderr into (`core/supervisor.nim:131-148`), so component log lines and nats-cli
  noise interleave there.
- **D12 — platform caveats are unstated** (`readlink -f` at `dialog.sh:22` under
  `set -euo pipefail`, no `osascript` anywhere in the script although `Makefile:716`
  advertises "macOS — dialog falls back to notify-send/osascript"). A Linux-first demo
  component should say so; the Makefile comment is the thing that is wrong.
- Verified, no change needed: MANUAL:86's bash/no-SDK/no-compile/`var/bin/dialog`/
  not-autostarted/spawn-shape/`make setup` claims, MANUAL:994's reference-shape sentence,
  MANUAL:482's `NIF_NATS_CLI`-drives-dialog clause, and the zenity rc mapping
  (zenity returns 5 on timeout; `dialog.sh:139-142` maps it to `timeout`).

## 6. Findings — row format (`normalize.py`)

Legend: rows are grouped under the **exact current MANUAL heading**; the class is the
trailing `[class]` tag (`FIX: fix: none` = `verified`; "code bug" in the FIX text is detected by
the parser as `code-bug?`; `wrong`/`missing`/`trim` need the tag because a
`components/*.md` report keeps the parser's `group` at `component: dialog`). **Every group heading below is one of the current MANUAL's `## ` headings, verbatim**; `FIX: fix: none` is the literal token `normalize.py` classifies as `verified`. `FIX:` wording
is the text I propose to insert/replace, verbatim.

## Layout of a running system

- MANUAL: "demo component written entirely in bash — nats CLI + jq, no SDK, no compile step" | CODE: components/dialog/dialog.sh:1-19 (header), Makefile:297-300 (`cp $< $@ && chmod +x $@`; nimble:all_internal identical), manifest.yaml (no `dialog` entry) | FIX: fix: none — verified [verified]
- MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer." | CODE: components/dialog/dialog.sh:107-141 (backends), :167-184 (handlers), :82/:95 (`x-harness.timeoutMs` 45000/120000, nothing else) | FIX: add "Neither tool is approval-gated and neither is on-demand, so once `dialog` is spawned both sit in every new conversation's direct toolset; `dialog_show` returns `{ok, shown, via: zenity|notify|log, kind}`, `dialog_ask` `{ok, answer: yes|no|timeout}`, and without a display (`DISPLAY` unset or zenity missing) `dialog_ask` answers `timeout` immediately without asking anyone." [missing]
- MANUAL: "Ships in `var/bin/dialog` (`make build`) but is **not autostarted**; spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` (core's tool)." | CODE: components/dialog/dialog.sh:15-17 (the script's own header: "Spawning is approval-gated like every new component"), core/catalog.nim:79-95 (`spawn` carries `approval: \"always\"`), core/dispatch.nim:1630-1633 | FIX: update to "…spawn it with `spawn {name: "dialog", binary: ".../var/bin/dialog"}` — core's `spawn` is approval-gated, so a human confirms the component itself; the two dialog tools are not gated afterwards." [doc-edit]
- MANUAL: "Prereqs: natscli, jq, zenity — `make setup` installs all three" | CODE: components/dialog/dialog.sh:37-45 (nats CLI required; missing → `nats: command not found`, exit 127), :152-163 (`jq` required to parse the envelope), :113/:122/:127 (`zenity`/`notify-send` optional; log fallback), Makefile:589-593 (`setup` → `install-natscli install-jq install-zenity`), Makefile:628-640 (`doctor`) | FIX: update to "Prereqs: the nats CLI and `jq` (both hard — without them the component cannot start); `zenity` (or `notify-send`) only for the visible part, and only with `DISPLAY` set — `make setup` installs all three, `make doctor` checks them." [doc-edit]
- MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer" | CODE: components/dialog/dialog.sh:51 (log path `${NIF_ROOT:-$HOME}/var/logs/dialog.log`), core/supervisor.nim:131-148 (a spawned child's stdout/stderr land in the same `var/logs/dialog.log`) | FIX: add "Both tools append `dialog: …` lines to `$NIF_ROOT/var/logs/dialog.log` (`$HOME/var/logs/dialog.log` when `NIF_ROOT` is unset) — the same file core redirects the spawned child's stdout into." [doc-edit]
- MANUAL: "demo component written entirely in bash — nats CLI + jq, no SDK, no compile step" | CODE: components/dialog/dialog.sh:24-34 (bus = `NIF_NATS_URL` → `./var/nats-url` → 4222; `NIF_ROOT` ignored), core/supervisor.nim:160 (`workingDir = NIF_ROOT` is why the spawned case works) | FIX: add "It resolves the bus from the **current directory** (`./var/nats-url`, then 127.0.0.1:4222) — `NIF_ROOT` is not consulted, so the documented `spawn` path works because core starts children with cwd = the harness root, while a hand-started copy from another directory silently targets 4222." [missing]
- MANUAL: "Ships in `var/bin/dialog` (`make build`) but is **not autostarted**" | CODE: components/dialog/dialog.sh:212 (only trap kills the reply child), `grep -c reg.depart dialog.sh` → 0, core/supervisor.nim:193-204 (core drops a *child's* registration on death) | FIX: add "(when you `spawn` it, core drops its registration on exit; a copy you started by hand stays in the catalog until core restarts, like `console`)" [missing]
- MANUAL: "`dialog_show` pops a desktop dialog (zenity, notify-send or log fallback), `dialog_ask` asks the user a yes/no question and returns the answer." | CODE: components/dialog/dialog.sh:208 (no `x-harness.effect` ⇒ fabric classifies both as write-effect), :82/:95 | FIX: add "(neither tool declares `x-harness.effect`, so the fabric batch host treats them as writes — a program that only asks a question runs exclusively)" [missing]
- MANUAL: "`dialog_ask` asks the user a yes/no question and returns the answer" | CODE: components/dialog/dialog.sh:139-142 (zenity `--question` rc 0/1/other → yes/no/timeout; zenity's own rc 5 = timeout), :175-184 (headless ⇒ instant `timeout`), :174-175 (raw `kind` echoed although the window normalized it) | FIX: code bug — distinguish "nobody can answer" (no display) from "the human let it time out" in the result, and echo the `kind` that was actually used; `shown: true` with `via: "log"` or after a failed zenity/notify-send also claims something that did not happen (`|| true` at :118/:123) [code-bug?]

## Component ecosystem (`plugins`)

- MANUAL: "`components/dialog/dialog.sh` — a whole bash component with no SDK at all." | CODE: components/dialog/dialog.sh:1-19 (envelope + bare `reg.publish` written by hand), docs/WIRE.md:44-47 (the registration shape it speaks) | FIX: fix: none — verified, and it should stay the teaching example [verified]

## Environment variables

- MANUAL: "`NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_NATS_CLI`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs: they steer `make` and `scripts/` and are never consulted by a running harness, so they are not part of the runtime table below." | CODE: components/dialog/dialog.sh:37-45 (`NIF_NATS_CLI` is the third fallback for the nats CLI of a spawned component) | FIX: update to move `NIF_NATS_CLI` out of that list, e.g. "…`NIF_BIN_DIR`, `NIF_BUILD_LOCK`, `NIF_STORE_BIN`, `NIF_REPO_ROOT` and `NIF_LSP_BIN` are build- and script-only knobs… (`NIF_NATS_CLI` is the exception: the spawned bash component `dialog` reads it as the last fallback for the nats CLI, after `PATH` and `$HOME/go/bin/nats`)" [wrong]
- MANUAL: "`NIF_NATS_CLI` (the nats CLI `components/dialog/dialog.sh` drives)" | CODE: components/dialog/dialog.sh:38-45 (PATH first, then `$HOME/go/bin/nats`, then `$NIF_NATS_CLI`) | FIX: update to "`NIF_NATS_CLI` (the nats CLI `components/dialog/dialog.sh` drives — consulted only when `nats` is neither on `PATH` nor in `$HOME/go/bin`)" [doc-edit]

## 7. Not user-facing

- `SELF`, `bus_url`, `nats_cli`, `log`, `register`, `show_dialog`, `ask_dialog`, `handle`
  (`dialog.sh:20-190`) are internals; the MANUAL needs the two tool contracts and the
  backend cascade, never these names.
- The duplicated "main: subscribe first … then announce" comment block
  (`dialog.sh:195-199` and `:201-204`) is a copy-paste artefact — cosmetic code cleanup,
  no docs surface.
- `dialog.sh:196-198`'s comment claims "The nats reply child is killed with us on
  SIGTERM" — true (`:212`), but nothing re-announces departure (D9).
- `dialog.sh:157-163` tolerates a non-object `args` silently (`jq … || true`): verified
  live — `dialog_show` with `args: "oops"` returned `shown: true, kind: ""` and popped an
  empty info box. Codes, not docs (core does not validate arguments for any tool).
- `components/dialog/dialog.sh:59-62`'s claim that a non-zero handler exit means no reply
  is not what natscli v0.4.0 does (`nats reply --command` still calls `RespondMsg` with the
  combined output after a failure — `~/go/pkg/mod/github.com/nats-io/natscli@v0.4.0/cli/reply_command.go:180-192`).
  The defensive style is right; the comment is wrong, and `make install-natscli` pins
  nothing (`go install …/@latest`), so the assumption can drift with upstream.
