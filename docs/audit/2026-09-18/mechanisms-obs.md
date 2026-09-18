# MANUAL.md delta audit — approvals · observability · plugins & skills · store paging · hooks

Scope (deliberately narrow): MANUAL.md §§ **Approvals** (455–522), **Component ecosystem
(`plugins`)** (674–720), **Skills** (721–798), **Hooks** (884–907), **Observation and logs**
(1742–1973), **The store** (2169–2196) + the paging paragraph in **Store engines** (189–193),
and the `ev.*` inventory in **The bus in one screen** (377–454). Everything else is out of scope
and left to the broader audit in `var/docs-audit/mechanisms.md` (same directory) — findings that
appear there too are marked `[dup]`.

Method: `grep -n` to locate, `read` windows ≤250 lines; every claim below was checked against the
cited `file:line`. MANUAL line numbers are as of the 2324-line file in this checkout; the line
numbers of *quotes* are given where the quote alone is ambiguous.

Verified-correct (no fix, listed so they are not re-audited):
- Approval routing/ack/fallback/deny-when-unreachable (`core/approval.nim:176–250`), the
  `NIF_AUTO_APPROVE` bypass (`:271–273`), tty fallback only when `clientCount()==0 and tty`
  (`:295–296`), `ev.approval.resolved` on every verdict (`:187–191`).
- plugins: unauthenticated GitHub (`components/plugins/main.nim:34–41` — only an `Accept` header,
  no token anywhere in the file), default ref = latest release tag else default branch, `sources`
  must be non-symlink same-package Go files (`:185–201,224–227`), `interactive: true` built into
  `var/bin` but not spawned (`:259–261`), store kind `plugin` id = package name (`:130–147`),
  `plugin_update` pull-in-place + rebuild-only-if-HEAD-moved (`:412–436`).
- skills: all eight tools `onDemand` (`components/skills/main.nim:256,285,333,354,368,423,497,577`),
  200 000-byte load truncation (`:50`), directory precedence and fresh-walk-per-call (`:10–24,
  217`), `skill_remove` confined to the two managed dirs (`:577–581`), `skills.sh/api/search`
  (`:408`).
- hooks: env→name mapping (`components/hooks/main.nim:59–62`), default `ev.session.turn` (`:86`),
  timeout clamp 100–60000 (`:112–115`), payload on stdin, never interpolated (`:83–84`),
  observe-only / no veto (`:1–11`).
- observe/logfile: every `NIF_OBSERVE_*` / `NIF_LOGFILE_*` default in the MANUAL env table
  (MANUAL:315–329) matches `components/observe/main.nim:16–20,31,73–84` and
  `components/logfile/main.nim:16–19,28,32,204`; probe cap, capture byte quota + 256-file cap
  (`observe/main.nim:32,78–80`), 60 s trace expiry (`:22`), 30 s `observe_request` cap (`:392`),
  `observe_send` refusing non-`ev.*`/`llm.cancel.*` (`:366–372`), single `>` tap (`:290`).

---

## §Approvals (MANUAL 455–522)

- MANUAL: 457–467 "Tools whose schema carries `x-harness.approval: "always"` — **currently**
  `bash`, `builder.build`, `core.spawn`, … `observe_monitor` — are gated" | CODE: the list is
  incomplete as a closed set — also gated: `process_start` (`components/processes/main.nim:500`),
  `process_kill` (`:521`), `lsp_registry` (`components/lsp/main.nim:1098`), `mcp_add`/`mcp_edit`/
  `mcp_remove` (`components/mcp/main.go:98,123,134`), `agent_ask` (`components/agent/main.nim:1416`),
  `expert_follow` (assigned after registration, `components/expert/main.nim:831–832`) | FIX: update —
  the list should read "…`agent_run`, `agent_spawn`, `agent_ask`, `expert_follow`, `fabric`,
  `process_start`, `process_kill`, `lsp_registry`, `mcp_add`, `mcp_edit`, `mcp_remove`, …" and the
  sentence should end "— and any plugin tool that sets it, so the list is not closed". `[dup]`
  (mechanisms.md §X found the tool-name gap independently).

