## Config surface — the discoverable configuration protocol
## (docs/research/CONFIG-CONTRACT.md).
##
## Boots a real store plus the config component and a small OWNER component
## that declares a domain and keeps its own values. The contract under test is
## that config discovers and validates but never writes someone else's record:
##
## - a declaration is durable, so it is listable after the owner is gone;
## - values, defaults, revision and schema are reported together;
## - a secret is redacted on read and never echoes back;
## - read-only properties are refused by name;
## - an invalid patch is refused before it reaches the owner;
## - a stale expectRev is a normal conflict, not a lost update;
## - reset drops explicit values so defaults apply again;
## - a declaration this component cannot enforce is refused outright;
## - an owner that is not running is reported as unavailable, never as
##   "defaults apply".

import std/[json, os, osproc, strutils]
import natsnim
import helpers

const ownerSource = """
import std/[json, os]
import niffler/sdk

let comp = newComponent("cfgowner", "0.1.0")
const kind = "cfgowner-settings"
const id = "main"

proc load(): tuple[values: JsonNode, rev: int] =
  try:
    let item = comp.storeGet(kind, id)
    if item.value == nil: return (newJObject(), 0)
    (item.value{"values"}, item.rev)
  except CatchableError:
    # storeGet raises when the record does not exist yet: an unconfigured
    # domain is a normal empty state, not an error.
    (newJObject(), 0)

comp.tool(%*{"hidden": true}):
  proc owner_config(op: string, patch: JsonNode = nil,
                    properties: seq[string] = @[], expectRev: int = -2): JsonNode =
    ## The owner's own mutation path: it validates nothing about schema (that
    ## is config's job) but owns the store document and the compare-and-set.
    var (values, rev) = load()
    case op
    of "get":
      return %*{"ok": true, "values": values, "rev": rev}
    of "patch":
      if expectRev != -2 and expectRev != rev:
        return errResult("rev-conflict: revision " & $expectRev & " != " & $rev, "rev-conflict")
      for name, value in patch.pairs:
        values[name] = value
      let newRev = comp.storePut(kind, id, %*{"values": values}, rev)
      return %*{"ok": true, "rev": newRev}
    of "reset":
      # Empty property list means "every mutable value" — config does not
      # enumerate them for the owner, so the owner interprets empty itself.
      if properties.len == 0:
        values = newJObject()
      else:
        for name in properties:
          values.delete(name)
      let newRev = comp.storePut(kind, id, %*{"values": values}, rev)
      return %*{"ok": true, "rev": newRev}
    else:
      return errResult("unsupported op", "bad-request")

# Declare AFTER the bus is connected: a request before comp.run() has no
# connection to send it on. The idle seam is the documented place for work
# with no request to ride on, and it runs on the main thread after registration.
var declared = false
discard comp.onIdle(100) do (c: Component):
  if declared: return
  declared = true
  let decl = %*{
    "domain": "cfgowner.main", "version": 1, "owner": "cfgowner",
    "ownerTool": "owner_config", "title": "Owner settings",
    "description": "Fixture domain.",
    "kind": kind, "id": id, "application": "immediate",
    "schema": {"type": "object",
      "properties": {
        "greeting": {"type": "string", "default": "hello", "x-config": {"title": "Greeting"}},
        "retries": {"type": "integer", "minimum": 1, "maximum": 10,
                    "default": 3, "x-config": {"application": "next turn"}},
        "token": {"type": "string", "x-config": {"secret": true}},
        "uptime": {"type": "integer", "x-config": {"readOnly": true}}},
      "additionalProperties": false}}
  try:
    let r = c.requestOk("config", "config_declare", %*{"declaration": decl}, 10_000)
    if not r{"ok"}.getBool(false):
      stderr.writeLine("cfgowner: declare refused: " & $r)
  except CatchableError as e:
    stderr.writeLine("cfgowner: declare failed: " & e.msg)
    # Before the config component is reachable: retry on the next idle tick.
    declared = false

comp.run()
"""

