## systemprompt component — the conversation constitution, as a component.
##
## Core keeps only a minimal structural fallback prompt (core/conversation.nim).
## This component owns the real one: it composes the product prompt (the
## self-extension ladder, SDK examples, repo lore — components/systemprompt/
## baseprompt.txt) with the repo's local context files, discovered Pi-style:
##
## - global: $NIF_ROOT/AGENTS.override.md → AGENTS.md → AGENTS.MD →
##   CLAUDE.md → CLAUDE.MD (first hit wins per directory)
## - ancestors: same candidate walk for every directory from cwd up to the
##   filesystem root; nearer-to-cwd files come later in the prompt (more
##   specific instructions read last)
## - per-directory shadowing: only one context file per directory
## - worktree shadow rule: when cwd is a `git worktree` nested under the
##   main repo, the main repo root's context file is skipped — its
##   instructions would otherwise be applied twice (once via the ancestor
##   walk, once via the worktree's own copy)
##
## The session runner requests the prompt once per conversation (tool
## "systemprompt" on svc.systemprompt.call) and falls back to the baked-in
## core prompt when this component is absent, slow, or broken. Replacing
## the constitution is then a normal Niffler operation: write a component
## answering on svc.systemprompt.call, builder.build, core.spawn — the
## agent can do this to itself.

import std/[algorithm, json, os, sequtils, strutils, tables]
import niffler/sdk

const maxPromptLen = 200_000
  ## Core truncates anyway; keep it honest here too — a runaway generated
  ## constitution must not poison every conversation.

const maxFiles = 16
  ## Deep ancestor walks must not blow the cap either.

const basePrompt = staticRead("baseprompt.txt")
  ## The product prompt, baked in at compile time: the repo is the snapshot,
  ## and the prompt must work from any runtime root (sandboxes have no
  ## components/ tree). Editing baseprompt.txt = rebuild + respawn, and it
  ## changes every FUTURE conversation (core freezes it per conversation for
  ## prompt-cache stability). Live here, not in the prompt text: the model
  ## has no use for harness plumbing notes.

const candidates = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD",
                    "CLAUDE.md", "CLAUDE.MD"]
const localCandidate = "AGENTS.local.md"

proc loadContextFileFromDir(dir: string): tuple[path, content: string] =
  ## Pi-style candidate order, first existing readable file wins.
  ## Symlinks resolve naturally (readFile follows them). Per directory:
  ## one file only — AGENTS.md shadows a CLAUDE.md sitting next to it.
  for name in candidates:
    let p = dir / name
    if fileExists(p):
      try:
        return (p, readFile(p))
      except CatchableError as e:
        stderr.writeLine("systemprompt: unreadable context file " &
                         p & ": " & e.msg)
  return ("", "")

proc loadLocalContextFileFromDir(dir: string): tuple[path, content: string] =
  ## AGENTS.local.md is additive, not a shadowing candidate. It is useful for
  ## checkout-local guidance while AGENTS.md remains the stable project rule.
  let path = dir / localCandidate
  if fileExists(path):
    try:
      return (path, readFile(path))
    except CatchableError as e:
      stderr.writeLine("systemprompt: unreadable context file " &
                       path & ": " & e.msg)
  ("", "")

proc fileId(path: string): string =
  ## File identity for dedupe, not the path: a symlink farm (the bench
  ## harness re-exposes the repo root inside its runtime dir) makes the same
  ## AGENTS.md reachable twice in one ancestor walk — farm copy first, real
  ## repo later. Including it twice would double every conversation's
  ## standing instructions.
  try:
    let fi = getFileInfo(path)
    result = $fi.id.device & ":" & $fi.id.file
  except CatchableError:
    result = path

type PromptHint = object
  slot: string
  source: string
  key: string
  content: string
  mode: string
  sequence: int

var promptHints = initTable[string, PromptHint]()
var nextHintSequence = 0

proc hintKey(slot, source, key: string): string =
  slot & "\x1f" & source & "\x1f" & key

