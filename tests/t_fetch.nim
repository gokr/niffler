## fetch component tests — bus contract: web content retrieval.
##
## Boots the fetch component alone against a private NATS server and a
## scratch NIF_ROOT. A mini HTTP server — the test binary re-executed
## with the "serve" argument (no threads, no external deps) — serves
## fixture routes: HTML page, raw HTML, JSON API, errors, oversized page
## (file spill), method/body echo, custom-header echo, redirect, slow endpoint.
## A fake trafilatura executable proves preferred extraction and fallback.
##
## The server is a select-driven event loop over raw fds. Blocking
## net.recv(size, timeout) is deliberately avoided: Nim's stdlib only
## returns partial reads on EOF and otherwise raises TimeoutError, which
## makes a per-connection blocking reader unreliable for live peers.

import std/[json, nativesockets, net, os, osproc, posix, strutils]
import natswrapper
import helpers

type
  Conn = object
    sock: Socket
    buf: string

  Req = object
    ok: bool
    verb, path: string
    headers: seq[string]
    bodyStart: int
    bodyLen: int

proc completeRequest(buf: string): Req =
  let sep = buf.find("\r\n\r\n")
  if sep < 0:
    return
  let head = buf[0 ..< sep]
  let lines = head.split("\r\n")
  if lines.len == 0 or lines[0].len == 0:
    return
  let first = lines[0].split()
  if first.len < 2:
    return
  var contentLength = 0
  for line in lines[1 .. ^1]:
    if line.toLowerAscii().startsWith("content-length:"):
      try:
        contentLength = parseInt(line.split(':', 1)[1].strip())
      except ValueError:
        discard
  let bodyStart = sep + 4
  if buf.len < bodyStart + contentLength:
    return
  result = Req(ok: true, verb: first[0], path: first[1],
               headers: lines[1 .. ^1], bodyStart: bodyStart,
               bodyLen: contentLength)

proc bodyOf(buf: string, c: Req): string =
  buf[c.bodyStart ..< c.bodyStart + c.bodyLen]

proc respond(sock: Socket, status, contentType, body: string) =
  let data = "HTTP/1.1 " & status & "\r\n" &
             "Content-Type: " & contentType & "\r\n" &
             "Content-Length: " & $body.len & "\r\n" &
             "Connection: close\r\n\r\n" & body
  if data.len > 0:
    discard send(sock.getFd(), cast[pointer](data[0].addr), data.len, 0)

proc serve(portFile: string) =
  let listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let (_, port) = listener.getLocalAddr()
  writeFile(portFile, $port)
  var conns: seq[Conn] = @[]
  while true:
    var readfds: seq[SocketHandle] = @[listener.getFd()]
    for c in conns:
      readfds.add(c.sock.getFd())
    discard selectRead(readfds, 1000)
    if readfds.len == 0:
      continue
    for fd in readfds:
      if fd == listener.getFd():
        var client: owned(Socket)
        listener.accept(client)
        conns.add(Conn(sock: client, buf: ""))
      else:
        var idx = -1
        for i, c in conns:
          if c.sock.getFd() == fd:
            idx = i
            break
        if idx < 0:
          continue
        var tmp = newString(8192)
        let n = recv(fd, tmp[0].addr, 8192, 0)
        if n <= 0:
          conns[idx].sock.close()
          conns.delete(idx)
          continue
        conns[idx].buf.add(tmp[0 ..< n])
        let req = completeRequest(conns[idx].buf)
        if not req.ok:
          continue
        let body = bodyOf(conns[idx].buf, req)
        let path = req.path.split('?')[0]
        if req.verb in ["POST", "PUT", "PATCH"] and path == "/echo":
          respond(conns[idx].sock, "200 OK", "text/plain",
                  req.verb & ":" & body)
        elif req.verb == "GET" and path == "/page":
          respond(conns[idx].sock, "200 OK", "text/html",
            "<html><head><title>T</title></head><body>" &
            "<h1>Hello Fetch</h1><p>Some <b>content</b> here.</p>" &
            "<script>evil()</script><ul><li>one</li><li>two</li></ul>" &
            "</body></html>")
        elif req.verb == "GET" and path == "/raw":
          respond(conns[idx].sock, "200 OK", "text/html",
            "<html><body><h1>Raw Page</h1><p>Keep the tags.</p></body></html>")
        elif req.verb == "GET" and path == "/api":
          respond(conns[idx].sock, "200 OK", "application/json",
            "{\"hello\": \"world\", \"n\": 42}")
        elif req.verb == "GET" and path == "/missing":
          respond(conns[idx].sock, "404 Not Found", "text/html",
            "not found here")
        elif req.verb == "GET" and path == "/blank-error":
          respond(conns[idx].sock, "500 Internal Server Error", "text/plain",
            "   ")
        elif req.verb == "GET" and path == "/extract-fail":
          respond(conns[idx].sock, "200 OK", "text/html",
            "<html><body><article><h1>Fallback Article</h1>" &
            "<p>Force extractor failure</p></article></body></html>")
        elif req.verb == "GET" and path == "/big":
          var big = "<html><body>"
          for i in 0 ..< 8000:
            big.add("<p>Big content paragraph number " & $i &
                    " lorem ipsum.</p>")
          big.add("</body></html>")
          respond(conns[idx].sock, "200 OK", "text/html", big)
        elif req.verb == "GET" and path == "/headers":
          var hdr = newJObject()
          for line in req.headers:
            let parts = line.split(':', 1)
            if parts.len == 2:
              hdr[parts[0].strip()] = %parts[1].strip()
          respond(conns[idx].sock, "200 OK", "application/json", $hdr)
        elif req.verb == "GET" and path == "/redirect":
          let data = "HTTP/1.1 302 Found\r\nLocation: /page\r\n" &
                     "Content-Length: 0\r\nConnection: close\r\n\r\n"
          if data.len > 0:
            discard send(fd, cast[pointer](data[0].addr), data.len, 0)
        elif req.verb == "GET" and path == "/slow":
          sleep(2000)
          respond(conns[idx].sock, "200 OK", "text/plain", "finally")
        else:
          respond(conns[idx].sock, "404 Not Found", "text/plain",
            "no route " & path)
        conns[idx].sock.close()
        conns.delete(idx)

