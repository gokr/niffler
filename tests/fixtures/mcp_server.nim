## Minimal MCP server fixture for tests/t_mcp.nim — speaks the stdio
## transport (newline-delimited JSON-RPC 2.0) with just enough surface to
## exercise the bridge: initialize, tools/list, tools/call, prompts/list,
## prompts/get, resources/list, resources/read, ping, and a server-initiated
## tools/list_changed notification for drift handling.
##
## Tools:
##   echo         {message} -> text "echo: <message>"
##   fail         {}        -> tool error result ("boom")
##   mutate_tools {}        -> adds "extra_tool" to the listing and pushes
##                           notifications/tools/list_changed
## Prompts:
##   greet        {name}    -> one assistant message greeting the name
## Resources:
##   doc://readme           -> text resource ("fixture readme contents")
##
## Deterministic, dependency-free (std only), compiled by the test itself.

import std/[json, os, streams, strutils]

type FixtureTool = object
  name: string
  description: string
  schema: JsonNode

var tools = @[
  FixtureTool(name: "echo", description: "Echo the message back",
    schema: %*{"type": "object",
               "properties": %*{"message": %*{"type": "string", "description": "Text to echo"}},
               "required": %*["message"]}),
  FixtureTool(name: "fail", description: "Always fails",
    schema: %*{"type": "object", "properties": %*{}}),
  FixtureTool(name: "mutate_tools", description: "Change the tool listing and notify",
    schema: %*{"type": "object", "properties": %*{}}),
]

proc toolJson(t: FixtureTool): JsonNode =
  %*{"name": t.name, "description": t.description, "inputSchema": t.schema}

proc send(node: JsonNode, outp: Stream) =
  outp.writeLine($node)
  outp.flush()

proc reply(outp: Stream, id: JsonNode, result: JsonNode) =
  send(%*{"jsonrpc": "2.0", "id": id, "result": result}, outp)

proc replyError(outp: Stream, id: JsonNode, code: int, message: string) =
  send(%*{"jsonrpc": "2.0", "id": id,
           "error": %*{"code": code, "message": message}}, outp)

proc main() =
  let stdin = stdin.newFileStream()
  let stdout = stdout.newFileStream()
  while true:
    let line = stdin.readLine()
    if line.len == 0:
      break  # EOF: client closed stdin (session close)
    var msg: JsonNode
    try:
      msg = parseJson(line)
    except CatchableError:
      continue
    let meth = msg{"method"}.getStr("")
    let id = msg{"id"}
    let hasId = id != nil and id.kind != JNull
    if not hasId:
      # Notifications need no reply; mutate_tools' own notification is
      # written by the tool call handler below.
      continue
    case meth
    of "initialize":
      reply(stdout, id, %*{
        "protocolVersion": msg{"params"}{"protocolVersion"}.getStr("2025-06-18"),
        "capabilities": %*{"tools": %*{"listChanged": true},
                          "prompts": %*{},
                          "resources": %*{}},
        "serverInfo": %*{"name": "mcp-fixture", "version": "0.1.0"},
      })
    of "ping":
      reply(stdout, id, %*{})
    of "tools/list":
      var arr = newJArray()
      for t in tools:
        arr.add(toolJson(t))
      reply(stdout, id, %*{"tools": arr})
    of "prompts/list":
      reply(stdout, id, %*{"prompts": %*[
        {"name": "greet", "description": "Greet someone by name",
         "arguments": %*[{"name": "name", "description": "Who to greet",
                          "required": true}]},
      ]})
    of "prompts/get":
      let promptName = msg{"params"}{"name"}.getStr("")
      if promptName == "greet":
        let who = msg{"params"}{"arguments"}{"name"}.getStr("stranger")
        reply(stdout, id, %*{
          "description": "Greeting template",
          "messages": %*[
            {"role": "user", "content": %*{"type": "text",
             "text": "Please greet " & who & " warmly."}},
          ],
        })
      else:
        replyError(stdout, id, -32602, "unknown prompt: " & promptName)
    of "resources/list":
      reply(stdout, id, %*{"resources": %*[
        {"uri": "doc://readme", "name": "readme",
         "description": "The fixture readme", "mimeType": "text/plain",
         "size": 21},
      ]})
    of "resources/read":
      let uri = msg{"params"}{"uri"}.getStr("")
      if uri == "doc://readme":
        reply(stdout, id, %*{"contents": %*[
          {"uri": "doc://readme", "mimeType": "text/plain",
           "text": "fixture readme contents"},
        ]})
      else:
        replyError(stdout, id, -32602, "unknown resource: " & uri)
    of "tools/call":
      let name = msg{"params"}{"name"}.getStr("")
      case name
      of "echo":
        let message = msg{"params"}{"arguments"}{"message"}.getStr("")
        reply(stdout, id, %*{
          "content": %*[{"type": "text", "text": "echo: " & message}],
          "isError": false,
        })
      of "fail":
        reply(stdout, id, %*{
          "content": %*[{"type": "text", "text": "boom"}],
          "isError": true,
        })
      of "mutate_tools":
        tools.add(FixtureTool(name: "extra_tool",
          description: "Appears after mutation",
          schema: %*{"type": "object", "properties": %*{}}))
        # Server-initiated contract change notification (no id).
        send(%*{"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                "params": %*{}}, stdout)
        reply(stdout, id, %*{
          "content": %*[{"type": "text", "text": "mutated"}],
          "isError": false,
        })
      else:
        replyError(stdout, id, -32602, "unknown tool: " & name)
    else:
      replyError(stdout, id, -32601, "method not found: " & meth)

when isMainModule:
  main()
