## fabricguest — the guest-side API for fabric programs (docs/research/FABRIC.md).
##
## The program imports this module and nothing else. Call-side procs
## (callTool, finish, logg, stringArg) have no bodies here — the fabric
## executor overrides them natively via implementRoutine, keyed by the
## "fabricguest" package name (the .nimble file next to this module is
## load-bearing: without it the package resolves to "unknown" and the
## bridge never fires).
##
## The j* helpers are ordinary procs the VM executes (bodies kept
## import-free so guests stay stdlib-free and cold eval stays ~ms): they
## build JSON strings for callTool without pulling std/json into the VM.

proc callTool*(tool: string, argsJson: string): string =
  ## Execute one Niffler tool call and return its raw JSON result.
  ## Raising calls (bash nonzero exit, tool errors) reject with an error
  ## message. Every call crosses the session proxy: approval, budgets and
  ## audit apply. `tool` is the plain tool name ("bash", "store's get" is
  ## written as "get"); argsJson is the tool's arguments object as JSON.
  discard "implementation provided by the fabric executor"

proc finish*(valueJson: string) =
  ## End the program and return valueJson to the conversation — the only
  ## thing the model sees. Call exactly once; nothing after it runs.
  discard "implementation provided by the fabric executor"

proc logg*(message: string) =
  ## Emit a progress line to the activity stream (never the conversation).
  discard "implementation provided by the fabric executor"

proc stringArg*(key: string): string =
  ## Return the strings[key] entry passed to the fabric tool call — the
  ## channel for big payloads (file contents, long prompts) that must not
  ## sit inside the program source.
  discard "implementation provided by the fabric executor"

proc jesc*(s: string): string =
  ## Escape and quote a string as one JSON value.
  const hex = "0123456789abcdef"
  result = "\""
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(c) < 32:
        result.add("\\u00")
        result.add(hex[ord(c) shr 4])
        result.add(hex[ord(c) and 0xF])
      else:
        result.add(c)
  result.add("\"")

proc jpair*(name: string, valueJson: string): string =
  ## One object member: escaped name + raw JSON value.
  result = jesc(name) & ":" & valueJson

proc jobj*(members: varargs[string]): string =
  ## Build a JSON object from jpair members.
  result = "{"
  for i, m in members:
    if i > 0: result.add(",")
    result.add(m)
  result.add("}")

proc jarr*(items: varargs[string]): string =
  ## Build a JSON array from raw JSON values.
  result = "["
  for i, it in items:
    if i > 0: result.add(",")
    result.add(it)
  result.add("]")

proc jnum*(i: int): string =
  ## Render an int as a JSON value.
  result = $i

proc jbool*(b: bool): string =
  ## Render a bool as a JSON value.
  result = (if b: "true" else: "false")
