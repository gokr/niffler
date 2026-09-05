## console component — follow the bus from a terminal.
##
## A passive bus citizen: subscribes to everything and renders the wire
## traffic as a readable stream (envelopes decoded, tool calls flattened).
## Zero tools, zero state — the diagnostic twin of `nats sub '>'`, with
## the envelope rendered instead of raw JSON lines.
##
## Run it in a separate terminal while the harness runs:
##   NIF_NATS_URL=nats://127.0.0.1:4222 ./var/bin/console
## (or just ./var/bin/console — it follows the harness's var/nats-url
## discovery file, then defaults to the local bus, same as every component.)

import std/[json, os, strutils, times]
import natswrapper
import envelope
import dotenv
import subjects
when defined(posix):
  import std/posix

proc ts(): string =
  let t = now()
  result = t.format("HH:mm:ss") & "." & align($(t.nanosecond div 1_000_000), 3, '0')

proc styled(s: string, code: int): string =
  when defined(posix):
    if isatty(getFileHandle(stdout)) > 0:
      return "\e[" & $code & "m" & s & "\e[0m"
  result = s

proc chop(s: string, n: int): string =
  if s.len <= n: return s
  result = s[0 ..< n] & "…"

proc render(subject: string, data: string) =
  let env = decode(data)
  let kind = $env.kind
  case env.kind
  of ekCall:
    echo ts() & " " & styled("call  ", 36) & subject & "  " &
         styled(env.tool, 1) & " " & chop($env.args, 300)
  of ekResult:
    echo ts() & " " & styled("result", 32) & "  " &
         styled(env.tool, 1) & " → " & chop($env.args, 500)
  of ekError:
    echo ts() & " " & styled("error ", 31) & "  " &
         styled(env.tool, 1) & " ! " & chop($env.error, 300)
  of ekEvent:
    let payload = if env.payload == nil: "" else: $env.payload
    if subject == "ev.session.assistant":
      # model text: render content directly (it is the conversation)
      echo ts() & " " & styled("assistant", 33) & "  " &
           chop(payload, 2000)
    else:
      echo ts() & " " & styled("event ", 35) & subject & "  " &
           chop(payload, 500)

proc resolveBusUrl(): string =
  ## NIF_NATS_URL wins; otherwise follow the harness's discovery file so a
  ## randomly-port bus still answers, defaulting to the canonical 4222
  ## (SDK's resolveNatsUrl — the same order every client follows).
  resolveNatsUrl()

proc followBus() =
  ## Connect, announce, and follow the bus until the connection is lost,
  ## then return so the caller can retry. The discovery file is re-read on
  ## every attempt, so a harness restarting on a new random port is found.
  let url = resolveBusUrl()
  var nc = connect(url)

  # announce so the catalog (and core's log) sees us, like the ui component
  let reg = %*{"name": "console", "version": "0.1.0",
                "pid": getCurrentProcessId(), "tools": newJArray()}
  nc.publish("reg.publish", $reg)

  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, ">".cstring)
  if not checkStatus(st):
    raise newException(IOError, "subscribe >: " & getErrorString(st))

  echo styled("console: following the bus at " & url &
              " — every envelope the harness speaks.", 2)
  while true:
    var msg: ptr natsMsg
    let ns = natsSubscription_NextMsg(addr msg, sub, 200)
    if ns == NATS_OK:
      let subject = $natsMsg_GetSubject(msg)
      let data = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      render(subject, data)
    elif ns == NATS_TIMEOUT:
      discard  # idle — the normal quiet-bus path
    else:
      # connection lost (nats.c abandons its reconnect budget after ~2min
      # of unreachable server) or the subscription went invalid: NextMsg
      # then fails INSTANTLY, so this must not fall through to a tight loop.
      echo styled("console: bus connection lost — reconnecting…", 3)
      nc.close()
      return

loadDotEnv(".env", rootDir() / ".env")
while true:
  try:
    followBus()
  except CatchableError as e:
    echo styled("console: " & e.msg & " — retrying in 2s", 3)
  sleep(2000)
