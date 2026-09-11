## tool profiles + sticky invoke tests — profile CRUD and resolution,
## frozen exposure snapshots, sticky promotion of discovered tools into
## the direct toolset, and the direct-token cap.

import std/[json, os, strutils, times]
when defined(nifflerNimNats):
  # Pure-Nim client (github.com/gokr/natsnim), aliased to `natswrapper` so every
  # call site below stays byte-identical. Enabled with
  #   make build NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
  # See docs/research/NATSNIM.md.
  import natsnim as natswrapper
else:
  import natswrapper
import helpers

proc names(nodes: JsonNode, nested = false): seq[string] =
  if nodes == nil or nodes.kind != JArray:
    return
  for node in nodes:
    let name = if node.kind == JString: node.getStr()
               elif nested: node{"function"}{"name"}.getStr("")
               else: node{"name"}.getStr("")
    if name.len > 0:
      result.add(name)

proc directNames(nc: NatsConnection, sessionId: string): seq[string] =
  let doc = call(nc, "store", "get",
                 %*{"kind": "session", "id": sessionId & ":tools"})
  if doc{"ok"}.getBool(false):
    result = names(doc{"value"}{"direct"})

proc waitForComponent(nc: NatsConnection, name: string,
                      timeoutMs = 15_000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    let snapshot = call(nc, "core", "catalog", %*{"op": "snapshot"}, 3_000)
    if snapshot{"components"} != nil:
      for item in snapshot{"components"}:
        if item{"name"}.getStr("") == name:
          return true
    sleep(100)

const fixtureSource = """
  import std/os
  import niffler/sdk

  let comp = newComponent("profile-fixture", "0.1.0")

  comp.tool:
    proc fixture_direct(value: string = ""): JsonNode =
      ## Echo through a directly exposed fixture tool.
      ## - value: value to echo
      %*{"value": value, "via": "direct"}

  comp.tool(%*{"onDemand": true}):
    proc fixture_demand_alpha(value: string): JsonNode =
      ## Echo through an on-demand fixture tool.
      ## - value: value to echo
      %*{"value": value, "via": "invoke"}

  comp.tool(%*{"onDemand": true, "approval": "always"}):
    proc fixture_needs_approval(): JsonNode =
      ## Approval-gated on-demand fixture tool.
      %*{"called": true}

  comp.tool(%*{"hidden": true, "onDemand": true}):
    proc fixture_hidden_needle(): JsonNode =
      ## HIDDEN_SENTINEL must never enter a direct toolset.
      %*{"hidden": true}

  comp.tool(%*{"hidden": true, "timeoutMs": 300000}):
    proc chat(messages: JsonNode, tools: JsonNode,
              sessionId: string, stream: bool): JsonNode =
      ## Scripted LLM: round 1 invokes sticky, round 2 calls the promoted
      ## tool directly, final round reports whether the tool was visible
      ## in the request's tools array.
      let last = messages[messages.len - 1]
      if last{"role"}.getStr("") == "user" and
          last{"content"}.getStr("") == "go-sticky":
        let arguments = $(%*{"tool": "fixture_demand_alpha",
                             "arguments": {"value": "a"}, "sticky": true})
        return %*{"content": "", "reasoning": "sticky invoke",
                  "tool_calls": [{
            "id": "profile-invoke", "type": "function",
            "function": {"name": "invoke", "arguments": arguments}}]}
      if last{"role"}.getStr("") == "tool" and
          last{"name"}.getStr("") == "invoke":
        let arguments = $(%*{"value": "b"})
        return %*{"content": "", "reasoning": "direct after promotion",
                  "tool_calls": [{
            "id": "profile-direct", "type": "function",
            "function": {"name": "fixture_demand_alpha",
                         "arguments": arguments}}]}
      var visible = "absent"
      if tools != nil:
        for t in tools:
          if t{"function"}{"name"}.getStr("") == "fixture_demand_alpha":
            visible = "in-array"
      return %*{"content": "sticky:" & visible}

  comp.run()
  """.dedent()

proc buildFixture(nc: NatsConnection): string =
  let built = call(nc, "builder", "build",
                   %*{"lang": "nim", "name": "profile-fixture",
                      "source": fixtureSource}, 300_000)
  check("builder builds profile fixture", built{"ok"}.getBool(false), $built)
  if not built{"ok"}.getBool(false):
    report("PROFILE TEST")
  return built{"binary"}.getStr("")

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for binary in ["niffler", "session", "store", "builder"]:
    if not fileExists(repoRoot / "var" / "bin" / binary):
      fail("missing " & binary & " binary — run `make build` first")
  if failures > 0:
    report("PROFILE TEST")

  # --- sandbox A: sticky under a 1-token cap must defer, not promote ------
  block:
    let sandbox = newCoreSandbox("profile-cap", ["store", "builder"])
    let root = sandbox.root
    defer: removeDir(root)
    let (server, url) = startNats()
    defer: stopServer(server)
    var nc = waitConnect(url)
    defer: nc.close()
    let coreProcess = startComponent(sandbox.sandboxBin("niffler"), url,
                                     root = root,
                                     extra = [("NIF_AUTO_APPROVE", "0"),
                                              ("NIF_MAX_DIRECT_TOKENS", "1")])
    defer: stopProcess(coreProcess, 1500)
    check("builder up", waitForComponent(nc, "builder"))

    let bin = buildFixture(nc)
    let fixtureProcess = startComponent(bin, url, root)
    defer: stopProcess(fixtureProcess)
    check("fixture registered", waitForComponent(nc, "profile-fixture"))

    discard call(nc, "core", "profile",
                 %*{"op": "save", "name": "cap",
                    "tools": []})
    let turn = call(nc, "core", "session",
                    %*{"sessionId": "cap-conv", "content": "go-sticky",
                       "profile": "cap"}, 120_000)
    check("sticky under a tiny cap still completes the turn",
          turn{"reply"}.getStr("") == "sticky:absent", $turn)
    check("cap defers promotion: direct set unchanged",
          "fixture_demand_alpha" notin directNames(nc, "cap-conv"))

  # --- sandbox B: resolution, freeze, promotion, errors --------------------
  block:
    let sandbox = newCoreSandbox("profile", ["store", "builder"])
    let root = sandbox.root
    defer: removeDir(root)
    let (server, url) = startNats()
    defer: stopServer(server)
    var nc = waitConnect(url)
    defer: nc.close()
    let coreProcess = startComponent(sandbox.sandboxBin("niffler"), url,
                                     root = root,
                                     extra = [("NIF_AUTO_APPROVE", "0")])
    defer: stopProcess(coreProcess, 1500)
    check("builder up", waitForComponent(nc, "builder"))

    let bin = buildFixture(nc)
    let fixtureProcess = startComponent(bin, url, root)
    defer: stopProcess(fixtureProcess)
    check("fixture registered", waitForComponent(nc, "profile-fixture"))

    # CRUD + resolution
    let saved = call(nc, "core", "profile",
                     %*{"op": "save", "name": "dev",
                        "tools": ["profile-fixture", "-fixture_needs_approval",
                                  "ghost_tool"],
                        "note": "test profile"})
    check("profile save succeeds", saved{"ok"}.getBool(false), $saved)
    let got = call(nc, "core", "profile",
                   %*{"op": "get", "name": "dev"})
    let resolved = names(got{"resolved"})
    check("profile resolves base + component selector",
          resolved.contains("fixture_direct") and
          resolved.contains("fixture_demand_alpha") and
          resolved.contains("discover") and resolved.contains("invoke"),
          $got)
    check("excluded selector is not resolved",
          "fixture_needs_approval" notin resolved, $got)
    check("unknown selector reported missing",
          got{"missing"} != nil and got{"missing"}.len == 1 and
          got{"missing"}[0].getStr("") == "ghost_tool", $got)
    check("estTokens is a positive estimate",
          got{"estTokens"}.getInt(0) > 0, $got)

    # hidden tools are never promotable, even by exact-name selector
    discard call(nc, "core", "profile",
                 %*{"op": "save", "name": "sneaky",
                    "tools": ["fixture_hidden_needle"]})
    let sneaky = call(nc, "core", "profile",
                      %*{"op": "get", "name": "sneaky"})
    check("hidden tool is not resolved (reported missing, no oracle)",
          "fixture_hidden_needle" notin names(sneaky{"resolved"}) and
          sneaky{"missing"}.len == 1, $sneaky)

    # Use a base-only profile so sticky must actually promote the tool.
    discard call(nc, "core", "profile",
                 %*{"op": "save", "name": "dev", "tools": ["ghost_tool"]})
    let turn = call(nc, "core", "session",
                    %*{"sessionId": "profile-conv", "content": "go-sticky",
                       "profile": "dev"}, 120_000)
    check("sticky round-2 call is LLM-visible in the tools array",
          turn{"reply"}.getStr("") == "sticky:in-array", $turn)
    check("sticky invoke promoted the tool into the direct set",
          "fixture_demand_alpha" in directNames(nc, "profile-conv"))
    let exposure = call(nc, "store", "get",
                        %*{"kind": "session",
                           "id": "profile-conv:tools"})
    check("exposure doc records profile name and missing selectors",
          exposure{"value"}{"profile"}.getStr("") == "dev" and
          exposure{"value"}{"profileMissing"} != nil and
          exposure{"value"}{"profileMissing"}.len == 1 and
          exposure{"value"}{"profileMissing"}[0].getStr("") == "ghost_tool",
          $exposure)

    # profiles are frozen at first build: editing one cannot rewrite a
    # running conversation's prefix
    discard call(nc, "core", "profile",
                 %*{"op": "save", "name": "dev", "tools": []})
    let frozen = directNames(nc, "profile-conv")
    let resume = call(nc, "core", "session",
                      %*{"sessionId": "profile-conv", "content": "ping",
                         "profile": "dev"}, 120_000)
    check("resume keeps the frozen direct set (profile edit is inert)",
          directNames(nc, "profile-conv") == frozen and
          "fixture_demand_alpha" in frozen and
          resume{"reply"}.getStr("") == "sticky:in-array", $resume)

    # explicit selection fails loudly on an unknown profile
    let missing = call(nc, "core", "session",
                       %*{"sessionId": "profile-nx", "content": "ping",
                          "profile": "nope"}, 60_000)
    check("unknown profile fails the call instead of falling back",
          missing{"error"}.getStr("").contains("not found"), $missing)

    # list surface carries the picker data
    let listing = call(nc, "core", "profile", %*{"op": "list"})
    check("profile list reports saved profiles",
          listing{"profiles"} != nil and listing{"profiles"}.len == 2, $listing)

  report("PROFILE TEST")

main()
