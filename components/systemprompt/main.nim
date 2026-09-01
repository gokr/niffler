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

import std/[json, os, strutils]
import natswrapper
import niffler/sdk

const maxPromptLen = 200_000
  ## Core truncates anyway; keep it honest here too — a runaway generated
  ## constitution must not poison every conversation.

const maxFiles = 16
  ## Deep ancestor walks must not blow the cap either.

const basePrompt = staticRead("baseprompt.txt")
  ## The product prompt, baked in at compile time: the repo is the snapshot,
  ## and the prompt must work from any runtime root (sandboxes have no
  ## components/ tree). Editing baseprompt.txt = rebuild + respawn.

const candidates = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD",
                    "CLAUDE.md", "CLAUDE.MD"]

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

proc contextFileName(path: string): string =
  ## The concrete candidate filename a directory resolved to — the shadow
  ## rule must skip the main repo's AGENTS.override.md when the worktree
  ## resolved its own AGENTS.override.md (not a plain AGENTS.md).
  splitFile(path).name & ".md"

proc main() =
  let comp = newComponent("systemprompt", "0.1.0")
  let root = getEnv("NIF_ROOT", getCurrentDir())

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

      # --- ancestor walk: harness root first, then cwd → / -----------------
      # One file per directory, and one per PATH: the harness root is both
      # the global scope and an ancestor of cwd, so dedup by path.
      var files: seq[tuple[path, content: string]] = @[]
      var seen: seq[string] = @[]
      var count = 0
      var dir = cwd
      while true:
        let f = loadContextFileFromDir(dir)
        if f.path.len > 0 and f.path != shadowed:
          let fid = fileId(f.path)
          if fid notin seen:
            inc count
            seen.add(fid)
            files.add(f)
            if count >= maxFiles: break
        if dir == "/" or dir.len <= 1: break
        dir = parentDir(dir)

      # --- compose: product prompt + wrapped context files -----------------
      var prompt = basePrompt.replace("$ROOT", root)

      if files.len > 0:
        prompt &= "\n\n<project_context>\n\n"
        prompt &= "Project-specific instructions and guidelines:\n\n"
        for f in files:
          prompt &= "<project_instructions path=\"" & f.path & "\">\n"
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
