## lsp component tests — bus contract: registration, registry data flow, and
## every operation against a deterministic fixture language server (Python,
## tests/fixtures/lsp_server.py) speaking real LSP framing over stdio.
##
## Covers: default+user registry merge; E_LSP_UNAVAILABLE (unconfigured
## extension, binary missing, server dies); E_LSP_UNSUPPORTED (capability
## absent); the one-based(model) → zero-based(wire) position conversion
## (the fixture echoes the received position); findReferences always
## sending includeDeclaration; diagnostics push + settle (two pushes collapse
## to the last); clean-file diagnostics; instance reuse (a second query must
## not re-initialize); server→client request answered; path scope refusals;
## lsp_registry add/remove (agent-editable registry — a new language with
## zero code changes, live on the next call).

import std/[json, os, osproc, sequtils, strutils]
import natsnim
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "lsp"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("lsp")
  defer: removeDir(tmp)

  # fixture language server for the invented ".nx" extension (never collides
  # with real servers), plus deliberately broken entries
  let fixture = root / "tests" / "fixtures" / "lsp_server.py"
  let regFile = tmp / "lsp-registry.json"
  let fixtureLog = tmp / "fixture.log"
  writeFile(regFile, (%*{
    "nx": {"command": ["python3", fixture], "extensions": %*{".nx": "nx"}},
    "gone": {"command": ["definitely-not-a-binary-xyz"], "extensions": %*{".gone": "gone"}},
    "exiter": {"command": ["true"], "extensions": %*{".exit": "exit"}}
  }).pretty())

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let lspProc = startComponent(bin, url, root = tmp,
                               extra = [("NIF_LSP_REGISTRY", regFile),
                                        ("LSP_FIXTURE_LOG", fixtureLog)])
  defer:
    if lspProc.running():
      lspProc.terminate()
      sleep(200)
    lspProc.close()
  check("lsp registers", waitRegistered(nc, "lsp"), "reg.publish")

  proc lspCall(args: JsonNode, timeoutMs = 30000): JsonNode =
    call(nc, "lsp", "lsp", args, timeoutMs)

  proc regCall(args: JsonNode): JsonNode =
    call(nc, "lsp", "lsp_registry", args, 10000)

  proc listCall(): JsonNode =
    call(nc, "lsp", "lsp_servers", %*{}, 10000)

  # --- shape + scope + missing file refusals -----------------------------
  let bad = lspCall(%*{"operation": "teleport", "path": "x.nx"})
  check("unknown operation refused", bad.hasKey("error") and
        bad{"error"}.getStr("").contains("E_BAD_SHAPE"), $bad)
  let noLine = lspCall(%*{"operation": "hover", "path": "a.nx"})
  check("hover without position refused", noLine.hasKey("error") and
        noLine{"error"}.getStr("").contains("E_BAD_SHAPE"), $noLine)
  let missing = lspCall(%*{"operation": "hover", "path": "nope.nx", "line": 1, "character": 1})
  check("missing file refused", missing.hasKey("error") and
        missing{"error"}.getStr("").contains("E_NOT_FOUND"), $missing)

  let escape = lspCall(%*{"operation": "hover", "path": "../hidden.nx",
                           "line": 1, "character": 1})
  check("'..' components refused (scope)", escape.hasKey("error") and
        escape{"error"}.getStr("").contains("E_LSP_SCOPE"), $escape)
  let outside = lspCall(%*{"operation": "hover", "path": "/etc/hostname",
                           "line": 1, "character": 1})
  check("absolute paths outside the workspace refused", outside.hasKey("error") and
        outside{"error"}.getStr("").contains("E_LSP_SCOPE"), $outside)

  # --- registry-driven unavailability ------------------------------------
  writeFile(tmp / "mystery.zzz", "what am i\n")
  let unconf = lspCall(%*{"operation": "hover", "path": "mystery.zzz",
                          "line": 1, "character": 1})
  check("unconfigured extension names the fix", unconf.hasKey("error") and
        unconf{"error"}.getStr("").contains("E_LSP_UNAVAILABLE") and
        unconf{"error"}.getStr("").contains(".zzz") and
        unconf{"error"}.getStr("").contains("lsp_registry"), $unconf)
  writeFile(tmp / "gone.gone", "ghost\n")
  let nobin = lspCall(%*{"operation": "hover", "path": "gone.gone",
                         "line": 1, "character": 1})
  check("missing binary reported clearly", nobin.hasKey("error") and
        nobin{"error"}.getStr("").contains("E_LSP_UNAVAILABLE") and
        nobin{"error"}.getStr("").contains("not found on PATH"), $nobin)
  writeFile(tmp / "boom.exit", "exit\n")
  let dies = lspCall(%*{"operation": "hover", "path": "boom.exit",
                        "line": 1, "character": 1})
  check("server that dies immediately is a protocol error", dies.hasKey("error") and
        (dies{"error"}.getStr("").contains("E_LSP_PROTOCOL") or
         dies{"error"}.getStr("").contains("E_LSP_TIMEOUT")), $dies)

  # --- hover: position conversion (fixture echoes the zero-based wire pos)
  writeFile(tmp / "main.nx", "let wobble = 1\nfn main() {}\n")
  let hv = lspCall(%*{"operation": "hover", "path": "main.nx", "line": 2, "character": 3})
  check("hover converts one-based to zero-based",
        hv{"ok"}.getBool(false) and
        hv{"text"}.getStr("") == "hover at line 1 char 2", $hv)
  let hv2 = lspCall(%*{"operation": "hover", "path": "main.nx", "line": 1, "character": 1})
  check("second hover reuses the instance",
        hv2{"ok"}.getBool(false) and
        hv2{"text"}.getStr("") == "hover at line 0 char 0", $hv2)
  let inits = if fileExists(fixtureLog):
                readFile(fixtureLog).splitLines().filterIt(it.len > 0).len
              else: 0
  check("exactly one initialize for two queries", inits == 1, $inits)

  # --- definition: Location normalization + one-based rendering ----------
  let def = lspCall(%*{"operation": "goToDefinition", "path": "main.nx",
                       "line": 1, "character": 1})
  check("definition renders one-based relative path",
        def{"ok"}.getBool(false) and
        def{"text"}.getStr("") == "sibling.nx:5:3" and
        def{"count"}.getInt(0) == 1, $def)

  # --- references: includeDeclaration always sent -------------------------
  let refs = lspCall(%*{"operation": "findReferences", "path": "main.nx",
                        "line": 1, "character": 1})
  check("findReferences includes the declaration",
        refs{"ok"}.getBool(false) and refs{"count"}.getInt(0) == 2, $refs)

  # --- capability refusal --------------------------------------------------
  let impl = lspCall(%*{"operation": "goToImplementation", "path": "main.nx",
                        "line": 1, "character": 1})
  check("unadvertised capability refused", impl.hasKey("error") and
        impl{"error"}.getStr("").contains("E_LSP_UNSUPPORTED") and
        impl{"error"}.getStr("").contains("implementationProvider"), $impl)

  # --- diagnostics: push + settle, then the clean path --------------------
  writeFile(tmp / "wobbly.nx", "fn wobble() {}\n")
  let diag = lspCall(%*{"operation": "diagnostics", "path": "wobbly.nx"})
  check("diagnostics renders the settled push",
        diag{"ok"}.getBool(false) and diag{"count"}.getInt(0) == 1 and
        diag{"errors"}.getInt(0) == 1 and
        diag{"text"}.getStr("").contains(
          "wobbly.nx:3:5  error  undefined: wobble (nx-check) [E1027]"), $diag)
  writeFile(tmp / "clean.nx", "all good\n")
  let diag2 = lspCall(%*{"operation": "diagnostics", "path": "clean.nx"})
  check("clean file reported clean", diag2{"ok"}.getBool(false) and
        diag2{"text"}.getStr("").contains("no diagnostics — clean"), $diag2)

  # --- workspace resolution: absolute path inside the root -----------------
  let abs = lspCall(%*{"operation": "hover", "path": tmp / "main.nx",
                       "line": 2, "character": 3})
  check("absolute path inside the workspace works",
        abs{"ok"}.getBool(false), $abs)

  # --- registry: list / add / remove ---------------------------------------
  let listed = listCall()
  check("registry lists defaults + user entries with source",
        listed{"ok"}.getBool(false) and
        listed{"servers"} != nil and listed{"servers"}.len >= 9 and
        listed{"path"}.getStr("").len > 0 and
        (block:
          var sawUser, sawBuiltin = false
          for s in listed{"servers"}:
            if s{"name"}.getStr("") == "nx" and s{"source"}.getStr("") == "user":
              sawUser = true
            if s{"name"}.getStr("") == "gopls" and s{"source"}.getStr("") == "builtin":
              sawBuiltin = true
          sawUser and sawBuiltin),
        $listed)
  let conflict = regCall(%*{"action": "add", "name": "other",
                            "command": "whatever", "extensions": %*{".nx": "nx2"}})
  check("extension conflict refused", conflict.hasKey("error") and
        conflict{"error"}.getStr("").contains("E_LSP_CONFLICT"), $conflict)
  let added = regCall(%*{"name": "echo-nx",
                         "command": ["python3", fixture],
                         "extensions": %*{".ezz": "ezz"}})
  check("add writes the user registry", added{"ok"}.getBool(false) and
        fileExists(regFile) and readFile(regFile).contains("echo-nx"), $added)
  # the added server serves the new extension immediately — no restart
  writeFile(tmp / "fresh.ezz", "hi\n")
  let viaNew = lspCall(%*{"operation": "hover", "path": "fresh.ezz",
                          "line": 1, "character": 1})
  check("new registry entry works on the next call",
        viaNew{"ok"}.getBool(false) and
        viaNew{"text"}.getStr("") == "hover at line 0 char 0", $viaNew)
  let removed = regCall(%*{"action": "remove", "name": "echo-nx"})
  check("remove deletes the user entry", removed{"ok"}.getBool(false) and
        not readFile(regFile).contains("echo-nx"), $removed)
  let rmDef = regCall(%*{"action": "remove", "name": "gopls"})
  check("removing a built-in is refused", rmDef.hasKey("error"), $rmDef)

  report("LSP TEST")

main()
