## edit/lsp latency contract: a mutation must never wait for the language
## server. The lsp component is single-threaded and runs its asynchronous
## diagnostics check in the same pump that answers the NEXT request, so its
## ack can be seconds away — the edit's ack budget is deliberately short and
## there is no second lookup on the slow path (tests/fixtures/slow_lsp.nim
## stands in for that busy pump: it answers nothing for 4s).
##
## What this pins: the file write is already done when the ack is late, the
## call returns promptly anyway, and the model is told the verdict is coming
## rather than being left to guess. A regression here is not cosmetic — the
## edit component's own pump is serialized, so one waiting mutation stalls
## every other session's mutation behind it (measured: 39s in the full31 run).

import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let editBin = root / "var" / "bin" / "edit"
  let lspBin = root / "var" / "bin" / "fixture-slow-lsp"
  for b in [editBin, lspBin]:
    if not fileExists(b):
      fail(b & " missing — run `make build` first")
      quit(1)
  let tmp = tempRoot("edit-lsp-slow")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let lspProc = startComponent(lspBin, url, root = tmp,
                               extra = [("SLOW_LSP_MS", "4000")])
  defer:
    if lspProc.running():
      lspProc.terminate()
      sleep(200)
    lspProc.close()
  doAssert waitRegistered(nc, "lsp"), "slow lsp fixture did not register"

  let eProc = startComponent(editBin, url, root = tmp,
                             extra = [("XDG_CONFIG_HOME", tmp / "config")])
  defer:
    if eProc.running():
      eProc.terminate()
      sleep(200)
    eProc.close()
  doAssert waitRegistered(nc, "edit"), "edit did not register"

  writeFile(tmp / "slow.go", "package p\n\nfunc Old() {}\n")
  writeFile(tmp / "bulk.go", "package p\n\nfunc Bulk() {}\n")

  proc elapsedOf(body: proc(): JsonNode): tuple[seconds: float, res: JsonNode] =
    let t0 = epochTime()
    result.res = body()
    result.seconds = epochTime() - t0

  # First mutation: the fixture is idle, so this one may get a real ack —
  # which itself blocks the fixture's pump for SLOW_LSP_MS.
  let first = elapsedOf(proc(): JsonNode =
    call(nc, "edit", "edit",
         %*{"path": "slow.go",
            "edits": [{"old_string": "func Old() {}", "new_string": "func New() {}"}],
            "__session": {"session": "slow-1"}}, 60_000))
  check("a mutation whose lsp ack is slow still returns promptly",
        first.seconds < 2.0, "took " & formatFloat(first.seconds, ffDecimal, 2) & "s")
  check("the file was written regardless of the lsp answer",
        readFile(tmp / "slow.go") == "package p\n\nfunc New() {}\n",
        readFile(tmp / "slow.go"))

  # Second mutation: the fixture's pump is now busy for the rest of its sleep,
  # so the ack cannot arrive inside the budget. The edit must not care.
  let second = elapsedOf(proc(): JsonNode =
    call(nc, "edit", "replace_across",
         %*{"glob": "bulk.go",
            "replace": [{"old": "func Bulk() {}", "new": "func Bulk2() {}"}],
            "__session": {"session": "slow-2"}}, 60_000))
  check("bulk mutation behind a busy lsp pump returns promptly too",
        second.seconds < 2.0, "took " & formatFloat(second.seconds, ffDecimal, 2) & "s")
  check("the bulk write landed", readFile(tmp / "bulk.go") ==
        "package p\n\nfunc Bulk2() {}\n", readFile(tmp / "bulk.go"))
  let note = second.res{"text"}.getStr("")
  check("the late ack is reported as queued, not as a failure",
        note.contains("diagnostics queued"), $second.res)

  # No session: the edit never talks to lsp at all.
  writeFile(tmp / "bare.go", "package p\n\nfunc Bare() {}\n")
  let bare = elapsedOf(proc(): JsonNode =
    call(nc, "edit", "edit",
         %*{"path": "bare.go",
            "edits": [{"old_string": "func Bare() {}", "new_string": "func Bare2() {}"}]},
         60_000))
  check("a sessionless mutation never waits for lsp",
        bare.seconds < 2.0 and not bare.res{"text"}.getStr("").contains("[lsp:"),
        $bare.res)

  report("EDIT-LSP-SLOW TEST")

main()
