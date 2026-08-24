## grep component — ripgrep-backed code search: `grep` and `files` tools.
##
## Two tools, one backend (ripgrep): `grep` searches file contents,
## `files` lists them. Both respect .gitignore and skip hidden files
## unless asked — bash stays the fallback for everything ripgrep cannot
## express (and for paths whose ignore rules you must bypass).
##
## The pattern travels as an argv to rg, never through an unquoted shell:
## every argument is quoteShell'd, so quotes, backslashes and spaces need
## no escaping by the model — the main reliability win over bash one-liners.

import std/[json, os, osproc, sequtils, strutils, times]
import niffler/sdk

let comp = newComponent("grep", "0.1.0")

const maxOutputBytes = 100_000
  ## Line-capped already (max_results, default 200 lines), so the byte cap
  ## only fires on pathological single lines (minified bundles).

proc capOutput(output: string): string =
  let totalLen = output.len
  if totalLen <= maxOutputBytes: return output
  let headLen = maxOutputBytes div 2
  let tailLen = maxOutputBytes - headLen
  let omitted = totalLen - maxOutputBytes
  result = output[0 ..< headLen] &
    "\n\n[... truncated " & $omitted & " of " & $totalLen &
    " bytes — narrow pattern/path/glob for the missing part ...]\n\n" &
    output[totalLen - tailLen ..< totalLen]

proc capLines(output: string, maxResults: int): string =
  ## Keep the first maxResults lines; drop the tail with an exact marker.
  if output.len == 0: return output
  var lines = output.split('\n')
  if lines[^1].len == 0: lines.setLen(lines.len - 1)  # trailing-newline artifact
  if lines.len <= maxResults: return output
  let kept = lines[0 ..< maxResults].join("\n")
  let dropped = lines.len - maxResults
  result = kept & "\n\n[... " & $dropped & " more result line" &
    (if dropped == 1: "" else: "s") &
    " — raise max_results or narrow pattern/path/glob ...]\n"

var callCounter = 0
  ## Calls are serialized (single-threaded SDK poll loop), so a plain
  ## counter is enough to keep temp-file names unique across calls.

proc runRg(args: seq[string], timeoutMs: int): tuple[code: int, output: string] =
  ## bash -c with every rg argv shell-quoted (the pattern reaches rg
  ## byte-for-byte; the shell only joins words) and combined output
  ## redirected to a temp file — osproc pipes deadlock chatty children,
  ## same fix as the bash component.
  if findExe("rg").len == 0:
    result.code = 127
    result.output = "ripgrep (rg) is not installed on this machine — " &
      "install it (e.g. `sudo apt install ripgrep`) or fall back to " &
      "bash: grep -rn <pattern> <path>"
    return
  inc callCounter
  let tmpPath = getTempDir() /
    ("niffler-grep-" & $getCurrentProcessId() & "-" & $callCounter & ".out")
  let cmd = "( rg " & args.mapIt(quoteShell(it)).join(" ") &
    " ) > " & quoteShell(tmpPath) & " 2>&1"
  var p = startProcess("bash", args = ["-c", cmd], options = {poUsePath})
  result.code = -1
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    result.code = p.peekExitCode()
    if result.code != -1: break
    sleep(50)
  if result.code == -1:
    p.terminate()
    sleep(200)
    if p.running(): p.kill()
    result.code = 124
  p.close()
  try:
    if fileExists(tmpPath):
      result.output = readFile(tmpPath)
  finally:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard

proc finish(code: int, output: string, maxResults: int): JsonNode =
  ## Shared result shape: rg exit code (0 matches / 1 none / 2 error / 124
  ## timeout / 127 missing binary) + line-capped, byte-capped output.
  var o = output
  if code == 124:
    o = "[timed out]\n" & o
  if code == 1 and o.strip().len == 0:
    o = "[no matches]"
  result = %*{"exit_code": code,
              "output": capOutput(capLines(o, maxResults))}

comp.tool:
  proc grep(pattern: string, path: string = ".", glob: string = "",
            context: int = 0, case_insensitive: bool = false,
            hidden: bool = false, max_results: int = 200,
            timeoutMs: int = 30000): JsonNode =
    ## Search file contents with ripgrep and return compact
    ## path:line:match text (with file headings when several files match).
    ## Your primary code-search tool — find definitions, call sites,
    ## config keys, error strings. Faster and safer than bash, because the
    ## pattern travels as an argument, not through a shell: quotes,
    ## backslashes and spaces need no escaping. Skips .gitignore'd paths,
    ## hidden files and binary files by default (a glob only narrows — it
    ## never un-hides). Patterns are Rust regex
    ## (no lookarounds/backreferences; for those use bash `grep -P`).
    ## Prefer narrowing with path/glob over reading large outputs; when
    ## output is truncated the marker says exactly what to narrow.
    ## - pattern: The regex to search for (no shell escaping needed)
    ## - path: File or directory to search (default "." = harness root)
    ## - glob: Only search files matching this glob (e.g. "*.nim"), like rg -g
    ## - context: Lines of context around each match (rg -C)
    ## - case_insensitive: Case-insensitive matching (rg -i)
    ## - hidden: Also search hidden files/directories (.gitignore still applies)
    ## - max_results: Cap on result lines (default 200, max 10000)
    ## - timeoutMs: Kill the search after this many ms (default 30000)
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
    if path.len > 0:
      args.add(path)
    let (code, output) = runRg(args, max(1000, min(timeoutMs, 120_000)))
    return finish(code, output, min(max(1, max_results), 10_000))

comp.tools[^1].schema["x-harness"] = %*{"timeoutMs": 60000}

comp.tool:
  proc files(path: string = ".", glob: string = "", hidden: bool = false,
             max_results: int = 500, timeoutMs: int = 30000): JsonNode =
    ## List repository files, sorted, one path per line — the fastest way
    ## to survey a codebase before searching or editing. Respects
    ## .gitignore and skips hidden files unless hidden: true. Prefer this
    ## over bash ls/find for anything inside the harness root; use bash
    ## when you need metadata (sizes, mtimes) or paths outside the root.
    ## - path: Directory to list (default "." = harness root)
    ## - glob: Only files matching this glob (e.g. "*.nim")
    ## - hidden: Also include hidden files (.gitignore still applies)
    ## - max_results: Cap on file paths (default 500, max 10000)
    ## - timeoutMs: Kill the listing after this many ms (default 30000)
    var args = @["--files", "--no-require-git"]
    if hidden: args.add("--hidden")
    if glob.len > 0:
      args.add(["-g", glob])
      if not hidden:
        # same rg semantics as grep: a positive -g can match hidden paths
        args.add(["-g", "!.*"])
    if path.len > 0:
      args.add(path)
    let (code, output) = runRg(args, max(1000, min(timeoutMs, 120_000)))
    if code == 0 and output.strip().len == 0:
      return %*{"exit_code": 0, "output": "[no files]"}
    return finish(code, output, min(max(1, max_results), 10_000))

comp.tools[^1].schema["x-harness"] = %*{"timeoutMs": 60000}

comp.run()