# --------------------------------------------------------------------------

proc main() =
  if paramCount() >= 2 and paramStr(1) == "serve":
    serve(paramStr(2))
    return

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "fetch"):
    fail("missing binary — run `make build` first")
    quit(1)

  # --- mini HTTP server child + scratch root --------------------------------
  let root = tempRoot("fetch")
  defer: removeDir(root)
  let portFile = root / "port"
  let srvProc = startProcess(getAppFilename(),
                             args = @["serve", portFile],
                             options = {poUsePath, poStdErrToStdOut})
  defer: stopProcess(srvProc)
  var port = ""
  for i in 0 ..< 100:
    if fileExists(portFile):
      port = readFile(portFile)
      break
    if srvProc.peekExitCode() != -1:
      fail("http server exited early")
      quit(1)
    sleep(50)
  check("http server up", port.len > 0, readFile(portFile))
  let base = "http://127.0.0.1:" & port

  # --- boot bus + component -------------------------------------------------
  let (server, url) = startNats(routed = true)
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var compProc = startComponent(repoRoot / "var" / "bin" / "fetch", url,
                                 root = root,
                                 extra = [("NIF_TRAFILATURA", "off")])
  defer: stopProcess(compProc)
  check("fetch registers", waitRegistered(nc, "fetch"))

  # --- HTML extraction ------------------------------------------------------
  let page = call(nc, "fetch", "fetch", %*{"url": base & "/page"})
  check("html page extracted", page{"ok"}.getBool(false) and
        page{"status"}.getInt(0) == 200 and
        page{"content"}.getStr("").contains("Hello Fetch") and
        page{"content"}.getStr("").contains("Some content here") and
        not page{"content"}.getStr("").contains("<h1>") and
        not page{"content"}.getStr("").contains("evil") and
        page{"convertedToText"}.getBool(false) and
        page{"extractionMethod"}.getStr("") == "htmlparser", $page)

  let raw = call(nc, "fetch", "fetch",
                 %*{"url": base & "/raw", "convertToText": false})
  check("raw html returned", raw{"ok"}.getBool(false) and
        raw{"content"}.getStr("").contains("<h1>Raw Page</h1>") and
        not raw{"convertedToText"}.getBool(false), $raw)

  # --- JSON / non-HTML ------------------------------------------------------
  let api = call(nc, "fetch", "fetch", %*{"url": base & "/api"})
  check("json api verbatim", api{"ok"}.getBool(false) and
        api{"contentType"}.getStr("").contains("application/json") and
        api{"content"}.getStr("").contains("\"hello\": \"world\"") and
        not api{"convertedToText"}.getBool(false), $api)

  # --- errors ---------------------------------------------------------------
  let missing = call(nc, "fetch", "fetch", %*{"url": base & "/missing"})
  check("404 is an error", not missing{"ok"}.getBool(false) and
        missing{"error"}.getStr("").contains("404") and
         missing{"error"}.getStr("").contains("not found"), $missing)

  let blankError = call(nc, "fetch", "fetch",
                        %*{"url": base & "/blank-error"})
  check("blank error body is safe",
        not blankError{"ok"}.getBool(false) and
        blankError{"error"}.getStr("").contains("500"), $blankError)

  let badScheme = call(nc, "fetch", "fetch", %*{"url": "ftp://example.com/x"})
  check("non-http scheme rejected",
        not badScheme{"ok"}.getBool(false) and
        badScheme{"error"}.getStr("").contains("http"), $badScheme)

  let noUrl = call(nc, "fetch", "fetch", %*{})
  check("missing url errors", noUrl{"error"} != nil, $noUrl)

  let badMethod = call(nc, "fetch", "fetch",
                       %*{"url": base & "/page", "method": "TRACE"})
  check("bad method rejected",
        not badMethod{"ok"}.getBool(false) and
        badMethod{"error"}.getStr("").contains("method"), $badMethod)

  # --- large content spills to file -----------------------------------------
  let big = call(nc, "fetch", "fetch", %*{"url": base & "/big"})
  check("big page spills to file", big{"ok"}.getBool(false) and
        big{"savedToFile"}.getBool(false) and
        big{"filePath"}.getStr("").len > 0 and
        fileExists(big{"filePath"}.getStr("")) and
        big{"content"}.getStr("").contains("Content saved to file"), $big)
  check("spilled file has the text",
        readFile(big{"filePath"}.getStr("")).len > 200_000 and
        readFile(big{"filePath"}.getStr("")).
          contains("Big content paragraph"))

  # --- redirect / custom headers / POST --------------------------------------
  let redir = call(nc, "fetch", "fetch", %*{"url": base & "/redirect"})
  check("redirect followed", redir{"ok"}.getBool(false) and
        redir{"content"}.getStr("").contains("Hello Fetch"), $redir)

  let hdrs = call(nc, "fetch", "fetch",
                  %*{"url": base & "/headers", "headers": {"X-Test": "yes"}})
  check("custom headers sent", hdrs{"ok"}.getBool(false) and
        hdrs{"content"}.getStr("").contains("x-test") and
        hdrs{"content"}.getStr("").contains("\"yes\""), $hdrs)

  let post = call(nc, "fetch", "fetch",
                  %*{"url": base & "/echo", "method": "POST",
                     "body": "ping-echo"})
  check("post body sent", post{"ok"}.getBool(false) and
        post{"content"}.getStr("") == "POST:ping-echo", $post)

  let put = call(nc, "fetch", "fetch",
                 %*{"url": base & "/echo", "method": "PUT",
                    "body": "replace-me"})
  check("put method and body sent", put{"ok"}.getBool(false) and
        put{"content"}.getStr("") == "PUT:replace-me", $put)

  let patch = call(nc, "fetch", "fetch",
                   %*{"url": base & "/echo", "method": "PATCH",
                      "body": "change-me"})
  check("patch method and body sent", patch{"ok"}.getBool(false) and
        patch{"content"}.getStr("") == "PATCH:change-me", $patch)

  # --- timeout ----------------------------------------------------------------
  let slow = call(nc, "fetch", "fetch",
                  %*{"url": base & "/slow", "timeout": 800}, 20_000)
  check("slow server times out", not slow{"ok"}.getBool(false) and
        slow{"error"}.getStr("").contains("failed"), $slow)

  # --- optional trafilatura -------------------------------------------------
  let fakeTrafilatura = root / "fake-trafilatura"
  writeFile(fakeTrafilatura, """#!/bin/sh
input_dir=
output_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-dir) input_dir=$2; shift 2 ;;
    --output-dir) output_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
if grep -q "Force extractor failure" "$input_dir/page.html"; then
  exit 7
fi
printf '%s\n' 'Trafilatura selected article text' > "$output_dir/article.txt"
""")
  setFilePermissions(fakeTrafilatura,
                     {fpUserRead, fpUserWrite, fpUserExec})
  stopProcess(compProc)
  compProc = startComponent(repoRoot / "var" / "bin" / "fetch", url,
                            root = root,
                            extra = [("NIF_TRAFILATURA", fakeTrafilatura)])
  check("fetch re-registers with trafilatura", waitRegistered(nc, "fetch"))

  let extracted = call(nc, "fetch", "fetch", %*{"url": base & "/page"})
  check("trafilatura preferred when installed",
        extracted{"ok"}.getBool(false) and
        extracted{"content"}.getStr("") ==
          "Trafilatura selected article text" and
        extracted{"extractionMethod"}.getStr("") == "trafilatura", $extracted)

  let fallback = call(nc, "fetch", "fetch",
                      %*{"url": base & "/extract-fail"})
  check("trafilatura failure falls back",
        fallback{"ok"}.getBool(false) and
        fallback{"content"}.getStr("").contains("Fallback Article") and
        fallback{"extractionMethod"}.getStr("") == "htmlparser", $fallback)

  report("FETCH TEST")

main()
