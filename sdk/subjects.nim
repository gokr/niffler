## Session subject builders + bus discovery — the wire-spec counterpart
## to the envelope.
##
## Session ids become NATS subject tokens (svc.session.<id>.call) and
## catalog component names, so they must be sanitized the same way
## everywhere. Pure std (no NATS, no process APIs): core (which speaks
## only the envelope wire format) imports this just like sdk/envelope.nim.

import std/[os, strutils]

proc resolveNatsUrl*(root = ""): string =
  ## Bus address: NIF_NATS_URL env → <root>/var/nats-url discovery file →
  ## the well-known local default.
  result = getEnv("NIF_NATS_URL")
  if result.len > 0: return
  let r = if root.len > 0: root else: getEnv("NIF_ROOT", ".")
  let disc = r / "var" / "nats-url"
  if fileExists(disc):
    let u = readFile(disc).strip()
    if u.len > 0: return u
  return "nats://127.0.0.1:4222"

proc rootDir*(): string =
  ## Harness root: NIF_ROOT or the working directory.
  getEnv("NIF_ROOT", ".")

proc rootVarDir*(name: string): string =
  ## Path under the harness root's var/ runtime state dir (not created —
  ## call createDir where a component writes).
  rootDir() / "var" / name

proc sanitizeSessionId*(s: string): string =
  ## Session ids become a NATS subject token (svc.session.<id>.call) and a
  ## catalog component name; keep alnum/-/_ and replace everything else.
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '-')

proc runnerName*(sessionId: string): string =
  ## Catalog component name of a conversation's session runner process.
  "session-" & sanitizeSessionId(sessionId)

proc sessionCallSubject*(sessionId: string): string =
  ## Request/reply subject of a session runner (queue "session").
  "svc.session." & sanitizeSessionId(sessionId) & ".call"

proc sessionSteerSubject*(sessionId: string): string =
  ## Fire-and-forget channel a client publishes to in order to inject a
  ## message into a RUNNING turn (folded in between LLM rounds).
  "svc.session." & sanitizeSessionId(sessionId) & ".steer"

proc sessionToolSubject*(sessionId: string): string =
  ## Nested-call proxy for session-context tools (fabric, agent): generated
  ## programs route every tool call here; the runner's pump validates the
  ## live lease and re-enters the one dispatch gate.
  "svc.session." & sanitizeSessionId(sessionId) & ".tool"

proc sessionAdviseSubject*(sessionId: string): string =
  ## Turn-bound advisory request/reply subject (expert → runner): accepted
  ## only while the addressed turn is still live (EXPERT.md).
  "svc.session." & sanitizeSessionId(sessionId) & ".advise"
