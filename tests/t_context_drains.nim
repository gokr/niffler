## Queue-drain regression: repo-map and LSP diagnostics are independent
## append-only history lanes. No store, model, or language server required.
import helpers
import ../core/conversation

proc main() =
  var maps: seq[tuple[workspace, map: string]] = @[]
  var diags: seq[tuple[path, text: string]] = @[]
  var appended = false
  var emittedMaps: seq[string]
  var emittedDiags: seq[string]
  proc takeMap() =
    for (ws, map) in drainMapQueue(maps, appended):
      emittedMaps.add(ws & ":" & map)
  proc takeDiag() =
    for (path, text) in drainDiagnosticsQueue(diags):
      emittedDiags.add(path & ":" & text)

  # The failing input: a diagnostic arrived before the map drain while the
  # map lane was empty (gated or late). Previously drainMap cleared
  # diagStream.queue and the following drainDiagnostics saw nothing.
  diags.add(("src/f.nim", "error: missing name"))
  takeMap()
  check("empty map lane cannot clear diagnostics", diags.len == 1)
  takeDiag()
  check("diagnostics survive empty map drain", emittedDiags ==
        @["src/f.nim:error: missing name"] and diags.len == 0)

  # Both lanes populated in one round: map appends once; the latest
  # diagnostic per path wins, in first-path order, and all queues drain.
  maps.add(("repo", "ranked symbols"))
  diags.add(("src/f.nim", "old"))
  diags.add(("src/g.go", "warning"))
  diags.add(("src/f.nim", "new"))
  takeMap()
  check("map appends once and never clears the diagnostics lane",
        emittedMaps == @["repo:ranked symbols"] and diags.len == 3 and
        maps.len == 0 and appended)
  takeDiag()
  check("latest diagnostic per path and no duplicate", emittedDiags ==
        @["src/f.nim:error: missing name", "src/f.nim:new", "src/g.go:warning"] and
        diags.len == 0)

  # Once a map was appended, subsequent maps are dropped without touching
  # fresh diagnostics (including a second check for the same path).
  maps.add(("repo", "stale map"))
  diags.add(("src/f.nim", "clean"))
  takeMap()
  takeDiag()
  check("one map per conversation; fresh diagnostic still delivered",
        emittedMaps.len == 1 and maps.len == 0 and
        emittedDiags[^1] == "src/f.nim:clean")

  report("CONTEXT DRAINS")

main()