- MANUAL: absent (MANUAL:459–460 writes `core.spawn`, `core.kill`, `core.remove`) | CODE: the
  registered names are bare `spawn`/`kill`/`remove` (`core/catalog.nim:68,81,89`), and core does not
  gate them through the schema path at all — `handleCoreTool` asks by name before dispatch
  (`core/dispatch.nim:273–276`) | FIX: add one sentence to the section: "Core's own destructive tools
  are named `spawn`, `kill`, `remove` and `conversation_delete`; they are gated by name inside
  `handleCoreTool`, not through a schema, so `x-harness.approval` appears on component tools only."

- MANUAL: 491–492 "if the driver does not ack within **a short window**, the request is rebroadcast
  on `ev.approval.request` with `fallback: true`" | CODE: the window is `ackTimeoutSecs = 1.5`
  (`core/approval.nim:48`) and the rebroadcast is skipped entirely when no client is registered —
  that path logs "has no reachable client — denying", publishes `ev.approval.resolved {ok:false}`
  and denies (`core/approval.nim:216–227`) | FIX: replace "a short window" with "1.5 s
  (`ackTimeoutSecs`)", and add "with no interactive client registered the rebroadcast is skipped and
  the call is denied immediately."

- MANUAL: 496 "Unanswered UI requests time out after 5 minutes and are denied." | CODE: 5 minutes is
  the *tool* approval timeout (`core/approval.nim:55` default `timeoutMs = 300000`, used by
  `core/niffler.nim:539` and `core/session.nim:44`); the `/limit` keep-going question uses its own
  120 s (`core/approval.nim:50–51 continueTimeoutMs = 120_000`) | FIX: "A tool approval that no
  client answers times out after 5 minutes (`timeoutMs`, 300 s) and is denied; a `/limit` keep-going
  question has its own shorter window (120 s). Both log `… timed out after Ns — denying` (`core/approval.nim:243–245`)."

