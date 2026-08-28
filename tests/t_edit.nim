## edit component tests — bus contract: registration + exact-match editing.
##
## Spawns edit against a throwaway NATS and drives it with envelopes:
## simple replace, ambiguity refusal, not-found refusal, trailing-whitespace
## fallback, multi-edit, overlap refusal, deletion, CRLF preservation,
## binary/empty refusal, undo (single-level, stale-refused, persisted across
## a component restart). Uses a temp NIF_ROOT and a temp XDG_CONFIG_HOME so
## the real undo store is untouched.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "edit"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("edit")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let eProc = startComponent(bin, url, root = tmp,
                             extra = [("XDG_CONFIG_HOME", tmp / "config")])
  defer:
    if eProc.running():
      eProc.terminate()
      sleep(200)
    eProc.close()

  check("edit registers", waitRegistered(nc, "edit"))

  # simple replace
  writeFile(tmp / "a.txt", "hello\nworld\n")
  let r1 = call(nc, "edit", "edit",
                %*{"path": "a.txt",
                   "edits": [{"old_string": "hello", "new_string": "hi"}]})
  check("edit replaces text",
        readFile(tmp / "a.txt") == "hi\nworld\n" and
        r1{"edits_applied"}.getInt(0) == 1, $r1)

  # ambiguity refused, file untouched
  writeFile(tmp / "amb.txt", "same\nsame\n")
  let r2 = call(nc, "edit", "edit",
                %*{"path": "amb.txt",
                   "edits": [{"old_string": "same", "new_string": "x"}]})
  check("edit refuses ambiguous match", r2.hasKey("error") and
        r2{"error"}.getStr("").contains("occurs 2 times"), $r2)
  check("ambiguous edit wrote nothing",
        readFile(tmp / "amb.txt") == "same\nsame\n")

  # not found refused
  let r3 = call(nc, "edit", "edit",
                %*{"path": "a.txt",
                   "edits": [{"old_string": "nope", "new_string": "x"}]})
  check("edit refuses missing text", r3.hasKey("error") and
        r3{"error"}.getStr("").contains("[E_NOT_FOUND]"), $r3)

  # fuzzy: trailing whitespace on file lines forgiven
  writeFile(tmp / "fuzzy.txt", "alpha   \nbeta\n")
  let r4 = call(nc, "edit", "edit",
                %*{"path": "fuzzy.txt",
                   "edits": [{"old_string": "alpha\nbeta",
                              "new_string": "one\ntwo"}]})
  check("edit fuzzy-matches trailing whitespace",
        readFile(tmp / "fuzzy.txt") == "one\ntwo\n", $r4)

  # several edits in one call, all matched against the original
  writeFile(tmp / "multi.txt", "aaa\nbbb\nccc\n")
  let r5 = call(nc, "edit", "edit",
                %*{"path": "multi.txt",
                   "edits": [{"old_string": "aaa", "new_string": "AAA"},
                             {"old_string": "ccc", "new_string": "CCC"}]})
  check("edit applies multiple edits",
        readFile(tmp / "multi.txt") == "AAA\nbbb\nCCC\n" and
        r5{"edits_applied"}.getInt(0) == 2, $r5)

  # overlapping edits refused
  let r6 = call(nc, "edit", "edit",
                %*{"path": "multi.txt",
                   "edits": [{"old_string": "AAA\nbbb", "new_string": "x"},
                             {"old_string": "bbb\nCCC", "new_string": "y"}]})
  check("edit refuses overlapping edits", r6.hasKey("error") and
        r6{"error"}.getStr("").contains("[E_OVERLAP]"), $r6)

  # deletion via empty new_string
  writeFile(tmp / "del.txt", "keep\ndrop\nkeep2\n")
  let r7 = call(nc, "edit", "edit",
                %*{"path": "del.txt",
                   "edits": [{"old_string": "drop\n", "new_string": ""}]})
  check("edit deletes lines", readFile(tmp / "del.txt") == "keep\nkeep2\n", $r7)

  # CRLF endings preserved outside the edit
  writeFile(tmp / "crlf.txt", "a\r\nb\r\n")
  discard call(nc, "edit", "edit",
               %*{"path": "crlf.txt",
                  "edits": [{"old_string": "b", "new_string": "c"}]})
  check("edit preserves CRLF endings", readFile(tmp / "crlf.txt") == "a\r\nc\r\n")

  # binary refused
  writeFile(tmp / "bin.dat", "ok\x00bytes")
  let r8 = call(nc, "edit", "edit",
                %*{"path": "bin.dat",
                   "edits": [{"old_string": "ok", "new_string": "x"}]})
  check("edit refuses binaries", r8.hasKey("error") and
        r8{"error"}.getStr("").contains("[E_NOT_TEXT]"), $r8)

  # empty file refused
  writeFile(tmp / "empty.txt", "")
  let r9 = call(nc, "edit", "edit",
                %*{"path": "empty.txt",
                   "edits": [{"old_string": "x", "new_string": "y"}]})
  check("edit refuses empty files", r9.hasKey("error") and
        r9{"error"}.getStr("").contains("[E_EMPTY]"), $r9)

  # undo reverts the last edit, then the history is consumed
  writeFile(tmp / "u.txt", "one\ntwo\n")
  discard call(nc, "edit", "edit",
               %*{"path": "u.txt",
                  "edits": [{"old_string": "two", "new_string": "TWO"}]})
  let ru = call(nc, "edit", "undo_last_edit", %*{"path": "u.txt"})
  check("undo reverts last edit", readFile(tmp / "u.txt") == "one\ntwo\n", $ru)
  let ru2 = call(nc, "edit", "undo_last_edit", %*{"path": "u.txt"})
  check("second undo refused", ru2.hasKey("error") and
        ru2{"error"}.getStr("").contains("No undo history"), $ru2)

  # undo persists across a component restart; the restarted process serves
  # the remaining tests (a defer inside a block would kill it immediately)
  writeFile(tmp / "p.txt", "keep\n")
  discard call(nc, "edit", "edit",
               %*{"path": "p.txt",
                  "edits": [{"old_string": "keep", "new_string": "kept"}]})
  eProc.terminate()
  sleep(400)
  let e2 = startComponent(bin, url, root = tmp,
                          extra = [("XDG_CONFIG_HOME", tmp / "config")])
  defer:
    if e2.running():
      e2.terminate()
      sleep(200)
    e2.close()
  check("edit re-registers after restart", waitRegistered(nc, "edit"))
  let rp = call(nc, "edit", "undo_last_edit", %*{"path": "p.txt"})
  check("undo persists across restart",
        readFile(tmp / "p.txt") == "keep\n", $rp)

  # undo refused when the file changed after the edit
  writeFile(tmp / "s.txt", "a\nb\n")
  discard call(nc, "edit", "edit",
               %*{"path": "s.txt",
                  "edits": [{"old_string": "b", "new_string": "B"}]})
  writeFile(tmp / "s.txt", "a\nb\nCHANGED\n")
  let rs = call(nc, "edit", "undo_last_edit", %*{"path": "s.txt"})
  check("undo refused after external modification", rs.hasKey("error") and
        rs{"error"}.getStr("").contains("[E_UNDO_STALE]"), $rs)
  check("stale undo left file alone",
        readFile(tmp / "s.txt") == "a\nb\nCHANGED\n")

  # drain: the (restarted) component exits
  drain(nc)
  sleep(700)
  check("edit drains and exits", not e2.running())

  report("EDIT TEST")

main()
