## grep component — ripgrep-backed code search: `grep` and `files` tools.
##
## Two tools, one backend (ripgrep): `grep` searches file contents,
## `files` lists them. Both respect .gitignore and skip hidden files
## unless asked — bash stays the fallback for everything ripgrep cannot
## express (and for paths whose ignore rules you must bypass).
##
## The pattern travels as an argv to rg, never through an unquoted shell:
## runArgv quoteShell's every argument, so quotes, backslashes and spaces
## need no escaping by the model — the main reliability win over bash
## one-liners.

import std/[json, os, strutils]
import niffler/sdk

let comp = newComponent("grep", "0.1.0")

const maxOutputBytes = 32_000
  ## Line-capped already (max_results, default 200 lines), so the byte cap
  ## bounds how much of the conversation context one broad search can eat:
  ## a few broad patterns must not cost more than the rest of the turn.
  ## only fires on pathological single lines (minified bundles).

proc runRg(args: seq[string], timeoutMs: int,
           workingDir = ""): tuple[code: int, output: string] =
  if findExe("rg").len == 0:
    result.code = 127
    result.output = "ripgrep (rg) is not installed on this machine — " &
      "install it (e.g. `sudo apt install ripgrep`) or fall back to " &
      "bash: grep -rn <pattern> <path>"
    return
  runArgv("rg", args, timeoutMs, workingDir)

proc finish(code: int, output: string, maxResults: int): JsonNode =
  ## Shared result shape: rg exit code (0 matches / 1 none / 2 error / 124
  ## timeout / 127 missing binary) + line-capped, byte-capped output.
  var o = output
  if code == 124:
    o = "[timed out]\n" & o
  if code == 1 and o.strip().len == 0:
    o = "[no matches]"
  var status = "(exit " & $code & ")"
  if code == 124: status = "(exit 124 — timed out)"
  if code == 127: status = "(exit 127 — ripgrep not installed)"
  result = %*{"exit_code": code,
              "text": status & "\n" & capBytes(
                capLines(o, maxResults,
                         hint = "raise max_results or narrow pattern/path/glob"),
                maxOutputBytes,
                hint = "narrow pattern/path/glob for the missing part")}

comp.tool(%*{"timeoutMs": 60000, "parallel": true,
              "workspace": {"pathFields": ["path"],
                           "defaultPathFields": ["path"]}}):
  proc grep(pattern: string, path: string = ".", glob: string = "",
            context: int = 0, case_insensitive: bool = false,
            hidden: bool = false, max_results: int = 200,
            timeoutMs: int = 30000): JsonNode =
    ## Search file contents with ripgrep (path:line:match). Prefer it over
    ## bash grep: the pattern is an argument (no shell escaping), it skips
    ## gitignored/hidden/binary files, and globs narrow without un-hiding.
    ## Rust regex, no lookarounds (use bash grep -P for those). Narrow with
    ## path/glob — broad patterns are capped (max_results lines, 32KB).
    ## - pattern: Regex to search for (no shell escaping)
    ## - path: File or directory to search (default: workspace, else root)
    ## - glob: Only files matching this glob (e.g. "*.nim"), like rg -g —
    ##   matched relative to ``path`` ("dir/file.nim" finds dir/file.nim
    ##   inside path, not relative to the process cwd)
    ## - context: Lines of context around each match (rg -C)
    ## - case_insensitive: Case-insensitive matching (rg -i)
    ## - hidden: Include hidden files/dirs (.gitignore still applies)
    ## - max_results: Max result lines (default 200, max 10000)
    ## - timeoutMs: Kill after this many ms (default 30000)
    var args = @["--color", "never", "-n", "-I", "--with-filename",
                 "--no-require-git", "--max-columns", "300"]
    if case_insensitive: args.add("-i")
    if hidden: args.add("--hidden")
    if context > 0:
      args.add(["-C", $min(context, 50)])
    if glob.len > 0:
      args.add(["-g", glob])
      if not hidden:
        # a positive -g glob overrides rg's hidden filter (gitignore-style
        # matching lets "*.nim" match ".hidden.nim") — put the exclusion
        # back so the documented contract holds: globs narrow, never un-hide
        args.add(["-g", "!.*"])
    args.add(["--", pattern])
    # rg matches slash-globs against the path relative to ITS cwd, so a
    # glob like "dir/file.py" misses whenever a search root is passed
    # (the walked path carries the root prefix). Chdir into the search
    # root instead — globs become root-relative; pass the root absolutely
    # so it still resolves from the new cwd and results stay absolute.
    let workingDir = if path.len > 0 and dirExists(path): path else: ""
    if path.len > 0:
      args.add(if workingDir.len > 0: absolutePath(path) else: path)
    let (code, output) = runRg(args, max(1000, min(timeoutMs, 120_000)),
                               workingDir)
    return finish(code, output, min(max(1, max_results), 10_000))

comp.tool(%*{"timeoutMs": 60000, "onDemand": true,
              "workspace": {"pathFields": ["path"],
                           "defaultPathFields": ["path"]}}):
  proc files(path: string = ".", glob: string = "", hidden: bool = false,
             max_results: int = 500, timeoutMs: int = 30000): JsonNode =
    ## List repo files sorted, one path per line — survey before searching
    ## or editing. Respects .gitignore; hidden only with hidden: true.
    ## - path: Directory (default: workspace, else harness root)
    ## - glob: Only files matching this glob (e.g. "*.nim"), like rg -g —
    ##   matched relative to ``path``
    ## - hidden: Include hidden files
    ## - max_results: Cap (default 500, max 10000)
    ## - timeoutMs: Kill after this many ms (default 30000)
    var args = @["--files", "--no-require-git"]
    if hidden: args.add("--hidden")
    if glob.len > 0:
      args.add(["-g", glob])
      if not hidden:
        # same rg semantics as grep: a positive -g can match hidden paths
        args.add(["-g", "!.*"])
    let workingDir = if path.len > 0 and dirExists(path): path else: ""
    if path.len > 0:
      # see grep above: chdir into the search root so slash-globs are
      # root-relative; the absolute root keeps results absolute
      args.add(absolutePath(path))
    let (code, output) = runRg(args, max(1000, min(timeoutMs, 120_000)),
                               workingDir)
    if code == 0 and output.strip().len == 0:
      return %*{"exit_code": 0, "text": "[no files]"}
    return finish(code, output, min(max(1, max_results), 10_000))

comp.run()
