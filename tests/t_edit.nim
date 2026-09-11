## edit component tests — bus contract: registration + exact-match editing.
##
## Spawns edit against a throwaway NATS and drives it with envelopes:
## simple replace, ambiguity refusal, not-found refusal, trailing-whitespace
## fallback, multi-edit, overlap refusal, deletion, CRLF preservation,
## binary/empty refusal, undo (single-level, stale-refused, persisted across
## a component restart). Uses a temp NIF_ROOT and a temp XDG_CONFIG_HOME so
## the real undo store is untouched.

import std/[json, os, osproc, strutils]
when defined(nifflerNimNats):
  # Pure-Nim client (github.com/gokr/natsnim), aliased to `natswrapper` so every
  # call site below stays byte-identical. Enabled with
  #   make build NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
  # See docs/research/NATSNIM.md.
  import natsnim as natswrapper
else:
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

  # read: canonical "reads" array — several files/ranges in one call,
  # per-item errors, bounds; union semantics, legacy aliases, the cap
  writeFile(tmp / "m1.txt", "alpha\n")
  writeFile(tmp / "m2.txt", "beta\n")
  writeFile(tmp / "m3.txt", "one\ntwo\nthree\n")
  let rm1 = call(nc, "edit", "read",
                 %*{"reads": [{"path": "m1.txt"}, {"path": "missing.txt"},
                              {"path": "m2.txt"}]})
  let rm1s = rm1{"text"}.getStr("")
  check("read reads returns items in order with per-item errors",
        rm1{"count"}.getInt(0) == 3 and
        rm1{"items"}[0]{"content"}.getStr("") == "alpha\n" and
        rm1{"items"}[1]{"error"} != nil and
        rm1{"items"}[2]{"content"}.getStr("") == "beta\n" and
        rm1s.find("### m1.txt") >= 0 and
        rm1s.find("### m2.txt") > rm1s.find("### m1.txt"), $rm1)
  let rm2 = call(nc, "edit", "read", %*{"reads": []})
  check("read refuses an empty reads array",
        rm2.hasKey("error") and rm2{"error"}.getStr("").contains("requires"), $rm2)
  let rm3 = call(nc, "edit", "read",
                 %*{"path": "m1.txt", "reads": [{"path": "m2.txt"}]})
  check("read unions sugar path + reads (sugar first)",
        rm3{"count"}.getInt(0) == 2 and
        rm3{"items"}[0]{"content"}.getStr("") == "alpha\n" and
        rm3{"items"}[1]{"content"}.getStr("") == "beta\n" and
        rm3{"text"}.getStr("").find("### m1.txt") <
          rm3{"text"}.getStr("").find("### m2.txt"), $rm3)
  let rm4 = call(nc, "edit", "read", %*{})
  check("read refuses an empty request",
        rm4.hasKey("error") and rm4{"error"}.getStr("").contains("requires"), $rm4)
  let rm5 = call(nc, "edit", "read",
                 %*{"reads": [{"path": "m3.txt", "offset": 2, "limit": 1},
                              {"path": "m1.txt"}]})
  check("read reads honours per-item offset/limit",
        rm5{"items"}[0]{"content"}.getStr("").startsWith("two\n") and
        rm5{"text"}.getStr("").contains("m3.txt:2+1") and
        rm5{"items"}[1]{"content"}.getStr("") == "alpha\n", $rm5)
  let rm6 = call(nc, "edit", "read", %*{"paths": ["m1.txt", "m2.txt"]})
  check("legacy paths alias still batches",
        rm6{"count"}.getInt(0) == 2 and
        rm6{"text"}.getStr("").contains("### m1.txt") and
        rm6{"text"}.getStr("").contains("### m2.txt"), $rm6)
  let rm7 = call(nc, "edit", "read",
                 %*{"windows": [{"path": "m1.txt"}]})
  check("legacy windows alias still reads (single item = plain content)",
        rm7.kind == JString and rm7.getStr("") == "alpha\n", $rm7)
  # the GPT-6 regression: path + a window on the same file was rejected as
  # E_BAD_SHAPE; union semantics now honor it — full file plus the window
  let rm8 = call(nc, "edit", "read",
                 %*{"path": "m3.txt", "limit": 2000,
                    "windows": [{"path": "m3.txt", "limit": 1}]})
  check("union path+window works as intended (no exclusivity)",
        rm8{"count"}.getInt(0) == 2 and
        rm8{"items"}[0]{"content"}.getStr("").startsWith("one\n") and
        rm8{"items"}[1]{"content"}.getStr("").startsWith("one\n"), $rm8)
  let rm9 = call(nc, "edit", "read",
                 %*{"path": "m1.txt", "reads": [{"path": "m1.txt"}]})
  check("identical union items dedupe to a single read",
        rm9.kind == JString and rm9.getStr("") == "alpha\n", $rm9)
  let rm10 = call(nc, "edit", "read",
                  %*{"reads": [{"path": 5}]})
  check("malformed reads item becomes a per-item error",
        rm10{"count"}.getInt(0) == 1 and rm10{"items"}[0]{"error"} != nil and
        rm10{"text"}.getStr("").contains("[E_BAD_SHAPE]"), $rm10)
  var many = newJArray()
  for i in 1 .. 13: many.add(%*{"path": "f" & $i & ".txt"})
  let rm11 = call(nc, "edit", "read", %*{"reads": many})
  check("read caps batches at 12 items",
        rm11.hasKey("error") and
        rm11{"error"}.getStr("").contains("at most 12"), $rm11)
  let rm12 = call(nc, "edit", "read", %*{"reads": "m1.txt"})
  check("a bare string reads item is sugar for one file",
        rm12.kind == JString and rm12.getStr("") == "alpha\n", $rm12)
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
        rw1{"lines"}.getInt(-1) == 2 and
        rw1{"digest"}.getStr("").len == 40 and
        rw1{"text"}.getStr("").contains("Wrote 12 bytes (2 lines, digest"), $rw1)
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

  # --- seen-state: per-session tracking (write digest, read stub, E_STALE) ---
  let bigContent = repeat("line of text that keeps going\n", 40)  # ≥ 512B
  discard call(nc, "edit", "write",
               %*{"path": "w.txt", "content": bigContent,
                  "__session": {"session": "s1"}})
  let rs1 = call(nc, "edit", "read",
                 %*{"path": "w.txt", "__session": {"session": "s1"}})
  check("unchanged re-read returns compact stub",
        rs1.getStr("").startsWith("[unchanged]") and
        rs1.getStr("").contains("digest") and
        rs1.getStr("").contains("40 lines"), $rs1)
  let rf = call(nc, "edit", "read",
                %*{"path": "w.txt", "force": true,
                   "__session": {"session": "s1"}})
  check("force re-dumps the bytes", rf.getStr("") == bigContent, $rf)
  let rs2 = call(nc, "edit", "read",
                 %*{"path": "w.txt", "__session": {"session": "s2"}})
  check("other session gets full bytes (no cross-talk)",
        rs2.getStr("") == bigContent, $rs2)
  let rn = call(nc, "edit", "read", %*{"path": "w.txt"})
  check("sessionless read (cli) always dumps", rn.getStr("") == bigContent, $rn)

  # below the stub threshold: unchanged re-read just re-dumps
  writeFile(tmp / "tiny.txt", "small\n")
  discard call(nc, "edit", "write",
               %*{"path": "tiny.txt", "content": "small\n",
                  "__session": {"session": "s1"}})
  let rt = call(nc, "edit", "read",
                %*{"path": "tiny.txt", "__session": {"session": "s1"}})
  check("tiny unchanged re-read dumps normally",
        rt.getStr("").startsWith("small\n"), $rt)

  # edit refuses stale content before matching, works after a fresh read
  writeFile(tmp / "stale.txt", bigContent)
  discard call(nc, "edit", "read",
               %*{"path": "stale.txt", "__session": {"session": "s1"}})
  writeFile(tmp / "stale.txt", bigContent & "external line\n")
  let rse = call(nc, "edit", "edit",
                 %*{"path": "stale.txt",
                    "edits": [{"old_string": "line of text that keeps going",
                               "new_string": "CHANGED"}],
                    "__session": {"session": "s1"}})
  check("edit refuses stale content with E_STALE", rse.hasKey("error") and
        rse{"error"}.getStr("").contains("[E_STALE]"), $rse)
  discard call(nc, "edit", "read",
               %*{"path": "stale.txt", "__session": {"session": "s1"}})
  let rse2 = call(nc, "edit", "edit",
                  %*{"path": "stale.txt",
                     "edits": [{"old_string": "external line",
                                "new_string": "seen"}],
                     "__session": {"session": "s1"}})
  check("edit works after fresh read", rse2.hasKey("edits_applied"), $rse2)
  let rse3 = call(nc, "edit", "read",
                  %*{"path": "stale.txt", "__session": {"session": "s1"}})
  check("re-read after own edit is stubbed (full carried)",
        rse3.getStr("").startsWith("[unchanged]"), $rse3)

  # read batch: first pass dumps (m1 unseen, m2 externally changed since
  # its tracked write), second pass stubs both unchanged files per-item
  writeFile(tmp / "m1.txt", bigContent)
  writeFile(tmp / "m2.txt", bigContent)
  discard call(nc, "edit", "write",
               %*{"path": "m2.txt", "content": bigContent,
                  "__session": {"session": "s1"}})
  writeFile(tmp / "m2.txt", bigContent & "tail\n")
  let rm = call(nc, "edit", "read",
                %*{"windows": [{"path": "m1.txt"}, {"path": "m2.txt"}],
                   "__session": {"session": "s1"}})
  check("read batch dumps unseen and changed files",
        rm{"text"}.getStr("").contains("### m1.txt") and
        not rm{"text"}.getStr("").contains("[unchanged] m1.txt") and
        not rm{"text"}.getStr("").contains("[unchanged] m2.txt"), $rm)
  let rmst = call(nc, "edit", "read",
                 %*{"reads": [{"path": "m1.txt"}, {"path": "m2.txt"}],
                    "__session": {"session": "s1"}})
  check("read batch stubs unchanged files",
        rmst{"text"}.getStr("").contains("[unchanged] m1.txt") and
        rmst{"text"}.getStr("").contains("[unchanged] m2.txt") and
        rmst{"items"}[0]{"content"}.getStr("").startsWith("[unchanged]"), $rmst)

  # after undo the restored bytes were only diffed, never delivered: read dumps
  writeFile(tmp / "u2.txt", bigContent)
  discard call(nc, "edit", "edit",
               %*{"path": "u2.txt",
                  "edits": [{"old_string": "line of text that keeps going",
                             "new_string": "edited", "replace_all": true}],
                  "__session": {"session": "s1"}})
  discard call(nc, "edit", "undo_last_edit",
               %*{"path": "u2.txt", "__session": {"session": "s1"}})
  let ru3 = call(nc, "edit", "read",
                 %*{"path": "u2.txt", "__session": {"session": "s1"}})
  check("read after undo dumps restored bytes",
        ru3.getStr("") == bigContent, $ru3)

  # a read that observes different bytes persists the correction: without
  # this, a stale persisted entry (restarted/duplicate process, resumed run
  # against a re-prepared repo) keeps refusing edits that re-reads cannot
  # clear even though the file on disk is current.
  writeFile(tmp / "wedge.txt", bigContent)
  discard call(nc, "edit", "write",
               %*{"path": "wedge.txt", "content": bigContent,
                  "__session": {"session": "s1"}})
  writeFile(tmp / "wedge.txt", bigContent & "external tail\n")
  discard call(nc, "edit", "read",
               %*{"path": "wedge.txt", "force": true,
                  "__session": {"session": "s1"}})
  var persisted = false
  let store = tmp / "config" / "niffler-edit" / "undo.json"
  if fileExists(store):
    for key, node in parseJson(readFile(store)){"seen"}:
      if key.contains("wedge.txt") and
          node{"bytes"}.getInt(0) == readFile(tmp / "wedge.txt").len:
        persisted = true
  check("changed read persists the observed bytes", persisted, store)
  let rw = call(nc, "edit", "edit",
                %*{"path": "wedge.txt",
                   "edits": [{"old_string": "external tail",
                              "new_string": "edited tail"}],
                   "__session": {"session": "s1"}})
  check("edit passes after the corrected read",
        not rw.hasKey("error") and
        readFile(tmp / "wedge.txt").contains("edited tail"), $rw)

  # the read nudge: three consecutive full single-file reads append a
  # batching hint, then it rearms; a multi-item batch resets the counter
  discard call(nc, "edit", "write",
               %*{"path": "n1.txt", "content": "a\n", "__session": {"session": "sn"}})
  discard call(nc, "edit", "write",
               %*{"path": "n2.txt", "content": "b\n", "__session": {"session": "sn"}})
  discard call(nc, "edit", "write",
               %*{"path": "n3.txt", "content": "c\n", "__session": {"session": "sn"}})
  let n1 = call(nc, "edit", "read",
                %*{"path": "n1.txt", "__session": {"session": "sn"}})
  check("first read has no nudge", not n1.getStr("").contains("[hint:"), $n1)
  let n2 = call(nc, "edit", "read",
                %*{"path": "n2.txt", "__session": {"session": "sn"}})
  check("second read has no nudge", not n2.getStr("").contains("[hint:"), $n2)
  let n3 = call(nc, "edit", "read",
                %*{"path": "n3.txt", "__session": {"session": "sn"}})
  check("third read appends the reads hint",
        n3.getStr("").contains("[hint:") and n3.getStr("").contains("reads"), $n3)
  let nb = call(nc, "edit", "read",
                %*{"reads": [{"path": "n1.txt"}, {"path": "n2.txt"}],
                   "__session": {"session": "sn"}})
  check("reads batch has no nudge",
        not nb{"text"}.getStr("").contains("[hint:"), $nb)
  discard call(nc, "edit", "read",
               %*{"path": "n1.txt", "__session": {"session": "sn"}})
  discard call(nc, "edit", "read",
               %*{"path": "n2.txt", "__session": {"session": "sn"}})
  let n5 = call(nc, "edit", "read",
                %*{"path": "n3.txt", "__session": {"session": "sn"}})
  check("nudge rearms after a batch",
        n5.getStr("").contains("[hint:"), $n5)

  # seen-state persists across a restart (mutations persist alongside undo);
  # the restarted component serves the remaining tests
  e2.terminate()
  sleep(400)
  let e3 = startComponent(bin, url, root = tmp,
                          extra = [("XDG_CONFIG_HOME", tmp / "config")])
  defer:
    if e3.running():
      e3.terminate()
      sleep(200)
    e3.close()
  check("edit re-registers after second restart", waitRegistered(nc, "edit"))
  let rp2 = call(nc, "edit", "read",
                 %*{"path": "w.txt", "__session": {"session": "s1"}})
  check("seen-state persists across restart",
        rp2.getStr("").startsWith("[unchanged]"), $rp2)

  # drain: the (twice-restarted) component exits
  drain(nc)
  sleep(700)
  check("edit drains and exits", not e3.running())

  report("EDIT TEST")

main()
