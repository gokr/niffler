## progressive discovery tests — prompt projection, schemas, invoke policy,
## fixed per-session toolsets, and durable exposure metadata.

import std/[json, os, strutils, tables, times]
import ../core/catalog
import natsnim
import helpers

proc names(nodes: JsonNode, nested = false): seq[string] =
  if nodes == nil or nodes.kind != JArray:
    return
  for node in nodes:
    let name = if nested: node{"function"}{"name"}.getStr("")
               else: node{"name"}.getStr("")
    if name.len > 0:
      result.add(name)

proc isSorted(items: seq[string]): bool =
  for i in 1 ..< items.len:
    if items[i - 1] > items[i]:
      return false
  return true

proc component(snapshot: JsonNode, name: string): JsonNode =
  let components = snapshot{"components"}
  if components == nil or components.kind != JArray:
    return nil
  for item in components:
    if item{"name"}.getStr("") == name:
      return item

proc tool(tools: JsonNode, name: string): JsonNode =
  if tools == nil or tools.kind != JArray:
    return nil
  for item in tools:
    if item{"name"}.getStr("") == name:
      return item

proc waitForComponent(nc: NatsConnection, name: string,
                      timeoutMs = 15_000): JsonNode =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    let snapshot = call(nc, "core", "catalog", %*{"op": "snapshot"}, 3_000)
    let found = component(snapshot, name)
    if found != nil:
      return found
    sleep(100)

proc discoveryUnitChecks() =
  ## Pure catalog checks: no bus, binaries, or shared build generation.
  let cat = Catalog(components: initTable[string, ComponentReg](),
                    toolIndex: initTable[string, string]())
  check("empty capability registry", cat.discover(%*{}) ==
        %*{"components": [], "count": 0})
  for i in 0 ..< 300:
    let name = "session-" & $i
    cat.components[name] = ComponentReg(name: name)
  cat.components["hidden-only"] = ComponentReg(name: "hidden-only", tools: @[
    ToolReg(name: "secret", schema: %*{"description": "SECRET_SENTINEL",
      "x-harness": {"hidden": true}})])
  cat.toolIndex["secret"] = "hidden-only"
  check("zero-visible components omitted, admin inventory retained",
        cat.discover(%*{}) == %*{"components": [], "count": 0} and
        cat.sortedComponentNames().len == 301)
  check("global hidden and unknown lookups equivalent",
        cat.discover(%*{"tools": ["secret"]}) ==
        cat.discover(%*{"tools": ["unknown"]}))
  for i in 0 ..< 120:
    let owner = "capability-" & align($i, 3, '0')
    var reg = ComponentReg(name: owner, version: "0.1.0")
    for j in 0 ..< 3:
      let name = owner & "_" & $j
      reg.tools.add(ToolReg(name: name, component: owner, schema: %*{
        "type": "object", "description": "Mechanical jobs and fan-out",
        "x-harness": {"onDemand": true,
          "hint": if j == 2: "ROUTE_SENTINEL " & repeat("parallel routing ", 10)
                  else: ""}}))
      cat.toolIndex[name] = owner
    cat.components[owner] = reg
    if i == 23:
      let reduced = cat.discover(%*{})
      check("budget pressure reduces hints without losing routing",
            ($reduced).len <= 6000 and reduced["components"].len == 24)
      for entry in reduced["components"]:
        check("routing hint survives reduced density",
              entry{"hints"}.len >= 1 and
              entry["hints"][0]["hint"].getStr().contains("ROUTE_SENTINEL"))
  check("empty tools behaves like omitted tools",
        cat.discover(%*{"tools": []}) == cat.discover(%*{}) and
        cat.discover(%*{"component": "capability-000", "tools": []}) ==
        cat.discover(%*{"component": "capability-000"}))
  check("component limit honored", cat.discover(%*{
    "component": "capability-000", "limit": 1})["component"]["onDemand"].len == 1)
  let missed = cat.discover(%*{"query": "mechanical nonexistent"})
  check("empty word-AND search offers corrective hint",
        missed["count"].getInt() == 0 and
        missed["next"].getStr().contains("Every keyword must match") and
        missed["next"].getStr().contains("tools:[name]"))
  check("word-AND search ignores word order and case",
        cat.discover(%*{"query": "FAN-OUT mechanical"})["count"].getInt() == 120)
  var after = ""
  var seen: seq[string]
  var pages = 0
  while true:
    let args = %*{"after": after}
    let page = cat.discover(args)
    check("registry page deterministic and bounded",
          page == cat.discover(args) and ($page).len <= 6000)
    check("registry hides invisible names", not ($page).contains("secret") and
          not ($page).contains("session-") and not ($page).contains("SECRET_SENTINEL"))
    if page{"components"} == nil or page["components"].len == 0:
      fail("registry page made no progress")
      break
    inc pages
    for entry in page["components"]:
      let name = entry["name"].getStr()
      check("paged routing hint and metadata survive",
            entry{"hints"}.len >= 1 and
            entry["hints"][0]["hint"].getStr().contains("ROUTE_SENTINEL") and
            entry["tools"].getInt() == 3 and entry["version"].getStr() == "0.1.0")
      check("page ordering exclusive with no duplicates",
            name > after and name notin seen and
            (seen.len == 0 or name > seen[^1]))
      seen.add(name)
    if not page{"hasMore"}.getBool(false): break
    after = page["nextAfter"].getStr()
    check("cursor is last visible component", after == seen[^1])
    if pages > 120:
      fail("paging did not terminate")
      break
  check("paging visits every meaningful component", pages > 1 and seen.len == 120)
  check("exhausted cursor returns empty page",
        cat.discover(%*{"after": seen[^1]}) == %*{"components": [], "count": 0})

