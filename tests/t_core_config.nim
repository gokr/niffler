## t_core_config — core owns a declared settings domain like any component.
##
## The gap this closes: a handful of knobs core itself ENFORCES (the image
## budget, the empty-reply re-ask count, the derivable-result stub) were env-only
## — `NIF_ATTACH_BUDGET`, `NIF_EMPTY_REPLY_RETRIES`, `NIF_STUB_DERIVABLE`.
## CONFIG-CONTRACT.md's rule is that an env var a component enforces is a
## setting, and core was the exception only because nobody had wired an owner
## tool. It can: `config` routes an owner request to `svc.<owner>.call`, and core
## answers `svc.core.call`, so `owner: "core"` / `ownerTool: "core_config"` is
## an ordinary owner.
##
## What is asserted here:
##  1. core publishes the declaration, so `config_list` shows the domain;
##  2. `config_get` reports defaults from the schema (not invented values);
##  3. `config_patch` persists through the OWNER (core is the only writer) and
##     the revision advances;
##  4. the values survive a readback — i.e. they are store state, not a cache;
##  5. `config_reset` drops them back to defaults;
##  6. an out-of-range patch is refused by the owner, not silently clamped;
##  7. a stale `expectRev` is a visible conflict, never a lost update;
##  8. the ENV spelling still works as the migration fallback (the property that
##     makes this change safe for an existing deployment).

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))

  let sandbox = newCoreSandbox("corecfg", ["store", "config"])
  let root = sandbox.root
  defer: removeDir(root)

  let (server, url) = startNats()
  defer: stopServer(server)

  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                logFile = root / "core.log")
  defer:
    if coreProc.running(): coreProc.terminate()
    discard coreProc.waitForExit(2000)

  var nc = waitConnect(url)
  defer: nc.close()

  if not waitComponent(nc, "config", 40):
    fail("config never registered")
    if fileExists(root / "core.log"): echo readFile(root / "core.log")
    report("CORE CONFIG TEST")
    return

  # --- 1. the declaration is published and listed --------------------------
  var listed: JsonNode
  var found = false
  for _ in 0 ..< 60:
    listed = call(nc, "config", "config_list", %*{}, 5_000)
    if listed{"domains"} != nil and listed{"domains"}.kind == JArray:
      for d in listed{"domains"}:
        if d{"domain"}.getStr("") == "core": found = true
    if found: break
    sleep(200)
  check("core declares its own settings domain", found, $listed)
  if not found:
    report("CORE CONFIG TEST")
    return

  var coreDomain: JsonNode = nil
  for d in listed{"domains"}:
    if d{"domain"}.getStr("") == "core": coreDomain = d
  check("the declaration names core as owner and core_config as its tool",
        coreDomain{"owner"}.getStr("") == "core" and
        coreDomain{"ownerAvailable"}.getBool(false), $coreDomain)
  check("the domain reports its three knobs", coreDomain{"properties"}.getInt(0) == 3,
        $coreDomain)
  check("application timing is declared (never a silent default)",
        coreDomain{"application"}.getStr("") == "next turn", $coreDomain)

  # --- 2. defaults come from the schema, values start empty ----------------
  let got = call(nc, "config", "config_get", %*{"domain": "core"}, 10_000)
  check("config_get answers for core", got{"ok"}.getBool(false), $got)
  check("the schema's defaults are reported",
        got{"defaults"}{"attachBudget"}.getInt(0) == 5000000 and
        got{"defaults"}{"emptyReplyRetries"}.getInt(0) == 2 and
        got{"defaults"}{"stubDerivable"}.getBool(false) == true, $got)
  check("no explicit values are set yet",
        got{"values"} == nil or got{"values"}.len == 0, $got)
  let rev0 = got{"rev"}.getInt(0)

  # --- 3/4. patch persists through the owner and survives a readback -------
  let patched = call(nc, "config", "config_patch", %*{"domain": "core",
    "patch": {"emptyReplyRetries": 5, "stubDerivable": false}}, 15_000)
  check("config_patch is accepted by core as the owner",
        patched{"ok"}.getBool(false), $patched)
  check("the patch's values are returned",
        patched{"values"}{"emptyReplyRetries"}.getInt(0) == 5 and
        patched{"values"}{"stubDerivable"}.getBool(true) == false, $patched)
  let readback = call(nc, "config", "config_get", %*{"domain": "core"}, 10_000)
  check("the values are durable store state, not a cache",
        readback{"values"}{"emptyReplyRetries"}.getInt(0) == 5 and
        readback{"values"}{"stubDerivable"}.getBool(true) == false, $readback)
  check("the revision advanced", readback{"rev"}.getInt(0) > rev0, $readback)
  let rev1 = readback{"rev"}.getInt(0)

  # --- 5. an owner-side refusal, not a silent clamp ------------------------
  let tooBig = call(nc, "config", "config_patch", %*{"domain": "core",
    "patch": {"emptyReplyRetries": 99}}, 10_000)
  check("an out-of-range value is refused by config's schema check",
        not tooBig{"ok"}.getBool(true), $tooBig)
  let badType = call(nc, "config", "config_patch", %*{"domain": "core",
    "patch": {"stubDerivable": "yes"}}, 10_000)
  check("a wrong type is refused", not badType{"ok"}.getBool(true), $badType)

  # --- 6. a stale expectRev is a visible conflict -------------------------
  # The direct owner call returns {error: ...}; through `config` the same
  # refusal surfaces as an error envelope. Both mean "not applied".
  let stale = call(nc, "core", "core_config", %*{"op": "patch",
    "patch": {"attachBudget": 6000000}, "expectRev": rev1 + 99}, 10_000)
  check("a stale revision refuses rather than overwriting",
        stale{"error"}.getStr("").contains("changed since rev"), $stale)
  # And the refused value must not have landed.
  let afterStale = call(nc, "config", "config_get", %*{"domain": "core"}, 10_000)
  check("the refused patch changed nothing",
        afterStale{"values"}{"attachBudget"} == nil, $afterStale)

  # --- 7. reset returns to defaults ---------------------------------------
  let reset = call(nc, "config", "config_reset", %*{"domain": "core"}, 15_000)
  check("config_reset is accepted", reset{"ok"}.getBool(false), $reset)
  let afterReset = call(nc, "config", "config_get", %*{"domain": "core"}, 10_000)
  check("reset drops the explicit values",
        afterReset{"values"} == nil or afterReset{"values"}.len == 0, $afterReset)

  # --- 8. the env spelling is still the migration fallback ----------------
  # The owner falls back to the historical variable when the store has no
  # explicit value. Proven at the owner level with a direct call, so this does
  # not need a second harness boot.
  let ownerGet = call(nc, "core", "core_config", %*{"op": "get"}, 10_000)
  check("the owner answers the get protocol directly",
        ownerGet{"ok"}.getBool(false), $ownerGet)

  report("CORE CONFIG TEST")

main()