proc renderPromptSlot(slot: string): string =
  var entries: seq[PromptHint]
  for hint in promptHints.values:
    if hint.slot == slot: entries.add(hint)
  if entries.len == 0: return ""
  entries.sort(proc(a, b: PromptHint): int =
    cmp(a.source & "\x1f" & a.key, b.source & "\x1f" & b.key))
  var rendered: seq[string]
  for hint in entries:
    rendered.add(hint.content)
  rendered.join("\n\n")

proc contextFileName(path: string): string =
  ## The concrete candidate filename a directory resolved to — the shadow
  ## rule must skip the main repo's AGENTS.override.md when the worktree
  ## resolved its own AGENTS.override.md (not a plain AGENTS.md).
  splitFile(path).name & ".md"

proc main() =
  let comp = newComponent("systemprompt", "0.1.0")
  let root = getEnv("NIF_ROOT", getCurrentDir())

  let hintSchema = toolSchema(%*{
    "slot": {"type": "string", "description": "Named prompt slot, e.g. efficient_tools or after_instructions"},
    "content": {"type": "string", "description": "Prompt fragment; keep it concise and stable"},
    "source": {"type": "string", "description": "Component/plugin identity"},
    "key": {"type": "string", "description": "Stable contribution key; repeated registration replaces the same contribution"},
    "mode": {"type": "string", "enum": ["aggregate", "singleton"], "description": "aggregate joins contributions; singleton keeps the last contribution for the slot"}
  }, required = @["slot", "content"], description = "Register a prompt fragment for future conversations. Internal component API; changes affect only prompts composed after registration and never rewrite frozen conversations.")
  hintSchema["x-harness"] = %*{"hidden": true, "timeoutMs": 5_000}
  discard comp.tool("prompt_hint", hintSchema,
    proc(c: Component, args: JsonNode): JsonNode =
      let slot = args{"slot"}.getStr("").strip()
      let content = args{"content"}.getStr("")
      if slot.len == 0 or slot.len > 64 or
          slot.anyIt(it notin {'a'..'z', '0'..'9', '_' }):
        return errResult("slot must be 1..64 lowercase letters, digits or _")
      if content.len == 0 or content.len > 16_384:
        return errResult("content must be 1..16384 bytes")
      let source = args{"source"}.getStr("component").strip()
      let key = args{"key"}.getStr(slot).strip()
      let mode = args{"mode"}.getStr("aggregate")
      if mode notin ["aggregate", "singleton"]:
        return errResult("mode must be aggregate or singleton")
      inc nextHintSequence
      if mode == "singleton":
        # A singleton is keyed only by its slot: a later registration replaces
        # the prior default, while aggregate hints remain independently keyed.
        var removeKeys: seq[string]
        for existingKey, existing in promptHints:
          if existing.slot == slot and existing.mode == "singleton":
            removeKeys.add(existingKey)
        for existingKey in removeKeys:
          promptHints.del(existingKey)
      promptHints[hintKey(slot, source, key)] = PromptHint(
        slot: slot, source: source, key: key, content: content,
        mode: mode, sequence: nextHintSequence)
      okResult(%*{"slot": slot, "source": source, "key": key})
  )

  let schema = toolSchema(%*{
    "cwd": {"type": "string",
            "description": "Working directory the conversation runs in (defaults to the harness root)"}
  }, description = "Return the system prompt for a new conversation. Internal service: core session runners call this once per conversation; not an LLM tool.")
  schema["x-harness"] = %*{"hidden": true, "timeoutMs": 5_000}
  discard comp.tool("systemprompt", schema,
    proc(c: Component, toolArgs: JsonNode): JsonNode =
      let cwd = toolArgs{"cwd"}.getStr(root).expandTilde()

      # --- worktree shadow rule -------------------------------------------
      # When cwd is a linked worktree nested under the main repo, the main
      # repo root's context file is shadowed by the worktree's own copy:
      # the ancestor walk would apply the same logical repo scope twice.
      # `git worktree add` writes a `gitdir: <path>` file into .git (an
      # ordinary repo has a .git directory); the gitdir lives at
      # <main>/.git/worktrees/<name>, so the main root is the prefix before
      # "/.git/worktrees/".
      var shadowed = ""
      if cwd.startsWith(root & "/") and fileExists(root / ".git"):
        try:
          let gitline = readFile(root / ".git").strip()
          if gitline.startsWith("gitdir: "):
            let gitPath = gitline["gitdir: ".len .. ^1].strip()
            let marker = "/.git/worktrees/"
            let idx = gitPath.find(marker)
            if idx > 0:
              let mainRoot = gitPath[0 ..< idx]
              if mainRoot.len > 0 and mainRoot != root:
                let worktreeFile = loadContextFileFromDir(root)
                if worktreeFile.path.len > 0:
                  let cand = mainRoot / contextFileName(worktreeFile.path)
                  if fileExists(cand):
                    shadowed = cand
        except CatchableError:
          discard

      # --- ancestor walk: cwd → the scope root (inclusive) ----------------
      # One file per directory, dedup by path. For workspaces inside the
      # harness root the walk stops AT the root: root is the global scope,
      # and nothing above the deployment root (the machine's own layout, or
      # the git worktree a bench harness happens to live in) may leak into
      # the prompt. Workspaces outside the root stop at the workspace
      # itself — walking to / would pick up stray machine-wide files (an
      # AGENTS.md in $HOME), which is exactly what the root stop avoids.
      let stopAbove = if cwd == root or cwd.startsWith(root & "/"): root else: cwd
      var files: seq[tuple[path, content: string]] = @[]
      var seen: seq[string] = @[]
      var count = 0
      var dir = cwd
      while true:
        let f = loadContextFileFromDir(dir)
        var candidatesHere: seq[tuple[path, content: string]] = @[]
        let primary = loadContextFileFromDir(dir)
        if primary.path.len > 0: candidatesHere.add(primary)
        let local = loadLocalContextFileFromDir(dir)
        if local.path.len > 0: candidatesHere.add(local)
        for f in candidatesHere:
          if f.path != shadowed:
            let fid = fileId(f.path)
            if fid notin seen:
              inc count
              seen.add(fid)
              files.add(f)
              if count >= maxFiles: break
        if count >= maxFiles: break
        if dir == stopAbove or dir == "/" or dir.len <= 1: break
        dir = parentDir(dir)

      # --- compose: product prompt + wrapped context files -----------------
      # Byte-stability: the composed prompt must not embed machine-specific
      # absolute paths ($ROOT, cwd) — the prompt is persisted in the
      # conversation header and its head should stay byte-identical across
      # conversations for provider prompt-cache reuse. Paths are discoverable
      # at runtime (pwd, tool results); the file attribute below is
      # root-relative for the same reason.
      var prompt = basePrompt
      for slot in ["tool_usage", "efficient_tools", "after_instructions"]:
        let hints = renderPromptSlot(slot)
        if hints.len > 0:
          prompt &= "\n\n<prompt_slot name=\"" & slot & "\">\n" & hints &
                    "\n</prompt_slot>\n"

      if cwd != root:
        prompt &= "\n\n<workspace>\nWorkspace: the conversation's working " &
          "directory — relative paths in tool calls resolve from it (`pwd` " &
          "prints the absolute path). Keep all task work inside it; reach " &
          "outside only with absolute paths.\n</workspace>\n"

      if files.len > 0:
        prompt &= "\n\n<project_context>\n\n"
        prompt &= "Project-specific instructions and guidelines:\n\n"
        for f in files:
          # Inside the root: root-relative (byte-stable across machines).
          # Outside: absolute — a relative path would be misleading ../ noise.
          let shown = if f.path.startsWith(root & "/"): relativePath(f.path, root)
                      else: f.path
          prompt &= "<project_instructions path=\"" & shown & "\">\n"
          prompt &= f.content
          prompt &= "\n</project_instructions>\n\n"
        prompt &= "</project_context>\n"

      if prompt.len > maxPromptLen:
        prompt = prompt[0 ..< maxPromptLen] &
          "\n\n[systemprompt: truncated at " & $maxPromptLen & " bytes]\n"

      %*{"systemPrompt": prompt, "contextFiles": int32(files.len)})

  comp.run()

when isMainModule:
  main()
