## grep component tests — bus contract: registration + grep/files behaviour.
##
## Spawns grep against a throwaway NATS and drives it with envelopes:
## matches, line numbers, gitignore/hidden handling, globs, case folding,
## regex errors, result caps, and the files tool.

import std/[json, os, osproc, strutils]
import natsnim
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "grep"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("grep")
  defer: removeDir(tmp)

  # fixture tree: two .nim files, one gitignored text file, one hidden file,
  # one nested file, plus a big file for the truncation test
  createDir(tmp / "src")
  createDir(tmp / "sub")
  writeFile(tmp / "src" / "alpha.nim", "proc helloWorld() =\n  echo \"hello\"\n")
  writeFile(tmp / "src" / "beta.nim", "proc helloNim() =\n  echo \"HELLO\"\n")
  writeFile(tmp / "notes.txt", "hello world\n")
  writeFile(tmp / ".hidden.nim", "proc helloHidden() = discard\n")
  writeFile(tmp / "sub" / "nested.txt", "hello nested\n")
  writeFile(tmp / ".gitignore", "notes.txt\n")
  var many = ""
  for i in 1 .. 500: many.add("needle " & $i & "\n")
  writeFile(tmp / "many.txt", many)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let gProc = startComponent(bin, url, root = tmp)
  defer:
    if gProc.running():
      gProc.terminate()
      sleep(200)
    gProc.close()

  check("grep registers", waitRegistered(nc, "grep"))

  # basic search: match found, path + line number in output
  let r1 = call(nc, "grep", "grep", %*{"pattern": "helloWorld"})
  check("grep exit 0 on match", r1{"exit_code"}.getInt(-1) == 0, $r1)
  let out1 = r1{"text"}.getStr("")
  check("grep shows path:line", out1.contains("alpha.nim") and
        out1.contains(":1:"), $r1)
  check("grep shows match text", out1.contains("helloWorld"), $r1)

  # .gitignore respected, hidden files skipped by default
  let r2 = call(nc, "grep", "grep", %*{"pattern": "hello"})
  let out2 = r2{"text"}.getStr("")
  check("grep respects gitignore", not out2.contains("notes.txt"), $r2)
  check("grep skips hidden files", not out2.contains("hidden.nim"), $r2)
  check("grep searches nested dirs", out2.contains("nested.txt"), $r2)

  # hidden: true includes hidden files (gitignore still applies)
  let r3 = call(nc, "grep", "grep",
                %*{"pattern": "helloHidden", "hidden": true})
  check("grep hidden:true finds hidden",
        r3{"exit_code"}.getInt(-1) == 0 and
        r3{"text"}.getStr("").contains("hidden.nim"), $r3)

  # glob filter narrows to .nim files
  let r4 = call(nc, "grep", "grep", %*{"pattern": "hello", "glob": "*.nim"})
  let out4 = r4{"text"}.getStr("")
  check("grep glob filters", out4.contains("alpha.nim") and
        not out4.contains("nested.txt"), $r4)

  # slash-glob is matched relative to path, not the process cwd
  # (regression: rg walks paths with the root prefix, so glob
  # "sub/nested.txt" + path "sub" used to return [no matches])
  let r4b = call(nc, "grep", "grep", %*{"pattern": "hello nested",
              "path": "sub", "glob": "nested.txt"})
  check("grep slash-glob matches relative to path",
        r4b{"exit_code"}.getInt(-1) == 0 and
        r4b{"text"}.getStr("").contains("nested.txt"), $r4b)
  let f4b = call(nc, "grep", "files", %*{"path": "sub",
              "glob": "nested.txt"})
  check("files slash-glob matches relative to path",
        f4b{"exit_code"}.getInt(-1) == 0 and
        f4b{"text"}.getStr("").contains("nested.txt"), $f4b)

  # case-insensitive matching
  let r5 = call(nc, "grep", "grep",
                %*{"pattern": "hello", "case_insensitive": true,
                   "path": "src/beta.nim"})
  check("grep case_insensitive", r5{"exit_code"}.getInt(-1) == 0 and
        r5{"text"}.getStr("").contains("HELLO"), $r5)

  # no matches: exit 1 with marker
  let r6 = call(nc, "grep", "grep", %*{"pattern": "zzzNoSuchThing"})
  check("grep no matches exit 1", r6{"exit_code"}.getInt(-1) == 1 and
        r6{"text"}.getStr("").contains("[no matches]"), $r6)

  # bad regex: exit 2, error text shown
  let r7 = call(nc, "grep", "grep", %*{"pattern": "["})
  check("grep bad regex exit 2", r7{"exit_code"}.getInt(-1) == 2 and
        r7{"text"}.getStr("").len > 0, $r7)

  # max_results caps lines with an exact marker
  let r8 = call(nc, "grep", "grep",
                %*{"pattern": "needle", "path": "many.txt",
                   "max_results": 10})
  let out8 = r8{"text"}.getStr("")
  check("grep caps result lines", out8.contains("needle 10") and
        not out8.contains("needle 11"), $r8)
  check("grep truncation marker counts", out8.contains("490 more result lines"),
        $r8)

  # files tool: sorted listing, gitignore + hidden respected
  let f1 = call(nc, "grep", "files", %*{})
  let outf1 = f1{"text"}.getStr("")
  check("files lists tracked files",
        outf1.contains("src/alpha.nim") and outf1.contains("src/beta.nim") and
        outf1.contains("sub/nested.txt"), $f1)
  check("files respects gitignore", not outf1.contains("notes.txt"), $f1)
  check("files skips hidden", not outf1.contains("hidden.nim"), $f1)

  let f2 = call(nc, "grep", "files", %*{"hidden": true})
  check("files hidden:true lists hidden",
        f2{"text"}.getStr("").contains(".hidden.nim"), $f2)

  let f3 = call(nc, "grep", "files", %*{"glob": "*.nim"})
  let outf3 = f3{"text"}.getStr("")
  check("files glob filters", outf3.contains("alpha.nim") and
        not outf3.contains("nested.txt"), $f3)

  # files max_results caps
  let f4 = call(nc, "grep", "files",
                %*{"path": "many.txt", "max_results": 1})
  check("files caps paths", f4{"text"}.getStr("").contains("many.txt"),
        $f4)

  # Private workspace context changes display only, including context records.
  let source = "path-marker " & tmp & "/src/alpha.nim"
  writeFile(tmp / "src" / "paths.txt", "before " & source & "\n" & source & "\nafter\n")
  let relative = call(nc, "grep", "grep", %*{"pattern": "^path-marker",
    "path": tmp / "src", "context": 1, "__workspace": {"root": tmp}})
  let relativeText = relative{"text"}.getStr("")
  check("grep displays workspace-relative match and context paths",
    relativeText.contains("\nsrc/paths.txt:2:" & source) and
    relativeText.contains("\nsrc/paths.txt-1-before " & source), $relative)
  check("grep never rewrites paths inside matched source",
    relativeText.contains(source), $relative)
  let unchanged = call(nc, "grep", "grep", %*{"pattern": "^path-marker",
    "path": tmp / "src"})
  check("grep without workspace keeps absolute display",
    unchanged{"text"}.getStr("").contains(tmp / "src/paths.txt" & ":2:"), $unchanged)
  let outside = call(nc, "grep", "grep", %*{"pattern": "^path-marker",
    "path": tmp / "src", "__workspace": {"root": tmp / "sub"}})
  check("grep outside workspace keeps original paths",
    outside{"text"}.getStr("") == unchanged{"text"}.getStr(""), $outside)
  let relativeFiles = call(nc, "grep", "files", %*{"path": tmp / "src",
    "__workspace": {"root": tmp}})
  check("files displays workspace-relative paths",
    relativeFiles{"text"}.getStr("").contains("\nsrc/alpha.nim") and
    not relativeFiles{"text"}.getStr("").contains(tmp), $relativeFiles)
  let outsideFiles = call(nc, "grep", "files", %*{"path": tmp / "src",
    "__workspace": {"root": tmp / "sub"}})
  check("files outside workspace keeps original paths",
    outsideFiles{"text"}.getStr("").contains(tmp / "src/alpha.nim"), $outsideFiles)

  createSymlink(tmp / "src", tmp / "mirror")
  let mirrored = call(nc, "grep", "grep", %*{
    "pattern": "^path-marker", "path": tmp / "mirror",
    "__workspace": {"root": tmp}})
  check("grep shortens symlinked dispatch filenames without rewriting source",
        mirrored{"text"}.getStr().contains("\nsrc/paths.txt:2:" & source), $mirrored)
  let mirroredFiles = call(nc, "grep", "files", %*{
    "path": tmp / "mirror", "__workspace": {"root": tmp}})
  check("files shortens symlinked dispatch filenames",
        mirroredFiles{"text"}.getStr().contains("\nsrc/alpha.nim"), $mirroredFiles)

  # drain: component exits
  drain(nc)
  sleep(700)
  check("grep drains and exits", not gProc.running())

  report("GREP TEST")

main()
