## Queue-drain regression: repo-map and LSP diagnostics are independent
## append-only history lanes. No store, model, or language server required.
import helpers
import std/[json, sets]
import ../core/conversation

proc main() =
  check("bare string tool results stay unescaped",
        toolResultText(%"raw\n\"quoted\"\\text\n") == "raw\n\"quoted\"\\text\n")
  check("text projection excludes machine fields",
        toolResultText(%*{"text": "visible", "machine": "hidden"}) == "visible")
  check("non-text JSON retains its serialized result",
        toolResultText(%*[1, true]) == "[1,true]" and
        toolResultText(%42) == "42")
  var maps: seq[tuple[workspace, map: string]] = @[]
  var diags: seq[tuple[path, text: string, clean: bool]] = @[]
  var appended = initHashSet[string]()
  var emittedMaps: seq[string]
  var emittedDiags: seq[string]
  proc takeMap() =
    for (ws, map) in drainMapQueue(maps, appended):
      emittedMaps.add(ws & ":" & map)
  proc takeDiag() =
    for (path, text, clean) in drainDiagnosticsQueue(diags):
      emittedDiags.add(path & ":" & text)

  # The failing input: a diagnostic arrived before the map drain while the
  # map lane was empty (gated or late). Previously drainMap cleared
  # diagStream.queue and the following drainDiagnostics saw nothing.
  diags.add(("src/f.nim", "error: missing name", false))
  takeMap()
  check("empty map lane cannot clear diagnostics", diags.len == 1)
  takeDiag()
  check("diagnostics survive empty map drain", emittedDiags ==
        @["src/f.nim:error: missing name"] and diags.len == 0)

  # Both lanes populated in one round: map appends once; the latest
  # diagnostic per path wins, in first-path order, and all queues drain.
  maps.add(("repo", "ranked symbols"))
  diags.add(("src/f.nim", "old", false))
  diags.add(("src/g.go", "warning", false))
  diags.add(("src/f.nim", "new", false))
  takeMap()
  check("map appends once and never clears the diagnostics lane",
        emittedMaps == @["repo:ranked symbols"] and diags.len == 3 and
        maps.len == 0 and "repo" in appended)
  takeDiag()
  check("latest diagnostic per path and no duplicate", emittedDiags ==
        @["src/f.nim:error: missing name", "src/f.nim:new", "src/g.go:warning"] and
        diags.len == 0)

  # Once a map was appended for a workspace, another map for the SAME
  # workspace is dropped without touching fresh diagnostics (including a
  # second check for the same path).
  maps.add(("repo", "stale map"))
  diags.add(("src/f.nim", "clean", true))
  takeMap()
  takeDiag()
  check("one map per workspace; fresh diagnostic still delivered",
        emittedMaps.len == 1 and maps.len == 0 and
        emittedDiags[^1] == "src/f.nim:clean")

  # A conversation that CHANGES workspace must get the new tree's map. The
  # dedupe key used to be a bare bool ("one map per conversation lifetime"),
  # so a conversation that ran `/worktree add` kept the map of the tree it had
  # left and described the wrong files for the rest of its life — exactly the
  # report "the workspace is X but the repo map shown is from Y".
  maps.add(("repo.wt/feat", "worktree symbols"))
  takeMap()
  check("a moved conversation gets the map of its NEW workspace",
        emittedMaps.len == 2 and emittedMaps[^1] == "repo.wt/feat:worktree symbols",
        $emittedMaps)
  # ...and moving back does not re-append the first tree again.
  maps.add(("repo", "ranked symbols"))
  takeMap()
  check("returning to a workspace already mapped does not duplicate it",
        emittedMaps.len == 2, $emittedMaps)

  check("clean verdict has no model message",
        diagnosticMessage("f.go", "clean", true) == nil)
  check("failed checks and warnings remain model context",
        diagnosticMessage("f.go", "timeout", false){"content"}.getStr("") != "")
  diags.add(("f.go", "error", false))
  diags.add(("f.go", "clean", true))
  let latest = drainDiagnosticsQueue(diags)
  check("newest clean verdict supersedes stale error without losing status",
        latest.len == 1 and latest[0].clean and latest[0].text == "clean")
  report("CONTEXT DRAINS")

main()
