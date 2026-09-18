# Docs audit — `components/console/` (Nim, 107 LOC, one file)

Read-only audit of the current tree (`docs/MANUAL.md` at **3072 lines**), 2026-09-19.
No component source and no MANUAL file was edited. Every claim cites `file:line`; claims
marked **verified live** were reproduced against an isolated bus with hand-made fixtures
(no interference with a running harness).

Line numbers are a snapshot of the 3072-line revision (the consolidation pass is editing
`docs/MANUAL.md` concurrently — re-verified against the tree at the end of this audit); the
**quotes** are the durable anchor.

## 1. What it offers

The **passive bus viewer**: a single `>` subscription rendered as a readable stream
(`main.nim:64-100`). It is a bus citizen, not a client with a service:

- **Zero tools, zero state, no service subject** — `main.nim:1-11`. It does announce
  itself: `reg.publish` with `{name: "console", version: "0.1.0", pid, tools: []}`
  (`main.nim:72-74`, the same raw payload contract the SDK uses,
  `sdk/niffler/sdk.nim:530-535`) — so it appears in `catalog {op: components}` as
  `console: (no tools)` while it runs (verified live against a running harness).
- **Not in `manifest.yaml`**: core never spawns it, nothing is restored at boot; the user
  starts `./var/bin/console` by hand (the shipped-components table's `—` Manifest cell
  means exactly this). Built by `make build` (`Makefile:253-254`, `Makefile:308-310`,
  `nimble:all_internal`, `--path:sdk`), linked onto `PATH` as `niffler-console` by
  `make install` (`scripts/install.sh:101,111`).
- **It is not an interactive frontend**: the registration carries no `"client": true`
  (`main.nim:72-74`; the SDK adds that field only via `interactive()`,
  `sdk/niffler/sdk.nim:536-539`), so it does **not** count toward
  `clientCount` (`core/catalog.nim` `clientCount`) and an autostarted core can shut down
  (after `NIF_AUTOSTART_IDLE_S`, default 10 s) while console keeps running.
- **No signal handling**: there is no `SIGTERM`/`SIGINT` handler and no `reg.depart`
  (`grep -n "reg\." main.nim` → only `reg.publish`). See D3.
- Rendering is deliberately small: a `HH:mm:ss.mmm` stamp (`main.nim:21-23`), ANSI colors
  **only when stdout is a tty** (`main.nim:25-29`), and one line per message with
  truncation — args 300, result 500, error 300, event payload 500, assistant payload 2000
  chars (`main.nim:31-56`).
- Reconnect loop: `followBus()` re-reads the discovery file on every attempt, so a harness
  that restarts on a new random port is picked up (`main.nim:64-68`, `:101-107`).
- `tests/t_console.nim` (112 lines) pins call/result/event rendering, the raw registration
  payload contract, and the "subscription is ready" barrier; `Makefile:505`
  (`test-console`) runs it. It does **not** cover reg-payload rendering (D1), staleness
  (D3) or reconnection (D4).

## 2. Rendering contract (no tools — it registers zero)

| Envelope kind | Rendered as | Evidence |
|---|---|---|
| `call` | `<ts> call  <subject>  <tool> <args≤300>` | `main.nim:39-41`; verified live: `01:17:00.751 call  svc.bash.call  bash {"command":"echo real-reply"}` |
| `result` | `<ts> result  <tool> → <args≤500>` | `main.nim:42-44`; **the `tool` field is empty for every SDK reply** — `sdk/niffler/sdk.nim:725` replies via `resultEnvelope(id, value)` (`sdk/envelope.nim:72-73`), which carries no tool: verified live `01:17:00.804 result   → {"exit_code":0,…}` (D2) |
| `error` | `<ts> error   <tool> ! <error≤300>` | `main.nim:45-47` |
| `event` | `<ts> event  <subject>  <payload≤500>` | `main.nim:54-56` |
| `event` on `ev.session.assistant` | `<ts> assistant  <payload≤2000>` (whole payload, not just `content`) | `main.nim:50-53` |
| undecodable JSON | `error` with `{"code":"bad-envelope","message":"<first 200 bytes>"}` | `sdk/envelope.nim:63-68` (decode never throws); verified live on `garbage.subject` |
| bare `reg.publish` / `reg.depart` payload | **blank event line**: `<ts> event reg.publish  ` — the payload lives at the top level of the message, and `render` prints only `env.payload` | `main.nim:48-56` vs `sdk/niffler/sdk.nim:530-535`; verified live (D1) |

