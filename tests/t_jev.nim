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

  # A real component-to-core bus path: core's discover projection supplies
  # current on-demand hints, not an invented or stale candidate list.
  let sandbox = newCoreSandbox("jev-recommend", ["store", "jev", "skills"])
  defer: removeDir(sandbox.root)
  let (coreNats, coreUrl) = startNats()
  defer: stopServer(coreNats)
  var coreNc = waitConnect(coreUrl)
  defer: coreNc.close()
  let core = startComponent(sandbox.sandboxBin("niffler"), coreUrl,
    root = sandbox.root,
    extra = @[("NIF_JEV_URL", "http://127.0.0.1:" & readFile(portFile) & "/v1/systemone")])
  defer: stopProcess(core)
  var ready = false
  for _ in 0 ..< 100:
    let snapshot = call(coreNc, "core", "catalog", %*{"op": "snapshot"}, 2000)
    if snapshot{"components"} != nil:
      for c in snapshot["components"]:
        if c{"name"}.getStr("") == "skills": ready = true
    if ready: break
    sleep(100)
  check("core and skills ready", ready)
  let tools = call(coreNc, "jev", "jev_recommend", %*{
    "task": "find workflow skills", "query": "skill_list", "kind": "tools"})
  check("live tool catalogue recommendation", tools{"ok"}.getBool(false) and
    tools{"suggestion"}.getStr("").len > 0 and
    tools{"candidates"}.len > 1 and
    tools{"kind"}.getStr("") == "tools", $tools)
  let skills = call(coreNc, "jev", "jev_recommend", %*{
    "task": "read niffler guide", "query": "niffler-harness", "kind": "skills"})
  check("live skill list recommendation", skills{"ok"}.getBool(false) and
    skills{"suggestion"}.getStr("") == "niffler-harness", $skills)
  let empty = call(coreNc, "jev", "jev_recommend", %*{
    "task": "find", "query": "unlikely-jev-xyz-not-found", "kind": "tools"})
  check("empty catalogue does not force inference", empty{"ok"}.getBool(false) and
    empty{"suggestion"}.getStr("x") == "" and empty{"candidates"}.len == 0,
    $empty)
  let wide = call(coreNc, "jev", "jev_recommend", %*{
    "task": "find", "query": "", "kind": "tools"})
  check("empty query refused before catalogue dump", not wide{"ok"}.getBool(false), $wide)
  stopProcess(core)
  stopProcess(http)
  let offline = call(nc, "jev", "jev_suggest",
    %*{"task": "search source", "candidates": items})
  check("backend outage is advisory failure, not a suggestion",
    not offline{"ok"}.getBool(false) and
    offline{"suggestion"} == nil, $offline)
  report("JEV TEST")

when isMainModule: main()
