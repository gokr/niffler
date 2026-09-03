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

const maxOutputBytes = 100_000
  ## Line-capped already (max_results, default 200 lines), so the byte cap
  ## only fires on pathological single lines (minified bundles).

proc runRg(args: seq[string], timeoutMs: int): tuple[code: int, output: string] =
  if findExe("rg").len == 0:
    result.code = 127
    result.output = "ripgrep (rg) is not installed on this machine — " &
      "install it (e.g. `sudo apt install ripgrep`) or fall back to " &
      "bash: grep -rn <pattern> <path>"
    return
  runArgv("rg", args, timeoutMs)

proc finish(code: int, output: string, maxResults: int): JsonNode =
  ## Shared result shape: rg exit code (0 matches / 1 none / 2 error / 124
  ## timeout / 127 missing binary) + line-capped, byte-capped output.
  var o = output
  if code == 124:
    o = "[timed out]\n" & o
  if code == 1 and o.strip().len == 0:
    o = "[no matches]"
  result = %*{"exit_code": code,
              "output": capBytes(
                capLines(o, maxResults,
                         hint = "raise max_results or narrow pattern/path/glob"),
                maxOutputBytes,
                hint = "narrow pattern/path/glob for the missing part")}

comp.tool(%*{"timeoutMs": 60000, "parallel": true, "onDemand": true,
              "workspace": {"pathFields": ["path"],
                           "defaultPathFields": ["path"]}}):
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
    ## - path: File or directory to search (default: the active conversation
    ##   workspace, else the harness root)
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

comp.tool(%*{"timeoutMs": 60000,
              "workspace": {"pathFields": ["path"],
                           "defaultPathFields": ["path"]}}):
  proc files(path: string = ".", glob: string = "", hidden: bool = false,
             max_results: int = 500, timeoutMs: int = 30000): JsonNode =
    ## List repository files, sorted, one path per line — the fastest survey
    ## before searching or editing. Respects .gitignore; hidden files only
    ## with hidden: true. Prefer over bash ls/find inside the harness root.
    ## - path: Directory to list (default: the active conversation
    ##   workspace, else the harness root)
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

comp.run()