- MANUAL: absent (MANUAL:493–495 says only "the call is **denied** with a clear error") | CODE: the
  exact strings differ by path — component tools raise `approval denied for tool '<tool>'`
  (`core/dispatch.nim:1559`), core's own tools return `{"error": "approval denied for <tool>"}`
  (`core/dispatch.nim:276`), the unreachable-client path logs `core: <tool> needs a human but no
  interactive client is attached — denying` (`core/approval.nim:203–205`), and a granted/denied
  verdict logs `core: approval GRANTED|DENIED for <tool>` (`:239–241`) | FIX: quote the error text
  the model actually sees, so an operator can grep for it: "the caller sees `approval denied for tool
  '<name>'` (core tools: `approval denied for <name>`) as a normal tool error — the turn continues,
  nothing is retried silently."

- MANUAL: absent (nothing about program-shaped approvals) | CODE: any gated args carrying a string
  `code` get a digest-keyed manifest — digest over source + sorted `tools` + `maxCalls`
  (`core/approval.nim:69–96`), the full source written 0600 to `$NIF_ROOT/var/approval-sources/<digest>.nim`
  (`:99–121`), and the tty/UI prompt shows digest, selected tools, `maxCalls`/`timeoutMs` and the
  source path (`:139–160`) | FIX: add a short paragraph to §Approvals: "A program-shaped call
  (`fabric`, `agent_run`/`agent_spawn` with `code`) is approved by *content*, not by tool name: core
  hashes source + selected tools + `maxCalls` into a digest, writes the full source to
  `var/approval-sources/<digest>.nim` (mode 0600) and shows that path in the prompt, so the approver
  reads everything rather than a truncated excerpt. `tests/t_approval_manifest.nim` covers it."

- MANUAL: 502–505 "the per-tool 'don't ask again' record is still available for narrower trust" |
  CODE: it is store kind `approval`, id `<sessionId>:<key>` (`core/niffler.nim:580`,
  `core/session.nim:58`) — **written by clients, not core** (e.g. `niffler-tui/tui/approvals.go:151`)
  — and for program-shaped calls the key is `tool:<digest>`, deliberately never the tool name alone
  (`core/approval.nim:126–133`) | FIX: name the record and its key: "A client's 'auto approve' action
  writes a durable record (store kind `approval`, id `<sessionId>:<tool>`); for program-shaped calls
  the key is `<tool>:<digest>`, so a blanket 'always approve fabric' never covers newly written
  source. The gate never flashes a dialog when such a record matches."

- MANUAL: 516 "`NIF_AUTO_CONTINUE=1` answers every keep-going question with yes" | CODE:
  `askContinue` returns true when `NIF_AUTO_APPROVE == "1"` **or** `NIF_AUTO_CONTINUE == "1"`
  (`core/approval.nim:263`) | FIX: "`NIF_AUTO_CONTINUE=1` answers every keep-going question with yes;
  `NIF_AUTO_APPROVE=1` implies it." `[dup]`

- MANUAL: 499–501 quotes the auto-grant log line as `core: approval auto-granted for <tool>` | CODE:
  the emitted text is `core: approval auto-granted for <tool> (this conversation is in approval mode:
  auto)` (`core/approval.nim:277–280`), and the mode itself is persisted in the conversation header
  field `approvals` (`core/conversation.nim:2421,2658,2792`) | FIX: fix the quote and add "(persisted
  in the conversation header as `approvals`, so a resumed conversation keeps it — hence the same
  `auto` grant happens in a session runner, not only in the terminal harness)".

---

## §Component ecosystem (`plugins`) (MANUAL 674–720)

- MANUAL: 677–679 "plain GitHub repos with a `niffler.json` manifest at the root (one repo = one
  package = N components)" | CODE: the manifest contract is never spelled out anywhere in MANUAL —
  `name` + `components: [{name, lang, main, sources?, env?, defines?, interactive?}]`
  (`components/plugins/main.nim:153–154,163–230`) | FIX: add a small schema block: "`niffler.json` =
  `{name, components: [{name, lang: "nim"|"go"|"ts", main, sources?, env?, defines?, interactive?}]}`;
  `lang` is validated (`:219–221`), `main`/`sources` must exist and not be symlinks (`:222–227`), and a
  manifest with no components is rejected (`:230`)."

- MANUAL: absent (`defines`, `env` never mentioned) | CODE: `defines` is an array validated per
  component (`components/plugins/main.nim:205–213`) and forwarded to `builder.build`
  (`:249–256`); `env` is an array of `NAME=value` strings passed through to `core.spawn`
  (`:257–258`, and echoed in the install result) | FIX: one line each — "`defines` (array of
  `-d:`-style prepends) and `env` (array of `NAME=value`) are passed through to the builder and the
  spawn, so a package can carry its own configuration without editing the manifest."

- MANUAL: 688–691 "`plugin_install {repo, version?}` — clone `var/plugins/<pkg>@<ref>/` … then
  `core.spawn` each service component" | CODE: the clone is refused when a record for the package
  already exists ("already installed … — use plugin_update for a newer version, or plugin_remove
  first", `components/plugins/main.nim:348–351`), and the clone is shallow (`git clone --depth 1`, `:361–363`) with an
  untracked `go.work` written in to redirect a repo's sibling-checkout SDK dependency
  (`writeGoWork`, `:274,369`) | FIX: add "`plugin_install` on an already-installed package is an error,
  not a re-install — use `plugin_update` (or `plugin_remove` first); the clone is shallow and carries an
  untracked `go.work` for Go packages that expect a sibling SDK checkout."

- MANUAL: 680 "`plugin_search {query?}` — GitHub topic search; returns repo, description, stars" |
  CODE: a zero-hit multi-word query is retried with fewer words, and the reply carries `query`
  (winning), `attempts`, `tried` and an install `hint` (`components/plugins/main.nim:520–600`);
  results do not include an install count | FIX: extend the row: "returns `repo`, `description`,
  `stars` (plus the winning `query` and per-attempt diagnostics — GitHub ANDs query words, so a
  zero-hit query is retried with fewer words)."

- MANUAL: 712 "The GitHub API is used unauthenticated (60 req/h/IP)." | CODE: verified — no token or
  `Authorization` header is read anywhere in `components/plugins/main.nim` (headers set at `:41`);
  no `NIF_GITHUB_TOKEN` exists | FIX: none (keep the warning; it is the honest rate limit).

---

## §Skills (MANUAL 721–798)

- MANUAL: absent (front-matter keys are never listed) | CODE: parsed keys are `name`, `description`,
  `version`, `license`, `tags`, `allowed-tools` (`components/skills/main.nim:64–67,120–125`), and
  `skill_list` returns name/description/version/**license**/tags/**allowedTools**/source/dir
  (`:249–251`) | FIX: add the contract to the section: "A SKILL.md is YAML frontmatter + markdown:
  `name`, `description`, `version`, `license`, `tags` (list) and `allowed-tools` (list) are the keys
  Niffler reads; `skill_list` surfaces license and allowedTools too — `allowed-tools` is metadata the
  model reads, not an enforced restriction."

- MANUAL: 771–772 "marks the active winner per name and every shadowed/invalid copy (invalid =
  unreadable SKILL.md, unparseable frontmatter, **or no `name`**)" | CODE: `name` falls back to the
  skill's *directory name* (`components/skills/main.nim:120`, called as
  `parseSkillMarkdown(readFile(path), skillDir.splitFile.name)` at `:137`), and the entry is only
  rejected when the name is empty *after* that fallback (`:127–128`) | FIX: correct the definition —
  "invalid = unreadable SKILL.md, unparseable frontmatter, or no name **even after falling back to the
  directory name**; a SKILL.md that omits `name:` is accepted under the name of its directory."

- MANUAL: 764 "`skill_load {name}` … a body over 200 000 bytes is truncated with `truncated: true`" |
  CODE: `const MaxContentBytes = 200_000` (`components/skills/main.nim:50`) | FIX: none.

- MANUAL: 762 "`skill_search {query, owner?}` — online search of the skills.sh registry" | CODE: the
  call is `https://skills.sh/api/search?q=…&limit=20` with `owner` as a query refinement
  (`components/skills/main.nim:404–420`) | FIX: add "(20 results per call; `owner` narrows the query,
  it is not a separate namespace)".

