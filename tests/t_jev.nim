## jev contract: bounded discovery advisory over a replaceable System One
## backend, without downloading model weights. Fake endpoint checks request
## shape, fail-open result, and no-match handling on a private bus.
import std/[json, net, os, osproc, sequtils, strutils]
import natsnim
import helpers

proc serve(portFile: string) =
  let server = newSocket()
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let (_, port) = server.getLocalAddr()
  writeFile(portFile, $port)
  while true:
    var peer: owned(Socket)
    server.accept(peer)
    var data = ""
    var line = ""
    while true:
      peer.readLine(line)
      if line.strip().len == 0: break
      data.add(line & "\n")
    let lengthLine = data.splitLines().filterIt(it.toLowerAscii().startsWith("content-length:"))
    var n = 0
    if lengthLine.len > 0: n = parseInt(lengthLine[0].split(':')[1].strip())
    var body = ""
    if n > 0:
      while body.len < n:
        var part = newString(n - body.len)
        let got = peer.recv(part, part.len)
        if got <= 0: break
        body.add(part[0 ..< got])
    let request = parseJson(body)
    let questions = request{"questions"}
    let criteria = questions{"pick"}{"criteria"}
    var first = ""
    if criteria != nil:
      for key, _ in criteria:
        first = key
        break
    let noMatch = request{"state"}.getStr("").contains("no match")
    let response = $(%*{"answers": {
      "needed": {"type": "noul", "noul": (if noMatch: 0.1 else: 0.9)},
      "pick": {"type": "choice", "choice": first,
               "probabilities": {first: 1.0}, "confidence": 1.0}
    }})
    peer.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" &
      "Content-Length: " & $response.len & "\r\nConnection: close\r\n\r\n" & response)
    peer.close()

proc main() =
  if paramCount() == 2 and paramStr(1) == "serve":
    serve(paramStr(2))
    return
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let root = tempRoot("jev")
  defer: removeDir(root)
  let portFile = root / "port"
  let http = startProcess(getAppFilename(), args = @["serve", portFile])
  defer: stopProcess(http)
  for _ in 0 ..< 100:
    if fileExists(portFile): break
    sleep(30)
  check("fake decision backend up", fileExists(portFile))
  let (nats, url) = startNats()
  defer: stopServer(nats)
  var nc = waitConnect(url)
  defer: nc.close()
  let jev = startComponent(repo / "var/bin/jev", url, root = root,
    extra = @[("NIF_JEV_URL", "http://127.0.0.1:" & readFile(portFile) & "/v1/systemone")])
  defer: stopProcess(jev)
  check("jev registered", waitRegistered(nc, "jev"))
  let items = %*[{"name": "grep", "description": "Search file contents"},
                 {"name": "skill_list", "description": "List skills"}]
  let good = call(nc, "jev", "jev_suggest", %*{"task": "search source", "candidates": items})
  check("suggestion from local backend", good{"ok"}.getBool(false) and
    good{"suggestion"}.getStr("") == "grep", $good)
  let none = call(nc, "jev", "jev_suggest", %*{"task": "no match", "candidates": items})
  check("no-match suppresses forced choice", none{"ok"}.getBool(false) and
    none{"suggestion"}.getStr("x") == "", $none)
  let duplicate = call(nc, "jev", "jev_suggest", %*{"task": "x", "candidates":
    %*[{"name": "grep", "description": "x"}, {"name": "grep", "description": "y"}]})
  check("duplicate candidates refused", not duplicate{"ok"}.getBool(false), $duplicate)
  let bad = call(nc, "jev", "jev_decide", %*{"state": "x", "questions":
    {"q": {"type": "choice", "instructions": "choose", "criteria": {}}}})
  check("invalid decision refused", not bad{"ok"}.getBool(false), $bad)
  stopProcess(http)
  let offline = call(nc, "jev", "jev_suggest",
    %*{"task": "search source", "candidates": items})
  check("backend outage is advisory failure, not a suggestion",
    not offline{"ok"}.getBool(false) and
    offline{"suggestion"} == nil, $offline)
  report("JEV TEST")

when isMainModule: main()
