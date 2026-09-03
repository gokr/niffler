## Niffler admin shell — the tty REPL of the system harness (stdin/stdout).
##
## NOT a conversation UI: it only inspects the harness itself (status,
## catalog, tools, sessions). The LLM chat lives in the web UI and the
## niffler-tui plugin; scripting goes through the cli component (pipeline
## friendly, non-interactive). While waiting for input the shell keeps
## pumping the bus so UIs stay responsive (svc.core.call keeps being served).

import std/[algorithm, json, os, osproc, sequtils, strformat, strutils, tables, times]
when defined(posix):
  import std/posix
import catalog
import dispatch
import supervisor

const
  prompt = "niffler> "
  maxHistory = 100

const commands = [
  ("help",     "show this help"),
  ("status",   "system state: bus, uptime, components, children, sessions"),
  ("catalog",  "registered components (name, version, pid, tools)"),
  ("tools",    "every non-hidden tool and the component providing it"),
  ("sessions", "conversations in the store + live session runners"),
  ("exit",     "leave the shell (also quit / Ctrl-D)"),
]

# Module load ≈ binary start: good enough for the uptime readout.
var bootTime = epochTime()

proc humanDuration(s: float): string =
  let total = int(s)
  let d = total div 86400
  let h = (total mod 86400) div 3600
  let m = (total mod 3600) div 60
  if d > 0: result = $d & "d " & $h & "h"
  elif h > 0: result = $h & "h " & $m & "m"
  elif m > 0: result = $m & "m " & $(total mod 60) & "s"
  else: result = $total & "s"

# ---------------------------------------------------------------------------
# Raw-mode line editor (posix): arrow-key history + tab completion.
# stty instead of termios FFI — portable across Linux/macOS, no struct layout
# games. ISIG stays enabled so Ctrl-C still delivers SIGINT.

type
  Editor = ref object
    line: string
    hist: seq[string]
    histIdx: int      ## -1 = not browsing history
    histDraft: string

when defined(posix):
  proc rawMode(on: bool) =
    let arg = if on: "-icanon -echo" else: "icanon echo"
    try:
      discard execCmd("stty " & arg & " < /dev/tty 2>/dev/null")
    except CatchableError:
      discard

  proc draw(ed: Editor) =
    stdout.write("\r\e[2K" & prompt & ed.line)
    stdout.flushFile()

  proc readKey(): string =
    ## One key; "" on EOF. Escape sequences are collapsed to names.
    var b: char
    if read(0, addr b, 1) != 1: return ""
    case b
    of '\e':
      var seq = ""
      while seq.len < 2:
        var fds = [Tpollfd(fd: 0, events: POLLIN, revents: 0)]
        let r = poll(addr fds[0], 1, 50)
        if r <= 0: return "escape"
        var c: char
        if read(0, addr c, 1) != 1: return "escape"
        seq.add(c)
      case seq
      of "[A": return "up"
      of "[B": return "down"
      of "[C": return "right"
      of "[D": return "left"
      else: return "escape"
    of '\r', '\n': return "enter"
    of '\t': return "tab"
    of '\x7f', '\x08': return "backspace"
    of '\x04': return "eof"
    else: return $b

  proc complete(ed: Editor) =
    let names = commands.mapIt(it[0])
    let matches = names.filterIt(it.startsWith(ed.line))
    if matches.len == 1:
      ed.line = matches[0] & " "
      draw(ed)
    elif matches.len > 1:
      echo "\n" & matches.join("  ")
      draw(ed)

  proc dropLastRune(s: string): string =
    ## Delete the last character, not the last byte: a CJK rune occupies
    ## 3 bytes, so a byte-wise backspace would leave broken UTF-8 on the
    ## line. Walk back over continuation bytes (10xxxxxx) to the rune's
    ## first byte.
    var i = s.len - 1
    while i > 0 and (s[i].uint8 and 0xC0) == 0x80:
      dec i
    result = s[0 ..< i]

  proc handleKey(ed: Editor, key: string) =
    case key
    of "backspace":
      if ed.line.len > 0:
        ed.line = dropLastRune(ed.line)
    of "up":
      if ed.hist.len > 0:
        if ed.histIdx == -1:
          ed.histDraft = ed.line
          ed.histIdx = ed.hist.len - 1
        elif ed.histIdx > 0:
          dec ed.histIdx
        ed.line = ed.hist[ed.histIdx]
    of "down":
      if ed.histIdx != -1:
        if ed.histIdx == ed.hist.len - 1:
          ed.histIdx = -1
          ed.line = ed.histDraft
        else:
          inc ed.histIdx
          ed.line = ed.hist[ed.histIdx]
    of "tab":
      complete(ed)
      return  # already redrawn
    else:
      ed.line.add(key)
    draw(ed)

# ---------------------------------------------------------------------------
# Commands

proc showHelp() =
  echo ""
  echo "Niffler admin shell — status commands for the harness itself."
  echo "The LLM chat lives in the web UI / niffler-tui; scripting goes"
  echo "through the cli component."
  echo ""
  for (name, desc) in commands:
    echo fmt("  {name:<10} {desc}")

