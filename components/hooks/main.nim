## hooks component — run shell commands when selected bus events fire
## (CodeWhale borrow, docs/research/CODEWHALE.md → docs/HOOKS.md, observe-
## only subset). A hook is a plain process: the event payload arrives as
## JSON on stdin, timeout enforced, failures logged to stderr and never
## fatal — hooks must never break the harness.
##
## Deliberately NOT borrowed (yet): steering (deny/ask/allow verdicts).
## Niffler's approval gate lives in core dispatch; a hooks component that
## could veto calls would need to sit inside that gate — a separate,
## carefully-designed plan. This component only observes.
##
## Configuration (env, read at boot — config changes are core.kill +
## core.spawn, the harness's hot-change idiom):
##   NIF_HOOKS_EVENTS      comma-separated subjects to watch, default
##                         "ev.session.turn" (one per finished user turn).
##                         Trailing '>' wildcards work (expert-style).
##   NIF_HOOKS_<SUBJECT>   the command to run for that subject, dots and
##                         '>' mapped to underscores:
##                         ev.session.turn → NIF_HOOKS_EV_SESSION_TURN
##                         ev.log.>        → NIF_HOOKS_EV_LOG_
##   NIF_HOOKS_TIMEOUT_MS  per-hook timeout, default 10000, max 60000.
##
## The hook command runs through `sh -c` (operator-provided, same trust
## level as the harness itself); the decoded event payload is piped to the
## command's stdin as pretty JSON — never interpolated into the command
## line. Worked examples (desktop notification, sound, email, webhook)
## live in components/hooks/README.md.

import std/[envvars, json, os, osproc, sequtils, strutils, times]
import natswrapper
import niffler/sdk
  # re-exports sdk/procutil: runCmd (temp-file capture, timeout kill)

const maxPayloadBytes = 256_000
  ## payload cap: an event payload is a summary, not a transcript.

proc hookEnvFor(subject: string): string =
  ## ev.session.turn → NIF_HOOKS_EV_SESSION_TURN; '>' collapses to '_'
  ## (so ev.log.> → NIF_HOOKS_EV_LOG_).
  "NIF_HOOKS_" & subject.toUpperAscii().multiReplace((".", "_"), (">", "_"))

var hookCounter = 0
  ## Payload temp files are serialized (single-threaded SDK poll loop), so
  ## a plain counter keeps names unique across hook runs.

type
  Hook = tuple[subject, command: string]

proc matchHook(hooks: seq[Hook], subject: string): string =
  ## First matching spec wins; a trailing '>' prefix-matches.
  for (s, cmd) in hooks:
    if s == subject or (s.endsWith(">") and
                        subject.startsWith(s[0 ..< ^1])):
      return cmd
  return ""

proc runHook(command, subject, payload: string, timeoutMs: int) =
  var body = payload
  try:
    let env = decode(payload)
    if env.payload != nil:
      body = env.payload.pretty
  except CatchableError:
    discard  # not an envelope — pass raw bytes through
  if body.len > maxPayloadBytes:
    body = body[0 ..< maxPayloadBytes] & "\n...[truncated]"
  # The command comes from the operator's own env (same trust level as
  # the harness itself); the payload travels through a temp file piped
  # to stdin by the subshell — never interpolated into the command line.
  # sdk/procutil.runCmd captures output through a temp file (pipes
  # deadlock chatty children) and owns the timeout kill (exit 124).
  inc hookCounter
  let payloadPath = getTempDir() /
    ("niffler-hook-" & $getCurrentProcessId() & "-" & $hookCounter & ".json")
  try:
    writeFile(payloadPath, body)
    let wrapped = "cat " & quoteShell(payloadPath) & " | " & command
    let r = runCmd(wrapped, timeoutMs)
    if r.code != 0:
      stderr.writeLine("hooks: exit " & $r.code & " on " & subject &
                       (if r.output.strip.len > 0: "\n" & r.output.strip else: ""))
  except CatchableError as e:
    stderr.writeLine("hooks: failed on " & subject & ": " & e.msg)
  finally:
    try: removeFile(payloadPath)
    except CatchableError: discard

proc main() =
  let comp = newComponent("hooks", "0.1.0")
  let root = getEnv("NIF_ROOT", getCurrentDir())
  loadDotEnv(".env", root / ".env")

  let timeoutMs = block:
    try:
      clamp(parseInt(getEnv("NIF_HOOKS_TIMEOUT_MS", "10000")), 100, 60_000)
    except CatchableError:
      10_000

  var hooks: seq[Hook] = @[]
  for subject in getEnv("NIF_HOOKS_EVENTS", "ev.session.turn").split(','):
    let s = subject.strip()
    if s.len == 0: continue
    let cmd = getEnv(hookEnvFor(s))
    if cmd.len > 0:
      hooks.add((s, cmd))

  if hooks.len == 0:
    echo "hooks: no hooks configured (set NIF_HOOKS_<EVENT>, see " &
         "components/hooks/README.md) — watching nothing, staying up"
  else:
    for (s, _) in hooks:
      echo "hooks: watching " & s

  if hooks.len > 0:
    let subjects = hooks.mapIt(it.subject)
    discard comp.tap("ev.session.>", proc(c: Component, subject: string,
                                          data: string) =
      # Single tap on the session namespace plus per-spec direct matches:
      # env-configured subjects outside ev.session.* (e.g. ev.log.>) get
      # their own tap below; matching is by spec, the tap is just transport.
      let cmd = matchHook(hooks, subject)
      if cmd.len > 0:
        runHook(cmd, subject, data, timeoutMs))
    for s in subjects:
      if not s.startsWith("ev.session."):
        let cmd = matchHook(hooks, s)
        discard comp.tap(s, proc(c: Component, subject: string,
                                 data: string) =
          # The tap pattern already narrows; still match in case the spec
          # used a wider wildcard than the tap (e.g. spec ev.log.>).
          let chosen = matchHook(hooks, subject)
          if chosen.len > 0:
            runHook(chosen, subject, data, timeoutMs))

  comp.run()

when isMainModule:
  main()