- MANUAL: absent (nothing says whether skills keep state) | CODE: `components/skills/main.nim` never
  calls the store — no `storePut`/`storeGet` in the file; installs are plain file copies
  (`:503–522`) | FIX: add one sentence to the intro: "The component keeps no store records and no
  cached registry — an install is a file copy into a scanned directory, which is why a fresh walk sees
  it immediately and why `--recover` cannot lose it."

- MANUAL: 788–797 install/remove table rows and the `global` flag | CODE: `global: bool = true` →
  `~/.niffler/skills`, `false` → `$NIF_ROOT/.opencode/skills` (`components/skills/main.nim:501,513,522`);
  `skill_remove` refuses anything outside those two dirs (`:577–581`) | FIX: none (accurate).

---

## §Hooks (MANUAL 884–907)

- MANUAL: 887–889 "the decoded event payload is piped to the command's stdin as pretty JSON, the
  command itself is never interpolated with event data, failures and timeouts (default 10s, max 60s)
  are logged and never fatal" | CODE: exact, with two limits MANUAL omits — the payload is capped at
  256 000 bytes with `\n...[truncated]` appended (`components/hooks/main.nim:40,63–67`), and the
  payload travels via a temp file `niffler-hook-<pid>-<n>.json` piped in as
  `cat <file> | <command>` (`:76–84`) | FIX: append "Payloads are capped at 256 KB (a truncation
  marker is appended) and handed to the hook through a temp file, so a hook can `cat` stdin or seek it."

- MANUAL: 892–894 example config block | CODE: `NIF_HOOKS_TIMEOUT_MS` is clamped to 100–60000
  (`components/hooks/main.nim:112–115`) — MANUAL:338 already says "values above 60000 are clamped",
  but the prose example block gives no floor, and the hook runs through `sh -c` with the SDK's
  `runCmd`, whose timeout kill exits 124 (`:88–90`, `sdk/procutil`) | FIX: add "(floor 100 ms; a
  timeout kills the process group and logs exit 124)".