proc showStatus(ct: CoreTools) =
  echo ""
  echo fmt("bus:          {getEnv(\"NIF_NATS_URL\", \"nats://127.0.0.1:4222\")}")
  echo fmt("uptime:       {humanDuration(epochTime() - bootTime)}")
  echo fmt("components:   {ct.cat.components.len} registered")
  var liveRunners = 0
  if ct.sup != nil:
    for c in ct.sup.children:
      if c.name.startsWith("session-"): inc liveRunners
    echo fmt("children:     {ct.sup.children.len} supervised ({liveRunners} session runners)")
  else:
    echo "children:     n/a"
  echo fmt("direct tools: {ct.cat.promptTools().len} in new conversations")
  echo "core tools:   discover, invoke (catalog/lifecycle tools are on demand)"

proc showCatalog(ct: CoreTools) =
  echo ""
  echo "name                version    pid  repl  tools"
  echo fmt("{repeat('-', 18)} {repeat('-', 10)} {repeat('-', 6)}  {repeat('-', 4)}  -----")
  for name in ct.cat.components.keys.toSeq.sorted:
    let reg = ct.cat.components[name]
    let replicas = max(reg.pids.len, 1)
    echo fmt("{name:<18} {reg.version:<10} {reg.pid:>6}  {replicas:>4}  {reg.tools.len}")

proc showTools(ct: CoreTools) =
  echo ""
  echo "tool                       component        description"
  echo fmt("{repeat('-', 26)} {repeat('-', 18)} -----------")
  for name in ct.cat.components.keys.toSeq.sorted:
    for t in ct.cat.components[name].tools:
      if t.schema{"x-harness"}{"hidden"}.getBool(false): continue
      var desc = t.schema{"description"}.getStr("").splitLines()[0]
      if desc.len > 60: desc = desc[0 ..< 57] & "…"
      echo fmt("{t.name:<26} {name:<18} {desc}")

proc showSessions(ct: CoreTools) =
  echo ""
  try:
    let resp = ct.dispatchToolCall("list", %*{"kind": "conversation"})
    let items = resp{"items"}
    if items == nil or items.len == 0:
      echo "no conversations yet"
    else:
      echo "id                                        title                          age"
      echo fmt("{repeat('-', 40)} {repeat('-', 30)} ---")
      for item in items:
        let id = item{"id"}.getStr("")
        let v = item{"value"}
        let title = v{"title"}.getStr("")
        let created = v{"createdAt"}.getFloat(0)
        let age = if created > 0: humanDuration(epochTime() - created) else: "?"
        echo fmt("{id:<40} {title:<30} {age}")
  except CatchableError as e:
    echo "store unreachable: " & e.msg
  if ct.sup != nil:
    let runners = ct.sup.children.filterIt(it.name.startsWith("session-"))
    if runners.len > 0:
      echo "live session runners: " & runners.mapIt(it.name).join(", ")

proc exec(cmd: string, ct: CoreTools): bool =
  ## Runs one command line. Returns true when the shell should exit.
  case cmd
  of "help", "?": showHelp()
  of "status": showStatus(ct)
  of "catalog": showCatalog(ct)
  of "tools": showTools(ct)
  of "sessions": showSessions(ct)
  of "exit", "quit": return true
  else:
    echo "unknown command: '" & cmd & "' — type 'help'"

# ---------------------------------------------------------------------------
# Shell loop

proc runAdminShell*(ct: CoreTools, pump: proc() = nil,
                    stopped: proc(): bool = nil) =
  ## The interactive admin REPL. Only called when stdin is a tty; service
  ## mode (no tty) keeps serving svc.core.call in the harness's main loop.
  echo "\nNiffler admin shell — type 'help' for commands (exit to quit)."
  when defined(posix):
    rawMode(true)
    defer: rawMode(false)
    var ed = Editor(histIdx: -1)
    draw(ed)
    while true:
      var fds = [Tpollfd(fd: 0, events: POLLIN, revents: 0)]
      let r = poll(addr fds[0], 1, 50)
      if r < 0: break                      # EINTR (Ctrl-C) or closed
      if r > 0 and (fds[0].revents and POLLIN) != 0:
        let key = readKey()
        if key.len == 0 or key == "eof": break
        if key == "enter":
          echo ""
          let line = ed.line
          ed.line = ""
          if line.strip().len > 0:
            if ed.hist.len == 0 or ed.hist[^1] != line:
              ed.hist.add(line)
              if ed.hist.len > maxHistory:
                ed.hist = ed.hist[^maxHistory .. ^1]
            ed.histIdx = -1
            ed.histDraft = ""
            if exec(line.strip(), ct): break
          draw(ed)
        elif key == "escape":
          draw(ed)                         # lone ESC: just redraw
        else:
          handleKey(ed, key)
      if stopped != nil and stopped(): break
      if pump != nil: pump()
  else:
    # Fallback without raw mode: plain lines, no history/completion.
    while true:
      stdout.write(prompt)
      stdout.flushFile()
      let line = stdin.readLine()
      if line.len == 0 or line in ["exit", "quit"]: break
      if exec(line.strip(), ct): break