## 3. Configuration

Same two SDK variables as `cli`, nothing of its own (no options, no flags, no config
file — `main.nim:101-107` is the whole entry point):

| Var | Effect here | Where |
|---|---|---|
| `NIF_NATS_URL` | bus address; wins over everything | `sdk/subjects.nim:25-26` via `main.nim:58-62` |
| `NIF_ROOT` | the harness root whose `var/nats-url` is read (unset → the binary's own clone, never the cwd); also one of the two `.env` locations | `sdk/subjects.nim:8-32`; `.env` half at `main.nim:101` (`loadDotEnv(".env", rootDir() / ".env")`) |

Verified live: with `NIF_ROOT=<tmp>` (its `var/nats-url` pointing at an isolated bus) and
`NIF_NATS_URL` unset, console printed
`console: following the bus at nats://127.0.0.1:<port>`. The discovery file is **never**
read from the cwd — see D5 for the MANUAL sentence that says otherwise.

## 4. How the MANUAL covers it (now)

**Shipped-components row** — `### Shipped components`, MANUAL line 81:

> | `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |

Correct.

**The viewer section** — `## The bus in one screen`, MANUAL:599-608:

> `nats sub '>'` attached to the bus shows the harness thinking in real time.
> Or better: **the console component** (`./var/bin/console`, not in the
> manifest — start it yourself in a second terminal) subscribes to
> everything and renders the wire traffic readably: calls with tool + args,
> results, errors, events, approvals — it is how you follow a live install
> or a stuck-tool call:
>
> ```bash
> ./var/bin/console    # in a separate terminal while the harness runs
> ```

Right about what it is, where it lives and that core does not start it ("not in the
manifest — start it yourself"). The "renders … readably" promise is where the gaps are:
registrations render blank (D1), results carry no tool name (D2), and the two things a
user most needs when following a live install — which component came up, and which tool
answered — need the raw `nats sub` this paragraph offers as the inferior alternative.

**Other mentions:**

- `MANUAL:2382` (in `### Boundary`, `## Observation and logs`) — "`console` prints and
  forgets" — correct and consistent with `main.nim` (no persistence, no ring).
- `MANUAL:2389-2390` (in `### observe`: bounded live inspection) — observe "preserves the
  original JSON node, including unknown envelope fields and bare registration payloads" —
  a contract console does **not** share (`main.nim:48-56`); the contrast is undocumented
  and, for anyone debugging a boot, decisive (D1).
- `MANUAL:2965-2972` (`## Starting and stopping`, "Interactive plugins") — "they probe for a
  live bus (`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` →
  127.0.0.1:4222)". Accurate for the TUI that bullet names
  (`~/git/niffler-tui/tui/main.go:3057-3072`), **not** for `console`/`cli`: the Nim SDK
  reads `NIF_NATS_URL` → `<NIF_ROOT or own clone>/var/nats-url` → `127.0.0.1:4222`, with
  no cwd leg (`sdk/subjects.nim:19-32`) — verified live (D5).
- `MANUAL:3015` (`## Common tasks`) — `make install` lists `niffler-console` — matches
  `scripts/install.sh:111`.
- `## Testing` (MANUAL:2911) no longer hand-lists targets; `test-console` exists
  (`Makefile:505`) — nothing to fix.

## 5. DELTA list

- **D1 — bare registration payloads render as blank lines (the biggest usability gap).**
  `render` prints `env.payload` for events; a `reg.publish`/`reg.depart` message *is* the
  registration object (`{name, version, pid, tools}`), so its fields are ignored and the
  line is `<ts> event reg.publish  ` with nothing after the subject. **Verified live**
  twice (isolated bus, fixtures): `00:53:59.462 event reg.publish  ` and, against a real
  `bash` component, `01:16:58.733 event reg.publish  `. Component arrival/departure — the
  most frequent boot traffic — is therefore invisible in detail, while the neighbouring
  `observe` component documents that it preserves exactly these payloads (MANUAL:2389-2390).
- **D2 — results have no tool attribution.** Every SDK reply omits `tool`
  (`sdk/niffler/sdk.nim:725`, `sdk/envelope.nim:72-73`), so console prints
  `result   → {…}` with an empty name and no envelope id to correlate against
  (`main.nim:42-44`). Verified live against a real `bash` component
  (`01:17:00.804 result   → {"exit_code":0,…}`). Consequence: on a busy bus you cannot
  tell which tool produced which result without counting calls.
- **D3 — a killed console leaves a permanent stale registration, and it never publishes
  `reg.depart`.** There is no signal handler (`main.nim:101-107`); core drops a
  registration only on `reg.depart` (`core/catalog.nim:769-787`) or for its own children
  (`core/supervisor.nim:193,204` → `dropReplica`, `core/catalog.nim:801-818`). **Verified
  live** on the running harness: after SIGTERM of a console, `cli catalog` still printed
  `console: (no tools)` and `catalog {op: snapshot}` still carried `{"name":"console",
  "pid":451756,"pids":[451756],"tools":0}` with a dead pid; publishing `reg.depart` with
  that pid removed it immediately. The MANUAL documents the *client* variant of this
  ("a client killed without `reg.depart` keeps an autostarted core up … until the catalog
  drops it", MANUAL:2980-2985) but not that a zero-tool component's entry never drops by
  itself — the same is true of a hand-started `dialog`.
- **D4 — reconnection is undocumented and slower than the source comment claims.** After
  the bus dies, console keeps polling until the natsnim client exhausts its internal
  reconnect budget (`maxReconnects: 60`, `reconnectWaitMs: 2000`,
  `reconnectDialTimeoutMs: 2000` — `~/.nimble/pkgs2/natsnim-0.1.0-*/natsnim/conn.nim:124-125`),
  then prints one `console: bus connection lost — reconnecting…` (`main.nim:96-99`) and
  enters `sleep(2000)` retries that re-read the discovery file. **Verified live**: after
  killing the bus, console printed the loss line once, then 43 `retrying in 2s` lines over
  ~3.7 min; when a server appeared on the *new* port written into `$NIF_ROOT/var/nats-url`,
  it reconnected by itself and rendered new events (so the code comment's "found" claim is
  true — but the in-code "~2min" (`main.nim:93-95`) understates the ~4 min budget, and the
  MANUAL says nothing about any of it).
- **D5 — the documented client discovery chain is the TUI's, not the Nim clients'.** The
  MANUAL's "Interactive plugins" bullet (MANUAL:2965-2972) lists a `./var/nats-url` leg
  that `console` and `cli` do not have (they use `NIF_ROOT` **or their own clone**, never
  the cwd — `sdk/subjects.nim:19-32`) while `dialog` has the opposite behaviour
  (cwd-relative only, `NIF_ROOT` ignored). Three clients, three chains, one sentence
  covering none of them exactly (the sentence is right for `niffler-tui`,
  `~/git/niffler-tui/tui/main.go:3057-3072`).
- **D6 — the view is unconfigurable and its limits are unstated**: no filtering, no file
  output, no JSON mode, no level/subject flags; truncation caps 300/500/2000
  (`main.nim:31-56`); colors only on a tty (`main.nim:25-29`); a permanently rewritten
  screen is not offered. One sentence would let a user decide between console and
  `observe`.
- **D7 — console is not a `"client": true` frontend**, so an autostarted core can exit
  underneath it (MANUAL:2980-2991 defines the client rule; console violates neither the
  rule nor the text — but the section never says which of the three terminal clients is
  one). Verified in code (`main.nim:72-74` has no `client` field; `core/catalog.nim`
  `clientCount` counts only `client: true`).
- Verified, no change needed: MANUAL:81 (row), MANUAL:2382 (`console` prints and forgets),
  MANUAL:3015 (`make install` → `niffler-console`), the `test-console` wiring, and
  "not in the manifest — start it yourself".

## 6. Findings — row format (`normalize.py`)

Legend: rows are grouped under the **exact current MANUAL heading**; the class is the
trailing `[class]` tag (`FIX: fix: none` = `verified`; "code bug" in the FIX text is detected by
the parser as `code-bug?`; `wrong`/`missing`/`trim` need the tag because a
`components/*.md` report keeps the parser's `group` at `component: console`). The group
headings below carry the MANUAL's heading text without its own `##`/`###` marker; `FIX: fix: none` is the literal token `normalize.py` classifies as `verified`. `FIX:`
wording is the text I propose to insert/replace, verbatim.

## Shipped components

- MANUAL: "| `console` | Nim | — | on-demand bus viewer (renders every envelope on stdout) |" | CODE: components/console/main.nim:1-11 (zero tools), :72-74 (`reg.publish`), Makefile:253-254, manifest.yaml (no `console` entry), scripts/install.sh:111 | FIX: fix: none — the row is right, including the empty Manifest cell [verified]
- MANUAL: "on-demand bus viewer (renders every envelope on stdout)" | CODE: components/console/main.nim:39-56 (registration payloads render as bare `event <subject>` lines; results lose their tool name), :101-107 (no signal handling, no `reg.depart`) | FIX: add "It is a stream viewer, not a registration viewer: bare `reg.publish`/`reg.depart` payloads show as `event reg.publish` with an empty body, a result shows its args but not the tool that produced it, and a killed console stays in the catalog until core restarts" [missing]

## The bus in one screen

- MANUAL: "Or better: **the console component** (`./var/bin/console`, not in the manifest — start it yourself in a second terminal) subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:" | CODE: components/console/main.nim:35-56 (render), :64-100 (subscribe `>` + loop) | FIX: update to "…renders the wire traffic readably: calls with subject + tool + args, results, errors, events, approvals. Two limits are worth knowing: a `reg.publish`/`reg.depart` payload prints as a bare `event <subject>` line (use `observe_subjects`/`catalog` to see which component came up), and every SDK result prints with an empty tool name — correlate by the call above it." [doc-edit]
- MANUAL: "subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:" | CODE: components/console/main.nim:48-56 (event payload only; top-level registration fields dropped) | FIX: add "Registration and departure payloads are the one thing it cannot show in detail: `reg.publish` is a bare JSON object (not an envelope), so console prints its subject with an empty body — `observe` keeps the payload intact if you need it." [doc-edit]
- MANUAL: "./var/bin/console    # in a separate terminal while the harness runs" | CODE: components/console/main.nim:64-100, 101-107 (retry loop; no flags, no filtering, truncation 300/500/2000 chars, colors only on a tty) | FIX: add "It has no options: everything on the bus, one line per message, args/result/event payloads truncated to 300/500/500 characters (assistant text 2000), colors only on a tty. For a bounded, filterable, persistent view use `observe`/`logfile`." [doc-edit]
- MANUAL: "subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:" | CODE: components/console/main.nim:48-56 (events render `env.payload` only), sdk/niffler/sdk.nim:530-535 (a `reg.publish` payload has no `payload` key) | FIX: code bug — for a non-envelope message (a bare registration/departure payload) render the decoded top-level object (e.g. `event reg.publish  {name: "bash", pid: 1234}`) instead of an empty body; without this, the arrival of every component is a blank line [code-bug?]
- MANUAL: absent | CODE: components/console/main.nim:42-44 (prints `env.tool`, empty for SDK replies), sdk/niffler/sdk.nim:725 + sdk/envelope.nim:72-73 (replies carry no `tool`) | FIX: code bug — make results identifiable on a busy bus: echo the envelope `id`, or keep an id→tool map from the calls already rendered, so a `result   → {…}` line can be attributed [code-bug?]
- MANUAL: absent | CODE: components/console/main.nim:64-68 and :93-99 (natsnim reconnect budget ~4 min before giving up; then the outer loop re-reads the discovery file every 2 s) | FIX: add "When the bus dies, console goes quiet for the client's reconnect budget (tens of seconds to ~4 minutes), then prints `bus connection lost — reconnecting…` and retries every 2 s, re-reading `var/nats-url` each time — a harness that restarts on a new random port is picked up automatically." [doc-edit]

## Starting and stopping

- MANUAL: "they probe for a live bus (`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` → 127.0.0.1:4222), connect and register `client: true`" | CODE: sdk/subjects.nim:19-32 (Nim: `NIF_NATS_URL` → `<NIF_ROOT or own clone>/var/nats-url` → default, no cwd leg), components/console/main.nim:58-62, components/cli/main.nim:28-32, components/dialog/dialog.sh:24-31 (cwd-relative only); ~/git/niffler-tui/tui/main.go:3057-3072 (the four-leg chain the sentence describes) | FIX: update to "the chain is per client: the TUI probes `NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` → 127.0.0.1:4222; the Nim clients (`cli`, `console`) use `NIF_NATS_URL` → `<NIF_ROOT or their own clone>/var/nats-url` → 127.0.0.1:4222 (never the cwd); the bash `dialog` uses `NIF_NATS_URL` → `./var/nats-url` (cwd only) → 127.0.0.1:4222" [wrong]
- MANUAL: "Interactive frontends register `"client": true` (the SDK's `interactive()` / `Component.Client` marker)." | CODE: components/console/main.nim:72-74 (registers as an ordinary zero-tool component, no `client` field); core/catalog.nim `clientCount` | FIX: add "`console` and `dialog` are not interactive frontends by this definition: they register without `client: true`, so an autostarted core can exit under them (they reconnect when a new harness appears)." [doc-edit]

## Boundary

- MANUAL: "`console` prints and forgets, and `hooks` record nothing." | CODE: components/console/main.nim:1-11 (no ring, no file, no state) | FIX: fix: none — verified [verified]

## `observe`: bounded live inspection

- MANUAL: "It preserves the original JSON node, including unknown envelope fields and bare registration payloads." | CODE: components/observe/main.nim (raw `>` ring) vs components/console/main.nim:48-56 (payload-only render, non-envelope messages show an empty body) | FIX: add "(the sibling `console` does not: it renders envelopes only, so a bare `reg.publish` shows as `event reg.publish` with no body — see [The bus in one screen](#the-bus-in-one-screen))" [doc-edit]

## Common tasks

- MANUAL: "make install        # PATH entries (niffler, niffler-cli, niffler-console," | CODE: scripts/install.sh:84,101,110-111 (`link niffler-console console`), Makefile:253-254 | FIX: fix: none — verified [verified]

## Testing

- MANUAL: "make test-ui        # ... frontend side only: lib unit tests + `npm run typecheck`" | CODE: Makefile:505 (`test-console` → `t_console`), tests/t_console.nim:1-112 (call/result/event rendering + raw registration contract) | FIX: fix: none — verified; the hand-list of targets is gone and the target exists [verified]

## 7. Not user-facing

- `ts`, `styled`, `chop`, `render`, `resolveBusUrl`, `followBus` (`main.nim:21-100`) are
  internals — the MANUAL needs the *contract* (D1/D2/D6), never these names.
- The `ev.session.assistant` special case (`main.nim:50-53`) is a rendering convenience:
  console shows the whole event payload for it (sessionId included), not the model text
  alone — worth a clause only if D6's sentence is written.
- Console's own registration is invisible to itself (it publishes before subscribing,
  `main.nim:72-77`) — an accidental but harmless ordering; no docs surface.