- MANUAL: 898 "`NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"` # subjects to watch" | CODE:
  matching is first-spec-wins (`components/hooks/main.nim:52–58`), the component always taps
  `ev.session.>` and adds one tap per configured spec outside that namespace, so both a concrete
  subject and a trailing-`>` prefix work (`:118–135`); a spec whose command env var is unset is
  silently dropped at boot (`:105–109`) | FIX: add "Matching is first-match-wins over the
  comma-separated list; a subject whose `NIF_HOOKS_<SUBJECT>` is unset is ignored at startup (the
  component logs `watching …` only for the ones it will run)."

- MANUAL: 884 "The `hooks` component (off by default)" | CODE: off-by-default is
  `manifest.yaml:212–218` (`autostart: false`, `required: false`, `restart: on-failure`) while the
  binary is still built by `make all` (`Makefile:266–269`, `:298`) | FIX: append "(built anyway, so
  enabling it is `NIF_HOOKS_*` + `core.spawn hooks var/bin/hooks` — no rebuild needed)".

- MANUAL: absent (nothing says where hook failures land) | CODE: hook stdout/stderr go to the hook's
  own stderr → the supervisor's `var/logs/hooks.log` (`core/supervisor.nim:126–138,202`), never into
  logfile's `var/logs/*.jsonl` (logfile only persists what it hears, default `ev.log.>`) | FIX: add to
  the section: "Failures are written to the component's own stderr, which the supervisor captures in
  `var/logs/hooks.log` — hook output never appears in logfile's JSONL, which persists bus traffic only."

- MANUAL: 906–907 "Worked examples … live in `components/hooks/README.md`" | CODE: the README exists
  (116 lines, `components/hooks/README.md`) — but the component's own header comment points at
  `docs/HOOKS.md` (`components/hooks/main.nim:2`), and **`docs/` contains no HOOKS.md** | FIX: fix the
  code comment (not MANUAL) to cite `components/hooks/README.md`, or add the missing doc.

---

## §Observation and logs (MANUAL 1742–1973)

- MANUAL: 1746–1757 "Boundary … Observe the bus, not component internals" | CODE: correct, but the
  section never states the negative half — none of `observe`, `logfile`, `console` is a durable
  record of *decisions*: observe keeps a bounded in-memory ring (`components/observe/main.nim:16–20`),
  logfile is explicitly best-effort (MANUAL:1808 says so), console renders and forgets
  (`components/console/main.nim:75–105`), hooks keep nothing | FIX: add a "Not an audit trail" list to
  §Boundary: "None of these is an audit log: observe is a bounded in-memory ring that dies with the
  component, logfile is best-effort (at-most-once, `ev.log.>` by default), console prints and forgets,
  and hooks record nothing. The only durable artefacts of the approval gate are the client-written
  grant record (store kind `approval`) and the program source core writes to
  `var/approval-sources/<digest>.nim` — no request/verdict history exists."

- MANUAL: absent (`var/approval-sources/` is nowhere in MANUAL, not even the `var/` row of the state
  table at MANUAL:244, which lists `logs/`, `captures/`, `processes/` …) | CODE:
  `core/approval.nim:99–121` creates `$NIF_ROOT/var/approval-sources/<digest>.nim` with mode 0600 |
  FIX: add `approval-sources/` (0600 program source awaiting/recorded for approval) to the `var/` row
  and to §Approvals.

- MANUAL: 1785 table row "`observe_monitor` | Read nats-server connection/subscription counts and
  most-subscribed patterns" | CODE: the tool carries `approval: always` (`components/observe/main.nim:714`)
  like `observe_send`/`observe_request`/`observe_dump` — MANUAL says this two paragraphs later
  (1791–1794) but the table column reads as a plain read | FIX: add "(approval-gated — it borrows the
  operator's monitoring endpoint)" to the row, or move the gate marker into the table for all four.

- MANUAL: 1791–1794 "A client talking directly to `svc.observe.call` is already a trusted bus peer and
  bypasses core policy" | CODE: matches the design (the gate lives in `core/dispatch.nim:1556–1559`,
  not in the component) | FIX: none — but consider one clause: "the component itself enforces only its
  own input/subject validation (`components/observe/main.nim:366–372,392`)."

- MANUAL: 1946–1952 "`NIF_OBSERVE_MONITOR_URL` explicitly … `observe_monitor` reads `/subsz` and
  `/connz` with a fresh HTTP client for each request" | CODE: `components/observe/main.nim:719`
  (`NIF_OBSERVE_MONITOR_URL`) and `:727` (`proc fetch` per request) | FIX: none.

- MANUAL: 1961–1973 Verification section names `tests/t_observe.nim` and `tests/t_logfile.nim` | CODE:
  both exist and are wired into `make test-server` (`tests/t_observe.nim`, `tests/t_logfile.nim`,
  `Makefile:501` for hooks) — but `tests/t_hooks.nim` is not named anywhere in MANUAL | FIX: add
  "`tests/t_hooks.nim` covers env→subject mapping, stdin payload delivery and timeout behaviour" to
  the hooks section or to §Testing.

---

## §The store (MANUAL 2169–2196) + paging (MANUAL 189–193)

- MANUAL: 189–193 "`list` is a **page**, not a complete view: it is capped at 1000 items and returns
  `hasMore` plus an `nextAfter` id cursor. Pass `nextAfter` back as `after` to walk the rest" | CODE:
  accurate, and the numbers behind it are: `limit` defaults to **100** and is clamped by
  `min(limit, 1000)` (`components/store/main.nim:130,151`), `after` is an *exclusive* full document
  id (`:145–150`), `nextAfter` is emitted only when `hasMore` and the page was non-empty and comes
  from the last **key**, not the last returned item, so an all-tombstoned page still advances
  (`:159–168`) | FIX: add the missing default and the cursor rule — "`limit` defaults to 100 (max
  1000); `after` is exclusive, so pass `nextAfter` (or `items[^1].id`) back verbatim; `nextAfter` is
  absent when `hasMore` is false. `core/dispatch.nim` `storeListAll` is the paging helper core uses
  for full-kind reads (resume, `session_info`, `conversation_delete`)."

- MANUAL: 2169–2196 §The store never mentions paging at all, while the only statement of it lives in
  §Store engines (189–193) | CODE: the canonical contract is the store tool's own docstring
  (`components/store/main.nim:130–150`) and `core/dispatch.nim:202–235` (`storeListAll` vs capped
  `storeListItems` at `:189–200`) | FIX: move/summarize the paragraph into §The store (with a
  cross-link from §Store engines) and add "everything in core that must see a whole kind goes through
  `storeListAll` — a single `list` silently truncated long transcripts on resume."

- MANUAL: 2172–2190 kind table | CODE: the table omits core kinds actually written today —
  `profile` (`core/dispatch.nim:394`), `approval` (read `core/niffler.nim:580`,
  `core/session.nim:58`; written by clients), `contextreceipt` (`core/conversation.nim:296`),
  `compaction_input` (`:1424–1426`, read `:1315`), `context_projection` (`:1579`), `spill` (`:1196`) |
  FIX: extend the table with those six, one row each, with a one-line value description (e.g.
  "`spill` | `<convId>:<n>` | oversized tool result spilled out of the context window";
  "`approval` | `<sessionId>:<key>` | a client's 'don't ask again' grant, keyed by tool or
  `tool:<digest>` for program-shaped calls").

- MANUAL: 2172–2190 kind table, component kinds | CODE: also missing `mcp`
  (server config records: `components/mcp/types.go:12`, written `components/mcp/main.go:581`, listed
  `:170`), and the transient `selftest` kind the store's own self-test writes and deletes
  (`components/store/main.nim:189,219`) | FIX: add the `mcp` row (id = server name; the MCP
  section, MANUAL:1165–1198, describes the record but never names the kind) and note `selftest` is
  throwaway.

- MANUAL: absent (nothing says who may write which kind) | CODE: a call arriving with a live session
  may only `put` curated kinds — everything except `fabricprog` is refused with
  `forbidden-kind`/`"<kind>' is harness-managed"` (`components/store/main.nim:100–105`); `del` is
  `hidden` from the LLM and core-only (`components/store/main.nim:171–178`) | FIX: add to §The store: "A session-bound caller
  may only write curated kinds (`fabricprog` today); every other kind is harness-managed and refused
  with `forbidden-kind`. `get`/`list` are on-demand tools; `del` is hidden (core deletes records, the
  model cannot)."

- MANUAL: absent (minor) | CODE: the store tool docstrings claim a kind inventory that is stale —
  `get` says "Kinds in use: conversation, message, component" (`components/store/main.nim:120–122`),
  `list` similar (`:130–135`) | FIX: not a MANUAL change; if the docstrings stay, MANUAL's kind table
  should be the authoritative list (they are the LLM-visible text, so a pointer sentence in the
  section is cheap).

---

## §The bus in one screen (MANUAL 377–454) — `ev.*` inventory

- MANUAL: 386–421 subject block | CODE: the block omits events that are live today —
  `ev.log.<component>` (structured logs; `sdk/go/component.go:302`, Nim/TS equivalents),
  `ev.workspace.opened` (`core/conversation.nim:2388`), `ev.lsp.warm`
  (`components/lsp/main.nim:1049`), `ev.agent.started`/`ev.agent.done`/`ev.agent.notice`
  (`components/agent/main.nim:1237,958,183`), and the fabric family
  `ev.fabric.started`/`phase`/`log`/`call.started`/`call.done`/`done`
  (`components/fabric/fabric.nim:770,354,362,292,368,794`) | FIX: add those six groups to the block
  (or to a compact table, see below), noting that `ev.session.*` is emitted dynamically from one
  helper (`core/conversation.nim:2701–2703`), so the list is the contract, not the code path.

- MANUAL: 388–395 `ev.session.*` rows | CODE: all seven exist, emitted from
  `onEvent("…")` in `core/conversation.nim` (e.g. `context` at `:776,789,841`, `advice` at `:999`),
  and `ev.session.turn`/`assistant`/`token` are the UI's live-bubble inputs (MANUAL:415–421
  streaming paragraph matches `ev.llm.token` → `ev.session.token`) | FIX: none (verified), but the
  rows would read better with an emitting-component column (core / llm / agent / fabric).

- MANUAL: 189 typo "plus an `nextAfter` id cursor"; MANUAL:398–400 block formatting (a stray `#` in
  a comment column) | FIX: "a `nextAfter` id cursor"; drop the stray comment markers.

---

## Wrong claims (summary)

1. MANUAL:457–467 presents the approval-gated tool list as complete ("currently …") — ten gated tools
   are missing (see §Approvals, finding 1).
2. MANUAL:491–492 "a short window" — it is 1.5 s, and the fallback is skipped when no client is
   registered (core/approval.nim:48,216–227).
3. MANUAL:496 makes the 5-minute timeout universal — the `/limit` keep-going question times out at
   120 s (core/approval.nim:50–51).
4. MANUAL:771–772 "invalid = … or no `name`" — a missing `name:` falls back to the directory name and
   is accepted (components/skills/main.nim:120,133).
5. MANUAL:459 (`core.spawn`, `core.kill`, `core.remove`) names tools that do not exist under those
   names (`spawn`/`kill`/`remove`, core/catalog.nim:68,81,89) and does not say core gates them by name
   rather than by schema (core/dispatch.nim:273–276).
6. MANUAL:190 "capped at 1000 items" without the `limit` default of 100, which is what a caller
   omitting `limit` actually gets (components/store/main.nim:130,151).
7. MANUAL:386–421 bus block is presented as the subject inventory but omits `ev.log.*`,
   `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`, `ev.fabric.*` (file:line in the table below).
8. MANUAL:2172–2190 kind table is labelled "kinds in use by core" yet omits six core kinds and the
   `mcp` component kind (file:line in the table below).
9. Not a MANUAL claim but code-side wrong pointer: `components/hooks/main.nim:2` cites `docs/HOOKS.md`,
   which does not exist.

## Kind / event inventory worth documenting

Store kinds written today (grep `put(kind`/`storePut*`/`StorePut` across `core/`, `components/`):

| Kind | Id | Written by | Value / note |
|---|---|---|---|
| `conversation` | `conv-<ts>` | core (`core/conversation.nim:241,417,446`) | header: model, thinking, profile, budgets, `approvals` mode, frozen system prompt (MANUAL:2174 ✔) |
| `message` | `<convId>:<seq>` | core (`:266`), agent fork (`components/agent/main.nim:493`) | transcript |
| `component` | `<name>` | core (`core/dispatch.nim:318`) | persisted shape (MANUAL ✔) |
| `plugin` | package name | plugins (`components/plugins/main.nim:144`) | install record (MANUAL ✔) |
| `provider` | nickname + `active` | provider (`components/provider/main.go`, kind const `:37`) | redacted registry (MANUAL ✔) |
| `session` | `<sessionId>:tools` | core (`core/conversation.nim:487,1167`) | frozen direct toolset (MANUAL ✔) |
| `slash` | `slash` | core (`core/niffler.nim:562`) | merged slash table (MANUAL ✔) |
| `agentjob` | `<jobId>` | agent (`components/agent/main.nim:931,1216`) | background job record (MANUAL ✔) |
| `agentnotice` | `<parent>:<seq>` | agent (`:177,1396`) | settlement notice (MANUAL ✔) |
| `sessionmeta` | `<sessionId>` | agent (`:585,752,1113`) | lineage/activations/closed (MANUAL ✔) |
| `fabricprog` | program name | fabric / curated (`components/fabric/fabric.nim:682`) | the one kind a session may write |
| `mcp` | server name | mcp (`components/mcp/main.go:581`, kind `types.go:12`) | **missing from MANUAL** |
| `profile` | profile name | core (`core/dispatch.nim:394`) | **missing** |
| `approval` | `<sessionId>:<key>` | clients (`niffler-tui/tui/approvals.go:151`); read core (`core/niffler.nim:580`) | **missing** |
| `contextreceipt` | `<convId>:<requestId>` | core (`core/conversation.nim:296`) | **missing** |
| `compaction_input` | `<convId>:<n>` | core (`core/conversation.nim:1424–1426`) | **missing** |
| `context_projection` | `<convId>` | core (`core/conversation.nim:1579`) | **missing** |
| `spill` | `<convId>:<n>` | core (`core/conversation.nim:1196`) | **missing** |
| `selftest` | store self-test | store, deleted in place (`components/store/main.nim:189,219`) | throwaway |

Events (`ev.*` / `llm.*`) emitted today:

| Subject | Emitter (file:line) | Note |
|---|---|---|
| `ev.session.turn` / `assistant` / `status` / `token` / `toolcall` / `advice` / `done` / `context` | core, dynamically (`core/conversation.nim:2701–2703`, e.g. `:776,999`) | MANUAL:388–395 ✔ |
| `ev.llm.token` | llm/core (`core/conversation.nim:891`) | re-emitted as `ev.session.token` (MANUAL:415–421 ✔) |
| `ev.approval.request` / `.reply` / `.resolved` | core (`core/approval.nim:58,191,201,216`) | MANUAL ✔ |
| `ev.log.<component>` | every SDK (`sdk/go/component.go:302`) | MANUAL:1928 ✔, absent from the bus block |
| `ev.catalog.updated` | core (`core/catalog.nim:604`) | MANUAL ✔ |
| `ev.sys.drain` | core (`core/supervisor.nim:257`) | MANUAL ✔ |
| `ev.workspace.opened` | core (`core/conversation.nim:2388`) | **absent** |
| `ev.lsp.warm` | lsp (`components/lsp/main.nim:1049`) | **absent** |
| `ev.agent.started` / `.done` / `.notice` | agent (`components/agent/main.nim:1237,958,183`) | **absent** |
| `ev.fabric.started` / `.phase` / `.log` / `.call.started` / `.call.done` / `.done` | fabric (`components/fabric/fabric.nim:770,354,362,292,368,794`) | **absent** |
| `svc.session.<id>.steer` | clients/core (`components/agent/main.nim:146`, `components/processes/main.nim:468`) | MANUAL:383 ✔ |
| `llm.cancel.<sessionId>` | core/agent (`components/agent/main.nim:194`) | MANUAL:421 ✔ |
| `cancel.<component>` | runner (`core/dispatch.nim` cancellation path) | MANUAL:410–413 ✔ |

## Point elsewhere instead of duplicating

- **Approval transport shapes** (`svc.approval.<name>.request`, `ev.approval.reply/resolved`, the
  `{id, ack}` protocol): keep the normative copy in `docs/WIRE.md`; MANUAL should describe *policy*
  (who is asked, when it denies) and link, not restate envelope fields — it currently restates them
  twice (MANUAL:388–411 and 465–495).
- **Hook examples and per-platform one-liners**: `components/hooks/README.md` (MANUAL already points
  there, MANUAL:906–907). Fix `components/hooks/main.nim:2`'s dangling `docs/HOOKS.md` reference.
- **Store paging contract**: `components/store/main.nim` `list` docstring (the LLM-visible text) is
  canonical; core's helper is `core/dispatch.nim:202–235`. State it once in §The store and link from
  §Store engines.
- **Observe/logfile bounds**: keep the env table (MANUAL:315–329) as the single numeric source;
  §Observation and logs should describe behaviour and point at `components/observe`,
  `components/logfile` and `tests/t_observe.nim`, `tests/t_logfile.nim`, `tests/t_hooks.nim` rather
  than repeating caps (it currently repeats several: 256-file cap, 256 KB payload, 64 KiB response).
- **SKILL.md front-matter keys**: the [Agent Skills](https://agentskills.io) spec is the normative
  source for `name`/`description`/`license`/`allowed-tools`; MANUAL should name which keys Niffler
  *reads* and link out for the rest.
- **`niffler.json` manifest schema**: `components/plugins/main.nim:153–230` is the validator; MANUAL
  should carry a 6-line schema plus the `gokr/niffler-weather` pointer it already has (MANUAL:715–720).