proc writeOwner(root: string): string =
  let path = root / "cfgowner.nim"
  writeFile(path, ownerSource)
  path

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["store-sqlite", "config"]:
    if not fileExists(repo / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  let tmp = tempRoot("config")
  defer: removeDir(tmp)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let store = startComponent(repo / "var" / "bin" / "store-sqlite", url, root = tmp)
  defer: stopProcess(store)
  check("store registers", waitRegistered(nc, "store"))
  let cfg = startComponent(repo / "var" / "bin" / "config", url, root = tmp)
  defer: stopProcess(cfg)
  check("config registers", waitRegistered(nc, "config"))

  # --- nothing declared yet ------------------------------------------------
  let empty = call(nc, "config", "config_list", %*{})
  check("an undeclared surface lists nothing", empty{"ok"}.getBool(false) and
        empty{"count"}.getInt(-1) == 0, $empty)

  # --- a declaration this surface cannot enforce is refused ----------------
  # A declaration without a timing is refused before anything else: "when does
  # this take effect" has no default, so an owner cannot inherit "immediate".
  let noTiming = call(nc, "config", "config_declare", %*{"declaration": {
    "domain": "bad.timing", "owner": "cfgowner", "kind": "x",
    "schema": {"type": "object"}}})
  check("a declaration without application is refused, not defaulted",
        noTiming{"code"}.getStr() == "bad-request" and
        noTiming{"error"}.getStr().contains("application is required"), $noTiming)
  let unsupported = call(nc, "config", "config_declare", %*{"declaration": {
    "domain": "bad.one", "owner": "cfgowner", "kind": "x", "application": "immediate",
    "schema": {"type": "object", "oneOf": []}}})
  check("an unenforceable schema keyword is refused, not ignored",
        unsupported{"code"}.getStr() == "bad-request" and
        unsupported{"error"}.getStr().contains("unsupported schema keyword"), $unsupported)
  let badScope = call(nc, "config", "config_declare", %*{"declaration": {
    "domain": "bad.two", "owner": "cfgowner", "kind": "x", "scope": "shared",
    "application": "immediate", "schema": {"type": "object"}}})
  check("shared scope is refused rather than silently instance-scoped",
        badScope{"code"}.getStr() == "bad-request", $badScope)

  # --- a real owner declares and serves its own values ---------------------
  let ownerBin = repo / "var" / "bin" / "cfgowner-fixture"
  let ownerSrc = writeOwner(tmp)
  let compiled = startComponent("/bin/sh", url, root = tmp, args = @[
    "-c", "nim c --hints:off --path:" & quoteShell(repo / "sdk") &
          " -o:" & quoteShell(ownerBin) & " " & quoteShell(ownerSrc) &
          " >/dev/null 2>&1"])
  check("owner fixture compiles", compiled.waitForExit(180_000) == 0)
  compiled.close()
  createDir(tmp / "logs")
  let ownerErr = tmp / "owner.err"
  var owner = startComponent("/bin/sh", url, root = tmp,
    args = @["-c", quoteShell(ownerBin) & " 2> " & quoteShell(ownerErr)],
    extra = [("CFGOWNER_DECLARE", "1")])
  defer: stopProcess(owner)
  check("owner registers", waitRegistered(nc, "cfgowner"))
  if failures > 0:
    echo "owner stderr follows; sandbox root ", tmp
    for f in walkDirRec(tmp):
      if f.endsWith(".nim"): continue
    report("CONFIG TEST")

  for i in 0 ..< 50:
    if call(nc, "config", "config_list", %*{}){"count"}.getInt(0) > 0: break
    sleep(100)
  if fileExists(ownerErr):
    let text = readFile(ownerErr)
    if text.strip().len > 0: echo "owner stderr: ", text.strip()
  let listed = call(nc, "config", "config_list", %*{})
  check("the declared domain is listed with its owner live",
        listed{"count"}.getInt(0) == 1 and
        listed{"domains"}[0]{"domain"}.getStr() == "cfgowner.main" and
        listed{"domains"}[0]{"ownerAvailable"}.getBool(false) and
        listed{"domains"}[0]{"properties"}.getInt(0) == 4 and
        listed{"domains"}[0]{"secrets"}.getInt(0) == 1, $listed)

  let got = call(nc, "config", "config_get", %*{"domain": "cfgowner.main"})
  check("values, defaults, revision and schema come back together",
        got{"ok"}.getBool(false) and got{"rev"}.getInt(0) == 0 and
        got{"defaults"}{"greeting"}.getStr() == "hello" and
        got{"schema"}{"properties"}{"retries"}{"maximum"}.getInt(0) == 10 and
        got{"schema"}{"properties"}{"retries"}{"x-config"}{"application"}.getStr() == "next turn",
        $got)

  # --- validation happens before the owner is touched ----------------------
  let badType = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"retries": "many"}})
  check("a wrong type is refused before the owner sees it",
        badType{"code"}.getStr() == "bad-request" and
        call(nc, "config", "config_get", %*{"domain": "cfgowner.main"}){"rev"}.getInt(-1) == 0,
        $badType)
  let outOfRange = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"retries": 99}})
  check("a bound is enforced", outOfRange{"code"}.getStr() == "bad-request", $outOfRange)
  let unknown = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"nope": 1}})
  check("an undeclared property is refused", unknown{"code"}.getStr() == "bad-request", $unknown)
  let readOnly = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"uptime": 5}})
  check("a read-only property is refused by name",
        readOnly{"error"}.getStr().contains("read-only"), $readOnly)

  # --- a valid patch, then a secret ---------------------------------------
  let patched = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"greeting": "hi", "retries": 5}})
  check("a valid patch is applied by the owner",
        patched{"ok"}.getBool(false) and patched{"rev"}.getInt(0) == 1, $patched)
  let withSecret = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"token": "s3cr3t"}, "expectRev": 1})
  check("a secret is written", withSecret{"ok"}.getBool(false), $withSecret)
  let afterSecret = call(nc, "config", "config_get", %*{"domain": "cfgowner.main"})
  check("a secret is redacted on read and never echoed",
        afterSecret{"values"}{"token"}{"set"}.getBool(false) and
        not ($afterSecret).contains("s3cr3t") and
        afterSecret{"values"}{"greeting"}.getStr() == "hi", $afterSecret)

  # --- stale revision is a conflict, not a lost update ---------------------
  let stale = call(nc, "config", "config_patch", %*{
    "domain": "cfgowner.main", "patch": {"greeting": "clobbered"}, "expectRev": 1})
  check("a stale expectRev is refused",
        stale{"code"}.getStr() == "owner-refused" and
        stale{"error"}.getStr().contains("rev-conflict"), $stale)
  check("the refused write left the value alone",
        call(nc, "config", "config_get", %*{"domain": "cfgowner.main"}){"values"}{"greeting"}.getStr() == "hi")

  # --- reset returns to defaults -----------------------------------------
  let reset = call(nc, "config", "config_reset", %*{"domain": "cfgowner.main"})
  check("reset drops explicit values", reset{"ok"}.getBool(false), $reset)
  let afterReset = call(nc, "config", "config_get", %*{"domain": "cfgowner.main"})
  check("defaults apply again after reset",
        afterReset{"values"}{"greeting"} == nil and
        afterReset{"defaults"}{"greeting"}.getStr() == "hello", $afterReset)

  # --- owner gone: durable declaration, unknown values --------------------
  stopProcess(owner)
  var unavailable = newJNull()
  for i in 0 ..< 50:
    unavailable = call(nc, "config", "config_get", %*{"domain": "cfgowner.main"})
    if unavailable{"code"}.getStr() == "owner-unavailable": break
    sleep(100)
  check("an absent owner is reported, not replaced by defaults",
        unavailable{"code"}.getStr() == "owner-unavailable", $unavailable)
  let listedAfter = call(nc, "config", "config_list", %*{})
  var survived = false
  if listedAfter{"domains"} != nil and listedAfter{"domains"}.len > 0:
    survived = listedAfter{"domains"}[0]{"ownerAvailable"}.getBool(true) == false
  check("the declaration survives its owner", survived, $listedAfter)

  report("CONFIG TEST")

main()
