## Mock official MCP Registry for tests/t_mcp.nim — std-only Nim, same style
## as mcp_server.nim. Binds 127.0.0.1:0 (ephemeral), prints the chosen port
## on stdout (one line, flushed), then serves the same canned /v0/servers
## response to every HTTP request until killed. Read-only: the manager's
## mcp_search only issues GETs.
##
## Note: std/net's recv loops until the full requested size or EOF, which
## deadlocks a request/response server — so reads go through raw posix recv,
## which returns whatever bytes are already available.

import std/[json, net, posix, streams, strutils]

const body = $(%*{
  "servers": [
    {"name": "io.github/example/github-mcp-server",
     "title": "GitHub MCP", "description": "GitHub API tools",
     "version": "1.0.0",
     "packages": [{"registryType": "npm",
                   "identifier": "@modelcontextprotocol/server-github",
                   "transport": {"type": "stdio"}}]},
    {"name": "io.github/example/not-installable",
     "title": "Needs setup", "description": "no transports",
     "version": "0.2.0", "packages": [], "remotes": []},
  ],
})

proc main() =
  let outp = stdout.newFileStream()
  let sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  sock.listen()
  let (host, boundPort) = sock.getLocalAddr()
  outp.writeLine($int(boundPort))
  outp.flush()
  while true:
    var client: Socket
    try:
      client = newSocket()
      sock.accept(client)
    except CatchableError:
      return
    var request = ""
    var buf: array[4096, char]
    # Read until the blank line that ends the request headers; then answer.
    while true:
      let n = posix.recv(client.getFd(), addr buf[0], csize(buf.len), 0.cint)
      if n <= 0:
        break
      for i in 0..<n:
        request.add(buf[i])
      if "\r\n\r\n" in request or "\n\n" in request:
        break
    let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " &
               $body.len & "\r\nConnection: close\r\n\r\n" & body
    try:
      client.send(resp)
    except CatchableError:
      discard
    client.close()

when isMainModule:
  main()
