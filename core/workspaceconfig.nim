## Workspace-scoped overrides: `<workspace>/.niffler/config.json`.
##
## The one place a REPOSITORY can say how Niffler should behave inside it —
## which tool profile new conversations start from, which tools stay in the
## direct set: the settings that are a property of the project rather than of
## the person or the machine. The harness only ever READS it; committing it is
## the user's choice, and a project that prefers to keep its Niffler settings
## private simply does not commit it.
##
## Absent, unreadable, empty or malformed files are ignored with one warning:
## a bad file in a repository must never be able to brick that repository's
## conversations. Every accessor follows the same rule — a wrong type reads as
## "absent" rather than failing a call.
##
## Resolution order for every key it can carry (first wins):
##   an explicit session argument  >  this file  >  the environment default
## and it is consulted only on the FRESH path: a conversation's toolset is
## resolved once and frozen into its header, so editing the file cannot rewrite
## a running conversation's request prefix (docs/WIRE.md, prompt-cache
## discipline). A new conversation picks the change up; an old one keeps the
## tools it started with.
##
## Shape (every section optional):
##   {
##     "tools":  {"profile": "nim-dev", "tools": ["lsp", "git", "bash"]},
##     "prompt": {"reviewHintMinChars": 1200}
##   }
##
## `tools.profile` names a stored tool profile (`profile {"op": "list"}`).
## `tools.tools` is a direct-set allowlist of tool names, like the `tools`
## argument of a session call. `prompt.reviewHintMinChars` is read by the
## systemprompt component, which owns that heuristic — this module owns the
## FILE, not every key; the file is the shared surface, the keys are whoever
## reads them (components read this path themselves rather than importing core,
## which is why the contract lives in this comment and docs/WORKSPACE-CONFIG.md).

import std/[json, os, strutils]

proc workspaceConfigPath*(workspace: string): string =
  ## Where the file is looked for; "" when there is no workspace to look in.
  if workspace.len == 0: return ""
  result = workspace / ".niffler" / "config.json"

proc loadWorkspaceConfig*(workspace: string): JsonNode =
  ## The parsed config object, or nil when there is nothing usable.
  result = nil
  let path = workspaceConfigPath(workspace)
  if path.len == 0 or not fileExists(path): return
  try:
    let raw = readFile(path)
    if raw.strip().len == 0: return
    let doc = parseJson(raw)
    if doc.kind != JObject:
      stderr.writeLine("workspace config " & path &
                       ": expected a JSON object — ignored")
      return
    result = doc
  except CatchableError as e:
    stderr.writeLine("workspace config " & path & " ignored: " & e.msg)

proc configStr*(cfg: JsonNode, section, key: string): string =
  ## A string under `section`; "" when absent or of the wrong type.
  result = ""
  if cfg == nil or cfg.kind != JObject: return
  let sec = cfg{section}
  if sec == nil or sec.kind != JObject: return
  let v = sec{key}
  if v == nil or v.kind != JString: return
  result = v.getStr("").strip()

proc configStrSeq*(cfg: JsonNode, section, key: string): seq[string] =
  ## A string array under `section`; non-string and empty entries are skipped.
  result = @[]
  if cfg == nil or cfg.kind != JObject: return
  let sec = cfg{section}
  if sec == nil or sec.kind != JObject: return
  let v = sec{key}
  if v == nil or v.kind != JArray: return
  for item in v:
    if item.kind == JString:
      let s = item.getStr("").strip()
      if s.len > 0: result.add(s)

proc configInt*(cfg: JsonNode, section, key: string, fallback: int): int =
  ## An integer under `section`, or `fallback` when absent/not an integer.
  result = fallback
  if cfg == nil or cfg.kind != JObject: return
  let sec = cfg{section}
  if sec == nil or sec.kind != JObject: return
  let v = sec{key}
  if v == nil or v.kind != JInt: return
  result = v.getInt(fallback)