proc main() =
  discoveryUnitChecks()
  if getEnv("NIF_DISCOVER_UNIT_ONLY") == "1":
    report("DISCOVER UNIT TEST")
    return
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for binary in ["niffler", "session", "store-sqlite", "builder"]:
    if not fileExists(repoRoot / "var" / "bin" / binary):
      fail("missing " & binary & " binary — run `make build` first")
  if failures > 0:
    report("DISCOVER TEST")

  let sandbox = newCoreSandbox("discover", ["store", "builder"])
  let root = sandbox.root
  let coreBin = sandbox.sandboxBin("niffler")
  defer: removeDir(root)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProcess = startComponent(coreBin, url, root = root,
                                   extra = [("NIF_AUTO_APPROVE", "0")])
  defer: stopProcess(coreProcess, 1500)

  check("builder registered", waitForComponent(nc, "builder") != nil)

  const fixtureSource = """
    import std/os
    import niffler/sdk

    let comp = newComponent("discover-fixture", "0.1.0")

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

    comp.tool(%*{"onDemand": true, "timeoutMs": 150}):
      proc fixture_times_out(): JsonNode =
        ## Slow on-demand fixture tool.
        sleep(800)
        %*{"called": true}

    comp.tool(%*{"hidden": true, "onDemand": true}):
      proc fixture_hidden_needle(): JsonNode =
        ## HIDDEN_SENTINEL must never appear in discovery.
        %*{"hidden": true}

    comp.tool(%*{"hidden": true, "timeoutMs": 300000}):
      proc chat(messages: JsonNode, tools: JsonNode,
                sessionId: string, stream: bool): JsonNode =
        ## Fake LLM used by the discovery bus test.
        let last = messages[messages.len - 1]
        if last{"role"}.getStr("") == "user" and
            last{"content"}.getStr("") == "discover-alpha":
          let arguments = $(%*{"component": "discover-fixture",
                               "tools": ["fixture_demand_alpha"]})
          return %*{"content": "", "reasoning": "select discover schema",
                    "tool_calls": [{
            "id": "fixture-discover", "type": "function",
            "function": {"name": "discover", "arguments": arguments}}]}
        if last{"role"}.getStr("") == "tool":
          for message in messages:
            if message{"role"}.getStr("") == "assistant" and
                message{"tool_calls"} != nil:
              return %*{"content":
                if message{"reasoning"}.getStr("") == "select discover schema":
                  "discovery complete"
                else:
                  "reasoning missing"}
          return %*{"content": "tool call missing"}
        return %*{"content": $tools}

    comp.run()
    """.dedent()

  let built = call(nc, "builder", "build",
                   %*{"lang": "nim", "name": "discover-fixture",
                      "source": fixtureSource}, 300_000)
  check("builder builds discovery fixture", built{"ok"}.getBool(false), $built)
  if not built{"ok"}.getBool(false):
    report("DISCOVER TEST")
  let fixtureProcess = startComponent(built{"binary"}.getStr(""), url, root)
  defer: stopProcess(fixtureProcess)
  let fixture = waitForComponent(nc, "discover-fixture")
  check("discovery fixture registered", fixture != nil)

  let projected = call(nc, "core", "catalog", %*{"op": "list"})
  let projectedNames = names(projected{"tools"})
  check("direct projection is name-sorted", projectedNames.isSorted(),
        $projectedNames)
  check("direct projection includes discover, invoke, and fixture_direct",
        "discover" in projectedNames and "invoke" in projectedNames and
        "fixture_direct" in projectedNames, $projectedNames)
  check("direct projection omits on-demand and hidden fixture tools",
        "fixture_demand_alpha" notin projectedNames and
        "fixture_needs_approval" notin projectedNames and
        "fixture_times_out" notin projectedNames and
        "fixture_hidden_needle" notin projectedNames and
        "chat" notin projectedNames, $projectedNames)

  check("discover advertises limit and registry cursor",
        tool(projected{"tools"}, "discover")["schema"]["properties"]{"limit"} != nil and
        tool(projected{"tools"}, "discover")["schema"]["properties"]{"after"} != nil)

  let fullNames = names(fixture{"tools"})
  check("full snapshot keeps every fixture tool", fullNames.len == 6 and
        "fixture_demand_alpha" in fullNames and
        "fixture_hidden_needle" in fullNames and "chat" in fullNames,
        $fixture)
  check("full snapshot preserves discovery policy metadata",
        tool(fixture{"tools"}, "fixture_demand_alpha"){"schema"}{"x-harness"}{"onDemand"}.getBool(false) and
        tool(fixture{"tools"}, "fixture_needs_approval"){"schema"}{"x-harness"}{"approval"}.getStr("") == "always" and
        tool(fixture{"tools"}, "fixture_times_out"){"schema"}{"x-harness"}{"timeoutMs"}.getInt(0) == 150 and
        tool(fixture{"tools"}, "fixture_hidden_needle"){"schema"}{"x-harness"}{"hidden"}.getBool(false),
        $fixture)

  let summary1 = call(nc, "core", "discover", newJObject())
  let summary2 = call(nc, "core", "discover", newJObject())
  check("discover summary is deterministic", $summary1 == $summary2)
  let componentNames = names(summary1{"components"})
  check("discover components are name-sorted", componentNames.isSorted(),
        $componentNames)
  let fixtureSummary = component(summary1, "discover-fixture")
  # The registry is one line per component: what it is, how much of it there is,
  # and a few when-to-use sentences — the routing signal that used to sit in the
  # system prompt's roster, fetched on demand instead of re-sent in every
  # request prefix. Tool names are deliberately NOT enumerated: a loaded harness
  # lists 201 tools, which cost 9KB as names alone and 40KB with descriptions
  # (measured), and a single MCP server can own 65 of them.
  check("registry summarises a component instead of listing its tools",
        fixtureSummary{"tools"}.getInt(0) == 4 and
        fixtureSummary{"onDemand"}.getInt(0) == 3 and
        fixtureSummary{"direct"}.getInt(0) == 1 and
        fixtureSummary{"more"}.getInt(-1) == 0 and
        fixtureSummary{"hints"}[0]{"tool"}.getStr("") == "fixture_demand_alpha" and
        fixtureSummary{"hints"}[0]{"hint"}.getStr("").len > 0 and
        fixtureSummary{"hints"}.len == 3, $fixtureSummary)
  let componentHint = call(nc, "core", "discover", %*{"component": "discover-fixture"})
  check("component view still describes its tools",
        names(componentHint{"component"}{"onDemand"}) ==
          @["fixture_demand_alpha", "fixture_needs_approval", "fixture_times_out"] and
        names(componentHint{"component"}{"direct"}) == @["fixture_direct"] and
        componentHint{"component"}{"onDemand"}[0]{"description"}.getStr("").len > 0,
        $componentHint)
  let filtered = call(nc, "core", "discover", %*{
    "component": "discover-fixture", "query": "alpha"})
  check("component query filters inside a component",
        names(filtered{"component"}{"onDemand"}) == @["fixture_demand_alpha"],
        $filtered)
  check("discover never leaks hidden names or descriptions",
        not ($summary1).contains("fixture_hidden_needle") and
        not ($summary1).contains("HIDDEN_SENTINEL"), $summary1)

  let missedComponent = call(nc, "core", "discover", %*{
    "component": "discover-fixture", "query": "unmatched nonexistent"})
  check("component search recovery survives the bus error envelope",
        missedComponent{"error"}.getStr().contains("Every keyword must match") and
        missedComponent{"error"}.getStr().contains("tools:[name]"), $missedComponent)
  let selected1 = call(nc, "core", "discover", %*{
    "component": "discover-fixture",
    "tools": ["fixture_times_out", "fixture_demand_alpha"]})
  let selected2 = call(nc, "core", "discover", %*{
    "component": "discover-fixture",
    "tools": ["fixture_demand_alpha", "fixture_times_out"]})
  check("schema discovery is deterministic and request-order independent",
        $selected1 == $selected2 and
        names(selected1{"tools"}) == @["fixture_demand_alpha", "fixture_times_out"],
        $selected1)
  check("discovered schema equals the full catalog schema",
        selected1{"tools"}[0]{"schema"} ==
          tool(fixture{"tools"}, "fixture_demand_alpha"){"schema"},
        $selected1)

  let hiddenLookup = call(nc, "core", "discover", %*{
    "component": "discover-fixture", "tools": ["fixture_hidden_needle"]})
  let unknownLookup = call(nc, "core", "discover", %*{
    "component": "discover-fixture", "tools": ["fixture_unknown"]})
  check("hidden and unknown schema lookups are indistinguishable",
        hiddenLookup{"error"}.getStr("") == unknownLookup{"error"}.getStr("") and
        hiddenLookup{"error"}.getStr("").len > 0,
        $hiddenLookup & " / " & $unknownLookup)

  let pinned1 = call(nc, "core", "catalog", %*{
    "op": "schemas",
    "tools": ["fixture_times_out", "fixture_demand_alpha"]})
  let pinned2 = call(nc, "core", "catalog", %*{
    "op": "schemas",
    "tools": ["fixture_demand_alpha", "fixture_times_out"]})
  check("selected catalog snapshot is deterministic",
        $pinned1 == $pinned2 and
        names(pinned1{"tools"}) ==
          @["fixture_demand_alpha", "fixture_times_out"], $pinned1)
  check("selected snapshot includes owner version and fingerprint",
        pinned1{"tools"}[0]{"component"}.getStr("") == "discover-fixture" and
        pinned1{"tools"}[0]{"version"}.getStr("").len > 0 and
        pinned1{"tools"}[0]{"fingerprint"}.getStr("").len > 0, $pinned1)
  let pinnedHidden = call(nc, "core", "catalog", %*{
    "op": "schemas", "tools": ["fixture_hidden_needle"]})
  let pinnedUnknown = call(nc, "core", "catalog", %*{
    "op": "schemas", "tools": ["fixture_unknown"]})
  check("selected lookup does not distinguish hidden and unknown tools",
        pinnedHidden{"error"}.getStr("") == pinnedUnknown{"error"}.getStr("") and
        pinnedHidden{"error"}.getStr("").len > 0,
        $pinnedHidden & " / " & $pinnedUnknown)

  let invoked = call(nc, "core", "invoke", %*{
    "tool": "fixture_demand_alpha", "arguments": {"value": "through-core"}})
  check("invoke dispatches an on-demand tool",
        invoked == %*{"value": "through-core", "via": "invoke"}, $invoked)
  # The tolerant dotted spelling (`component.tool`) is resolved for the
  # lookup — and must ALSO be dispatched as the resolved bare name, not
  # sent to the component as its literal tool name (A632).
  let dotted = call(nc, "core", "invoke", %*{
    "tool": "discover-fixture.fixture_demand_alpha",
    "arguments": {"value": "dotted-through-core"}})
  check("invoke resolves the dotted spelling to the bare tool name",
        dotted == %*{"value": "dotted-through-core", "via": "invoke"}, $dotted)
  let denied = call(nc, "core", "invoke", %*{
    "tool": "fixture_needs_approval", "arguments": {}})
  check("invoke preserves target approval policy",
        denied{"error"}.getStr("").contains("approval denied") and
        denied{"error"}.getStr("").contains("fixture_needs_approval"), $denied)
  let hiddenInvoke = call(nc, "core", "invoke", %*{
    "tool": "fixture_hidden_needle", "arguments": {}})
  let unknownInvoke = call(nc, "core", "invoke", %*{
    "tool": "fixture_unknown", "arguments": {}})
  check("invoke does not expose hidden tools as an existence oracle",
        hiddenInvoke{"error"}.getStr("") == unknownInvoke{"error"}.getStr(""),
        $hiddenInvoke & " / " & $unknownInvoke)

  let status = call(nc, "core", "status", newJObject())
  check("live status includes core and externally registered components",
        component(status, "core") != nil and
        component(status, "discover-fixture") != nil, $status)

  let sessionId = "discover-projection"
  let firstTurn = call(nc, "core", "session",
                       %*{"sessionId": sessionId, "content": "capture"},
                       120_000)
  var firstLlmTools = newJArray()
  try:
    firstLlmTools = firstTurn{"reply"}.getStr("[]").parseJson()
  except CatchableError:
    discard
  let firstLlmNames = names(firstLlmTools, nested = true)
  check("actual LLM request uses the direct projection",
        firstLlmNames == projectedNames, $firstTurn)

  let exposure1 = call(nc, "store", "get",
                       %*{"kind": "session", "id": sessionId & ":tools"})
  check("session persists its immutable direct snapshot",
        exposure1{"ok"}.getBool(false) and
        names(exposure1{"value"}{"direct"}) == projectedNames and
        exposure1{"value"}{"discovered"}.len == 0, $exposure1)

  const lateSource = """
    import niffler/sdk
    let comp = newComponent("discover-late", "0.1.0")
    comp.tool:
      proc fixture_late(value: string): JsonNode =
        ## Tool registered after a conversation freezes its direct projection.
        ## - value: value to echo
        %*{"value": value, "late": true}
    comp.run()
    """.dedent()
  let lateBuilt = call(nc, "builder", "build",
                       %*{"lang": "nim", "name": "discover-late",
                          "source": lateSource}, 300_000)
  check("builder builds late fixture", lateBuilt{"ok"}.getBool(false), $lateBuilt)
  if not lateBuilt{"ok"}.getBool(false):
    report("DISCOVER TEST")
  let lateProcess = startComponent(lateBuilt{"binary"}.getStr(""), url, root)
  defer: stopProcess(lateProcess)
  check("late fixture registered", waitForComponent(nc, "discover-late") != nil)

  let secondTurn = call(nc, "core", "session",
                        %*{"sessionId": sessionId, "content": "capture"},
                        120_000)
  var secondLlmTools = newJArray()
  try:
    secondLlmTools = secondTurn{"reply"}.getStr("[]").parseJson()
  except CatchableError:
    discard
  let secondLlmNames = names(secondLlmTools, nested = true)
  check("component churn does not mutate an existing session prefix",
        secondLlmNames == firstLlmNames and "fixture_late" notin secondLlmNames,
        $secondTurn)
  let lateDiscovery = call(nc, "core", "discover",
                           %*{"component": "discover-late",
                              "tools": ["fixture_late"]})
  check("late component remains discoverable",
        names(lateDiscovery{"tools"}) == @["fixture_late"], $lateDiscovery)
  let lateInvoke = call(nc, "core", "invoke",
                        %*{"tool": "fixture_late",
                           "arguments": {"value": "new capability"}})
  check("invoke reaches a late default tool absent from the fixed projection",
        lateInvoke == %*{"value": "new capability", "late": true}, $lateInvoke)

  let discoveryTurn = call(nc, "core", "session",
                           %*{"sessionId": sessionId,
                              "content": "discover-alpha"}, 120_000)
  check("session runner can call core discover",
        discoveryTurn{"reply"}.getStr("") == "discovery complete", $discoveryTurn)
  let exposure2 = call(nc, "store", "get",
                       %*{"kind": "session", "id": sessionId & ":tools"})
  check("successful schema discovery is persisted for the UI",
        exposure2{"value"}{"discovered"}.len == 1 and
        exposure2{"value"}{"discovered"}[0]{"component"}.getStr("") ==
          "discover-fixture" and
        exposure2{"value"}{"discovered"}[0]{"name"}.getStr("") ==
          "fixture_demand_alpha" and
        names(exposure2{"value"}{"direct"}) == projectedNames,
        $exposure2)
  let messages = call(nc, "store", "list",
                      %*{"kind": "message", "idPrefix": sessionId & ":"})
  var schemaInHistory = false
  for item in messages{"items"}:
    let value = item{"value"}
    if value{"role"}.getStr("") == "tool" and
        value{"name"}.getStr("") == "discover" and
        value{"content"}.getStr("").contains("fixture_demand_alpha"):
      schemaInHistory = true
  check("discovered schemas are additive conversation history", schemaInHistory,
        $messages)
  var reasoningCall = -1
  var discoveryResult = -1
  var messageIndex = 0
  for item in messages{"items"}:
    let value = item{"value"}
    if value{"role"}.getStr("") == "assistant" and
        value{"reasoning"}.getStr("") == "select discover schema" and
        value{"tool_calls"} != nil:
      reasoningCall = messageIndex
    if value{"role"}.getStr("") == "tool" and
        value{"name"}.getStr("") == "discover":
      discoveryResult = messageIndex
    messageIndex.inc
  check("tool-call reasoning is persisted before its result",
        reasoningCall >= 0 and discoveryResult > reasoningCall, $messages)

  let started = epochTime()
  let timedOut = call(nc, "core", "invoke", %*{
    "tool": "fixture_times_out", "arguments": {}}, 5_000)
  let elapsed = epochTime() - started
  check("invoke preserves target timeout policy",
        timedOut{"error"}.getStr("").contains("timed out after 150ms") and
        elapsed < 2.0, $timedOut & " elapsed=" & $elapsed)

  report("DISCOVER TEST")

main()
