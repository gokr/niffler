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

  let (server, url) = startNats(routed = true)
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
        r1{"edits_applied"}.getInt(0) == 1 and
        r1{"text"}.getStr("").contains("Successfully applied 1 edit"), $r1)

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
        r5{"edits_applied"}.getInt(0) == 2 and
        r5{"text"}.getStr("").contains("Successfully applied 2 edits"), $r5)

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

  # fallback cascade: indentation drift (full-trim tier)
  writeFile(tmp / "ind.txt", "proc go() =\n    echo 1\n    echo 2\n")
  let r10 = call(nc, "edit", "edit",
                 %*{"path": "ind.txt",
                    "edits": [{"old_string": "echo 1\necho 2",
                               "new_string": "echo 3\necho 4"}]})
  check("edit rescues indentation drift",
        readFile(tmp / "ind.txt") == "proc go() =\necho 3\necho 4\n", $r10)

  # fallback cascade: unicode punctuation folded to ASCII
  writeFile(tmp / "uni.txt", "title = \u{201C}hello\u{201D}\n")
  let r11 = call(nc, "edit", "edit",
                 %*{"path": "uni.txt",
                    "edits": [{"old_string": "title = \"hello\"",
                               "new_string": "title = \"goodbye\""}]})
  check("edit rescues unicode punctuation",
        readFile(tmp / "uni.txt") == "title = \"goodbye\"\n", $r11)

  # fallback cascade: double-escaped old_string
  writeFile(tmp / "esc.txt", "alpha\nbeta\n")
  let r12 = call(nc, "edit", "edit",
                 %*{"path": "esc.txt",
                    "edits": [{"old_string": "alpha\\nbeta",
                               "new_string": "one\ntwo"}]})
  check("edit rescues double-escaped text",
        readFile(tmp / "esc.txt") == "one\ntwo\n", $r12)

  # fallback cascade: block anchors forgive a drifted middle line
  writeFile(tmp / "blk.txt", "func f() {\n  a := 1\n  b := 2\n  c := 3\n}\n")
  let r13 = call(nc, "edit", "edit",
                 %*{"path": "blk.txt",
                    "edits": [{"old_string": "func f() {\n  a := 1\n  b := XX\n  c := 3\n}",
                               "new_string": "func f() {\n  a := 1\n  b := 2\n  c := 30\n}"}]})
  check("edit block-anchor rescues middle drift",
        readFile(tmp / "blk.txt") == "func f() {\n  a := 1\n  b := 2\n  c := 30\n}\n",
        $r13)

  # replace_all: every occurrence, no uniqueness requirement
  writeFile(tmp / "ra.txt", "dup\ndup\nunique\n")
  let r14 = call(nc, "edit", "edit",
                 %*{"path": "ra.txt",
                    "edits": [{"old_string": "dup", "new_string": "new",
                               "replace_all": true}]})
  check("edit replace_all replaces every occurrence",
        readFile(tmp / "ra.txt") == "new\nnew\nunique\n", $r14)

  # lenient input: filePath alias, old_str/new_str aliases, edits as a
  # JSON string (pi's prepareArguments + hashline's normalizeFilePath)
  writeFile(tmp / "len.txt", "value = 1\n")
  let r15 = call(nc, "edit", "edit",
                 %*{"filePath": "len.txt",
                    "edits": "[{\"old_str\": \"value = 1\", \"new_str\": \"value = 2\"}]"})
  check("edit accepts lenient input shapes",
        readFile(tmp / "len.txt") == "value = 2\n", $r15)

  # read: verbatim content, no anchors, pagination, empty/binary refusal
  writeFile(tmp / "r.txt", "one\ntwo\nthree\n")
  let rr1 = call(nc, "edit", "read", %*{"path": "r.txt"})
  check("read returns verbatim content",
        rr1.kind == JString and rr1.getStr("") == "one\ntwo\nthree\n", $rr1)

  # read_many: several files in one call, per-item errors, bounds
  writeFile(tmp / "m1.txt", "alpha\n")
  writeFile(tmp / "m2.txt", "beta\n")
  let rm1 = call(nc, "edit", "read_many",
                 %*{"paths": ["m1.txt", "missing.txt", "m2.txt"]})
  let rm1s = rm1{"text"}.getStr("")
  check("read_many returns files in order with per-item errors",
        rm1{"count"}.getInt(0) == 3 and
        rm1{"items"}[0]{"content"}.getStr("") == "alpha\n" and
        rm1{"items"}[1]{"error"} != nil and
        rm1{"items"}[2]{"content"}.getStr("") == "beta\n" and
        rm1s.find("### m1.txt") >= 0 and
        rm1s.find("### m2.txt") > rm1s.find("### m1.txt"), $rm1)
  let rm2 = call(nc, "edit", "read_many", %*{"paths": []})
  check("read_many refuses empty paths",
        rm2.hasKey("error") and rm2{"error"}.getStr("").contains("1..8"), $rm2)
  let rr2 = call(nc, "edit", "read",
                 %*{"path": "r.txt", "offset": 2, "limit": 1})
  check("read paginates", rr2.getStr("").startsWith("two\n\n[Showing lines 2-2 of 3"), $rr2)
  let rr3 = call(nc, "edit", "read", %*{"path": "r.txt", "offset": 9})
  check("read reports offset beyond EOF",
        rr3.getStr("").contains("beyond end of file"), $rr3)
  writeFile(tmp / "b.dat", "ok\x00bytes")
  let rr4 = call(nc, "edit", "read", %*{"path": "b.dat"})
  check("read refuses binaries", rr4.hasKey("error") and
        rr4{"error"}.getStr("").contains("[E_NOT_TEXT]"), $rr4)

  # write: create with parent dirs, overwrite flag, truncate, permissions,
  # symlink follow-through
  let rw1 = call(nc, "edit", "write",
                 %*{"path": "dir/sub/new.txt", "content": "hello\nworld\n"})
  check("write creates new file",
        rw1{"bytes_written"}.getInt(-1) == 12 and
        rw1{"overwrote"}.getBool(true) == false and
        rw1{"text"}.getStr("").contains("Wrote 12 bytes to"), $rw1)
  check("write created parent dirs",
        readFile(tmp / "dir" / "sub" / "new.txt") == "hello\nworld\n")
  let rw2 = call(nc, "edit", "write",
                 %*{"path": "dir/sub/new.txt", "content": "replaced"})
  check("write overwrites", rw2{"overwrote"}.getBool(false) == true and
        rw2{"text"}.getStr("").contains("Overwrote") and
        readFile(tmp / "dir" / "sub" / "new.txt") == "replaced", $rw2)
  let rw3 = call(nc, "edit", "write",
                 %*{"path": "dir/sub/new.txt", "content": ""})
  check("write truncates on empty content",
        rw3{"bytes_written"}.getInt(-1) == 0 and
        rw3{"text"}.getStr("").contains("Overwrote") and
        rw3{"text"}.getStr("").contains("0 bytes") and
        readFile(tmp / "dir" / "sub" / "new.txt") == "", $rw3)
  let rr5 = call(nc, "edit", "read", %*{"path": "dir/sub/new.txt"})
  check("read reports empty files", rr5.getStr("").contains("is empty"), $rr5)
  let modePath = tmp / "mode.txt"
  writeFile(modePath, "first")
  setFilePermissions(modePath, {fpUserRead, fpUserWrite})
  discard call(nc, "edit", "write",
               %*{"path": "mode.txt", "content": "second"})
  check("write preserves permissions",
        getFilePermissions(modePath) == {fpUserRead, fpUserWrite})
  writeFile(tmp / "target.txt", "old")
  createSymlink("target.txt", tmp / "link.txt")
  let rw4 = call(nc, "edit", "write",
                 %*{"path": "link.txt", "content": "new"})
  check("write follows symlink",
        rw4{"path"}.getStr("").contains("target.txt") and
        readFile(tmp / "target.txt") == "new" and
        symlinkExists(tmp / "link.txt"), $rw4)

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
