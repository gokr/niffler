## config component — the one discoverable configuration surface.
##
## Every other component owns its own settings where it always has: a store
## document in its own kind, written by its own tool. This component adds the
## missing half — DISCOVERY, VALIDATION and a single editing API — without
## taking ownership away from anyone (docs/research/CONFIG.md C6, C11):
##
##   * an owner publishes a DECLARATION (JSON Schema + UI/application metadata)
##     through config_declare; the declaration is durable, so it survives an
##     owner that is stopped or replaced;
##   * config_list / config_get let a human or a model see what is tunable,
##     with defaults, current values, revisions and per-property metadata;
##   * config_patch / config_reset validate a change and forward it to the
##     OWNER's tool, which does the actual compare-and-set write. config never
##     writes another component's store document, so invariants an owner
##     enforces (credential handling, derived caches, migration) stay enforced.
##
## Why a component and not core: core must not grow a settings engine (C11),
## and core supplies the parts that must be un-retirable — routing, approval
## enforcement and the catalog. Being a component also means the agent can
## replace or remove this surface like any other capability.
##
## What is deliberately NOT here: no settings values in a prompt prefix (a
## change is visible at the owner's next call, never spliced into history), no
## env-var bridge (that is each owner's migration to do), and no shared scope
## (that decision is still open — a declaration asking for it is refused rather
## than silently treated as per-instance).
##
## Contract: docs/research/CONFIG-CONTRACT.md.

import std/[json, strutils, times]
import natsnim
import niffler/sdk

let comp = newComponent("config", "0.1.0")

const
  declKind = "configdecl"        ## store kind holding declarations
  maxSchemaBytes = 32_768        ## a declaration is metadata, not a document

# ---------------------------------------------------------------------------
# validation — the JSON Schema subset this component actually enforces

type SchemaError = object of CatchableError

proc fail(msg: string) {.noreturn.} = raise newException(SchemaError, msg)

const supportedKeywords = [
  "type", "properties", "required", "enum", "minimum", "maximum",
  "minLength", "maxLength", "additionalProperties", "description", "title",
  "default", "x-config"]

proc jsonType(v: JsonNode): string =
  ## JSON type name of a value, in JSON Schema's vocabulary.
  if v == nil: return "null"
  case v.kind
  of JNull: "null"
  of JBool: "boolean"
  of JInt, JFloat: "number"
  of JString: "string"
  of JArray: "array"
  of JObject: "object"

proc typeMatches(want, v: JsonNode): bool =
  ## "number" admits an integer; every other name is exact. "integer" is
  ## checked separately because JSON Schema distinguishes it.
  let name = want.getStr("")
  let got = jsonType(v)
  if name == "number": return got == "number" or got == "integer"
  if name == "integer": return got == "number" or got == "integer"
  got == name

proc checkSchemaShape(schema: JsonNode, where: string) =
  ## Refuse a declaration this component cannot enforce: silently ignoring a
  ## constraint would report a validation that never happened.
  if schema == nil or schema.kind != JObject:
    fail(where & ": schema must be an object")
  for key, _ in schema.pairs:
    if key notin supportedKeywords:
      fail(where & ": unsupported schema keyword '" & key &
           "' (supported: " & supportedKeywords.join(", ") & ")")
  if schema{"properties"} != nil:
    if schema{"properties"}.kind != JObject:
      fail(where & ": properties must be an object")
    for name, prop in schema{"properties"}.pairs:
      checkSchemaShape(prop, where & "." & name)
      if prop{"x-config"} != nil:
        let x = prop{"x-config"}
        if x.kind != JObject: fail(where & "." & name & ": x-config must be an object")
        for key, _ in x.pairs:
          if key notin ["title", "description", "secret", "readOnly",
                        "application", "humanOnly"]:
            fail(where & "." & name & ": unknown x-config key '" & key & "'")
        if x{"application"} != nil and
            x{"application"}.getStr("") notin
              ["immediate", "next turn", "next conversation", "component restart"]:
          fail(where & "." & name & ": invalid application timing")
        for flag in ["secret", "readOnly", "humanOnly"]:
          if x{flag} != nil and x{flag}.kind != JBool:
            fail(where & "." & name & ": " & flag & " must be boolean")
  if schema{"required"} != nil and schema{"required"}.kind != JArray:
    fail(where & ": required must be an array")

proc validateValue(schema, value: JsonNode, where: string) =
  ## Validate one value against the supported subset.
  let typeNode = schema{"type"}
  if typeNode != nil:
    var matched = false
    if typeNode.kind == JArray:
      for t in typeNode: (if typeMatches(t, value): matched = true)
    else:
      matched = typeMatches(typeNode, value)
    if not matched:
      fail(where & ": expected " & (if typeNode.kind == JArray: $typeNode
                                    else: typeNode.getStr("")) &
           ", got " & jsonType(value))
  if schema{"enum"} != nil:
    var ok = false
    for allowed in schema{"enum"}:
      if allowed == value: ok = true
    if not ok: fail(where & ": must be one of " & $schema{"enum"})
  if value != nil and value.kind in {JInt, JFloat}:
    if schema{"minimum"} != nil and value.getFloat() < schema{"minimum"}.getFloat():
      fail(where & ": below minimum " & $schema{"minimum"})
    if schema{"maximum"} != nil and value.getFloat() > schema{"maximum"}.getFloat():
      fail(where & ": above maximum " & $schema{"maximum"})
  if value != nil and value.kind == JString:
    if schema{"minLength"} != nil and value.getStr("").len < schema{"minLength"}.getInt(0):
      fail(where & ": shorter than " & $schema{"minLength"})
    if schema{"maxLength"} != nil and value.getStr("").len > schema{"maxLength"}.getInt(0):
      fail(where & ": longer than " & $schema{"maxLength"})
  if value != nil and value.kind == JObject and schema{"properties"} != nil:
    for name, prop in schema{"properties"}.pairs:
      if value.hasKey(name):
        validateValue(prop, value[name], where & "." & name)
  if value != nil and value.kind == JObject:
    let required = schema{"required"}
    if required != nil:
      for name in required:
        if not value.hasKey(name.getStr("")):
          fail(where & ": missing required property '" & name.getStr("") & "'")
    let extra = schema{"additionalProperties"}
    if extra != nil and extra.kind == JBool and extra.getBool(false) == false and
        schema{"properties"} != nil:
      for name, _ in value.pairs:
        if schema{"properties"}{name} == nil:
          fail(where & ": unknown property '" & name & "'")

proc announceChange(c: Component, domain, owner: string, rev: int) =
  ## Tell snapshot owners a domain changed. Fire-and-forget by design: a
  ## component that misses it keeps its last values until its next real read,
  ## and no subscriber can fail the mutation that already succeeded.
  try:
    c.nc.publish("ev.config.updated",
      Envelope(v: 1, id: newId(), kind: ekEvent,
               payload: %*{"domain": domain, "owner": owner,
                           "rev": rev}).encode())
  except CatchableError:
    discard

proc propMeta(declaration: JsonNode, name: string): JsonNode =
  ## x-config of one declared property (nil when absent).
  declaration{"schema", "properties", name, "x-config"}

proc isSecret(declaration: JsonNode, name: string): bool =
  let m = propMeta(declaration, name)
  m != nil and m{"secret"} != nil and m{"secret"}.getBool(false)

proc isReadOnly(declaration: JsonNode, name: string): bool =
  let m = propMeta(declaration, name)
  m != nil and m{"readOnly"} != nil and m{"readOnly"}.getBool(false)

proc isHumanOnly(declaration: JsonNode, name: string): bool =
  ## A property a MODEL may not turn on or off, only report. Approval alone is
  ## not enough for a field whose whole meaning is "a human decided this":
  ## approval answers "may I run this?", while a subagent asked to widen its
  ## own reach would be asking the person who delegated the task, not the
  ## person who owns the setting.
  let m = propMeta(declaration, name)
  m != nil and m{"humanOnly"} != nil and m{"humanOnly"}.getBool(false)

proc effectiveTiming(declaration: JsonNode, name: string): string =
  ## When a change to `name` takes effect: the property's own claim, else the
  ## domain's fallback. Never invented — config_declare refuses a declaration
  ## that omits the domain timing, so this always has an honest answer.
  let m = propMeta(declaration, name)
  if m != nil and m{"application"} != nil and m{"application"}.getStr("").len > 0:
    return m{"application"}.getStr("")
  declaration{"application"}.getStr("")

# ---------------------------------------------------------------------------
# who is calling
#
type CallerKind = enum
  ckDirect,     ## no live session: a human's CLI, a script, another component
  ckRoot,       ## a conversation a human is driving
  ckSubagent,   ## a conversation spawned as a child by agent_spawn/agent_run
  ckUnknown     ## a session whose lineage record could not be read

proc callerKind(c: Component): CallerKind =
  ## Classify the caller from a fact core OWNS, not from a claim the caller
  ## makes: the session id is the runner's private context (x-harness
  ## sessionId, injected and overwritten by core at dispatch) and "is this a
  ## subagent" is the durable `sessionmeta.parent` lineage relation — the same
  ## one agent_run authorizes against.
  ##
  ## Deliberately NOT done: inferring a subagent from a prompt hint or a tool
  ## argument. Both are supplied by the caller, which is the thing being
  ## classified.
  if c.sessionContext.len == 0: return ckDirect
  try:
    let meta = c.storeGet("sessionmeta", c.sessionContext, 5_000)
    if meta.value == nil: return ckRoot
    if meta.value{"parent"}.getStr("").len > 0: return ckSubagent
    return ckRoot
  except StoreNotFoundError:
    # No lineage record. A subagent always has one (agent_spawn writes it
    # before the child's first turn), so this is a root conversation —
    # possibly one created before sessionmeta existed.
    return ckRoot
  except CatchableError:
    # Unreadable is not root. This only matters for humanOnly properties, and
    # there failing closed is the point.
    return ckUnknown

proc humanOnlyRefusal(c: Component, declaration: JsonNode,
                      names: seq[string]): string =
  ## "" when this caller may touch `names`, else why it may not. Only
  ## humanOnly properties are consulted, so an ordinary tuning field stays
  ## editable by an autonomous subagent.
  var guarded: seq[string]
  for name in names:
    if isHumanOnly(declaration, name): guarded.add(name)
  if guarded.len == 0: return ""
  case c.callerKind()
  of ckDirect, ckRoot: ""
  of ckSubagent:
    "property '" & guarded.join("', '") & "' is human-only: it cannot be " &
    "changed from a subagent session, because the approval would be answered " &
    "by whoever delegated this task rather than by the human who owns the " &
    "setting. Report the change you need instead of making it."
  of ckUnknown:
    "property '" & guarded.join("', '") & "' is human-only and this " &
    "session's lineage record is unreadable, so the caller cannot be shown " &
    "to be a human's own conversation"

# ---------------------------------------------------------------------------
# declaration access

proc declarationId(domain: string): string {.used.} = domain

proc declarationStoreId(domain: string): string =
  ## Declaration ids are the domain: one declaration per domain, so a
  ## re-declaring owner replaces its own record instead of accumulating.
  domain

proc loadDeclaration(c: Component, domain: string): JsonNode =
  let item = c.storeGet(declKind, declarationStoreId(domain))
  item.value

proc ownerAnswers(c: Component, declaration: JsonNode): bool =
  ## "Available" means the owner's own tool answers a read — NOT that core
  ## lists the component. A registered component can still be restarting, and a
  ## catalog entry proves registration, not that a settings read would work.
  ## The probe is the same read config_get performs, so the two cannot disagree.
  let owner = declaration{"owner"}.getStr("")
  let tool = declaration{"ownerTool"}.getStr("")
  if owner.len == 0: return false
  if tool.len == 0: return true  # stateless domain: nothing to ask
  try:
    discard c.requestOk(owner, tool,
      %*{"op": "get", "domain": declaration{"domain"}.getStr("")}, 3_000)
    return true
  except CatchableError:
    return false

proc summarise(c: Component, declaration: JsonNode): JsonNode =
  ## A declaration as config_list reports it: identity, presentation and the
  ## live-owner check. Values are never included here.
  let owner = declaration{"owner"}.getStr("")
  let available = c.ownerAnswers(declaration)
  var properties = 0
  var secrets = 0
  for name, _ in declaration{"schema", "properties"}.pairs:
    inc properties
    if isSecret(declaration, name): inc secrets
  %*{"domain": declaration{"domain"}, "title": declaration{"title"},
     "description": declaration{"description"}, "owner": owner,
     "ownerTool": declaration{"ownerTool"}, "version": declaration{"version"},
     "scope": declaration{"scope"}, "application": declaration{"application"},
     "properties": properties, "secrets": secrets, "ownerAvailable": available}

# ---------------------------------------------------------------------------
# tools

comp.tool(%*{"onDemand": true}):
  proc config_list(): JsonNode =
    ## List every configuration domain any component has declared, with its
    ## title, owning component, property count and whether that owner is live.
    ## Use before changing behavior: it is the catalogue of what is tunable at
    ## runtime (a knob that is not here is still an environment variable).
    ## Follow with config_get for values and schemas, then config_patch.
    var items = newJArray()
    for entry in comp.storeListAll(declKind):
      items.add(summarise(comp, entry.value))
    %*{"ok": true, "count": items.len, "domains": items}

comp.tool(%*{"onDemand": true}):
  proc config_get(domain: string): JsonNode =
    ## Read one domain: its schema (so a UI can render a form), the current
    ## values, the defaults, and the revision a patch must match. Secret
    ## properties are reported as {"set": bool} — never their value.
    ## - domain: id from config_list
    let declaration = loadDeclaration(comp, domain)
    if declaration == nil:
      return errResult("unknown configuration domain '" & domain & "'", "unknown-domain")
    let owner = declaration{"owner"}.getStr("")
    let ownerTool = declaration{"ownerTool"}.getStr("")
    var values = newJObject()
    var rev = 0
    var ownerAvailable = owner.len > 0
    if ownerTool.len > 0:
      try:
        let current = comp.requestOk(owner, ownerTool,
          %*{"op": "get", "domain": domain}, 8_000)
        values = current{"values"}
        rev = current{"rev"}.getInt(0)
        ownerAvailable = true
      except CatchableError:
        # The declaration is durable, the values are the owner's: report the
        # owner as unavailable instead of inventing defaults for real state.
        ownerAvailable = false
        return %*{"ok": false, "code": "owner-unavailable", "domain": domain,
                  "owner": owner, "schema": declaration{"schema"},
                  "application": declaration{"application"},
                  "error": owner & " did not answer " & ownerTool &
                           "; its declaration is listed but values are unknown"}
    var defaults = newJObject()
    for name, prop in declaration{"schema", "properties"}.pairs:
      if prop{"default"} != nil and not isSecret(declaration, name):
        defaults[name] = prop{"default"}
    # Per-property timing, reported so an agent or a generated form can promise
    # the right thing. Only properties that override the domain fallback are
    # listed; the rest inherit `application` below, which is always present.
    var timings = newJObject()
    var humanOnly: seq[string]
    for name, _ in declaration{"schema", "properties"}.pairs:
      let m = propMeta(declaration, name)
      if m != nil and m{"application"} != nil:
        timings[name] = %effectiveTiming(declaration, name)
      if isHumanOnly(declaration, name): humanOnly.add(name)
    var redacted = newJObject()
    for name, _ in declaration{"schema", "properties"}.pairs:
      if values.hasKey(name):
        if isSecret(declaration, name):
          redacted[name] = %*{"set": true}
        else:
          redacted[name] = values[name]
    %*{"ok": true, "domain": domain, "title": declaration{"title"},
       "description": declaration{"description"}, "owner": owner,
       "ownerAvailable": ownerAvailable, "rev": rev, "values": redacted,
       "defaults": defaults, "schema": declaration{"schema"},
       "application": declaration{"application"}, "timings": timings,
       "humanOnly": %humanOnly}

# `sessionId: true` is how this tool learns WHICH conversation is asking: core
# injects the runner's private `__session.session` at dispatch, so a humanOnly
# property can be told apart from a subagent's attempt. It carries no lease and
# does not fail closed, so a direct (sessionless) caller is still served — it
# simply reads as "".
comp.tool(%*{"onDemand": true, "approval": "always", "effect": "write",
             "sessionId": true}):
  proc config_patch(domain: string, patch: JsonNode,
                    expectRev: int = -2): JsonNode =
    ## Change settings in one domain. The patch is validated before anything
    ## is written, then applied by the OWNER (this component never writes
    ## another component's record). A secret is written without being echoed;
    ## read-only properties are refused.
    ## - domain: id from config_list
    ## - patch: JSON object of properties to change (a JSON Merge Patch body)
    ## - expectRev: require the current revision to match; omit to apply
    ##   unconditionally
    let declaration = loadDeclaration(comp, domain)
    if declaration == nil:
      return errResult("unknown configuration domain '" & domain & "'", "unknown-domain")
    if patch == nil or patch.kind != JObject:
      return errResult("patch must be a JSON object", "bad-request")
    let owner = declaration{"owner"}.getStr("")
    let ownerTool = declaration{"ownerTool"}.getStr("")
    if ownerTool.len == 0:
      return errResult("domain '" & domain & "' has no mutable state", "not-writable")
    # Refuse read-only properties by name before the schema check so the error
    # says which property and why.
    var touched: seq[string]
    for name, _ in patch.pairs: touched.add(name)
    for name in touched:
      if isReadOnly(declaration, name):
        return errResult("property '" & name & "' is read-only", "bad-request")
    # Approval is necessary but not sufficient (CONFIG.md C10): a property the
    # owner marked human-only may only be changed from a human's own
    # conversation or from a direct, sessionless call.
    let refusal = comp.humanOnlyRefusal(declaration, touched)
    if refusal.len > 0: return errResult(refusal, "human-only")
    try:
      validateValue(declaration{"schema"}, patch, "patch")
    except SchemaError as e:
      return errResult(e.msg, "bad-request")
    var args = %*{"op": "patch", "domain": domain, "patch": patch}
    if expectRev != -2: args["expectRev"] = %expectRev
    try:
      let applied = comp.requestOk(owner, ownerTool, args, 15_000)
      result = applied
      result["ok"] = %true
      result["domain"] = %domain
      # Say when the change lands, so a caller does not read the new value back
      # and conclude the new BEHAVIOR is already live. This is the timing the
      # owner promised in its declaration; config reports it, the owner honors
      # it.
      var applies = newJObject()
      for name in touched:
        applies[name] = %effectiveTiming(declaration, name)
      result["applies"] = applies
      comp.announceChange(domain, owner, applied{"rev"}.getInt(0))
    except CatchableError as e:
      return errResult(owner & " refused the change: " & e.msg, "owner-refused")

comp.tool(%*{"onDemand": true, "approval": "always", "effect": "write",
             "sessionId": true}):
  proc config_reset(domain: string, properties: seq[string] = @[],
                    expectRev: int = -2): JsonNode =
    ## Drop explicit values so the declared defaults apply again.
    ## - domain: id from config_list
    ## - properties: names to reset; empty resets every mutable property
    ## - expectRev: require the current revision to match
    let declaration = loadDeclaration(comp, domain)
    if declaration == nil:
      return errResult("unknown configuration domain '" & domain & "'", "unknown-domain")
    let ownerTool = declaration{"ownerTool"}.getStr("")
    if ownerTool.len == 0:
      return errResult("domain '" & domain & "' has no mutable state", "not-writable")
    for name in properties:
      if declaration{"schema", "properties"}{name} == nil:
        return errResult("unknown property '" & name & "'", "bad-request")
      if isReadOnly(declaration, name):
        return errResult("property '" & name & "' is read-only", "bad-request")
    # An empty list means "every mutable property", so it would clear
    # human-only values too. Guard the broad form explicitly instead of letting
    # it slip past a check written for the narrow one.
    var guarded = properties
    if guarded.len == 0:
      for name, _ in declaration{"schema", "properties"}.pairs:
        if not isReadOnly(declaration, name): guarded.add(name)
    let refusal = comp.humanOnlyRefusal(declaration, guarded)
    if refusal.len > 0: return errResult(refusal, "human-only")
    var args = %*{"op": "reset", "domain": domain, "properties": properties}
    if expectRev != -2: args["expectRev"] = %expectRev
    try:
      let applied = comp.requestOk(declaration{"owner"}.getStr(""), ownerTool, args, 15_000)
      result = applied
      result["ok"] = %true
      result["domain"] = %domain
      comp.announceChange(domain, declaration{"owner"}.getStr(""),
                          applied{"rev"}.getInt(0))
    except CatchableError as e:
      return errResult(declaration{"owner"}.getStr("") &
                       " refused the reset: " & e.msg, "owner-refused")

# The declaration API is infrastructure the model must not call: declaring a
# domain is a component's own act, exactly like instance registration. Hidden
# rather than on-demand, because a wrong declaration would make the whole
# surface describe settings that do not exist.
comp.tool(%*{"hidden": true, "effect": "write"}):
  proc config_declare(declaration: JsonNode): JsonNode =
    ## Publish (or replace) one domain's declaration. Called by owning
    ## components at startup; validates the schema subset this surface can
    ## enforce and refuses anything it would have to ignore.
    let domain = declaration{"domain"}.getStr("")
    if domain.len < 3 or domain.len > 128 or
        not domain.allCharsInSet({'a'..'z', '0'..'9', '.', '-', '_'}):
      return errResult("domain must be 3..128 chars of a-z 0-9 . - _", "bad-request")
    let owner = declaration{"owner"}.getStr("")
    if owner.len == 0:
      return errResult("owner component is required", "bad-request")
    if declaration{"kind"}.getStr("").len == 0:
      return errResult("kind is required (where the owner stores its values)", "bad-request")
    let scope = declaration{"scope"}.getStr("instance")
    if scope != "instance":
      return errResult("scope '" & scope & "' is not implemented; only 'instance' is",
                       "bad-request")
    # REQUIRED, with no default. "When does this take effect" is a claim the
    # owner must make deliberately: a silent "immediate" default let a
    # component promise more than it delivers (observe captured its caps at
    # creation but would have declared "immediate").
    let application = declaration{"application"}.getStr("")
    if application.len == 0:
      return errResult("application is required (immediate | next turn | " &
                       "next conversation | component restart) — state when a " &
                       "change takes effect", "bad-request")
    if application notin ["immediate", "next turn", "next conversation", "component restart"]:
      return errResult("invalid application timing", "bad-request")
    if declaration{"schema"} == nil:
      return errResult("schema is required", "bad-request")
    if ($declaration).len > maxSchemaBytes:
      return errResult("declaration is too large", "bad-request")
    try:
      checkSchemaShape(declaration{"schema"}, domain)
    except SchemaError as e:
      return errResult(e.msg, "bad-request")
    var stored = declaration.copy()
    stored["scope"] = %scope
    stored["application"] = %application
    stored["declaredAt"] = %epochTime()
    try:
      let rev = comp.storePut(declKind, declarationStoreId(domain), stored)
      return %*{"ok": true, "domain": domain, "rev": rev}
    except CatchableError as e:
      return errResult("cannot record declaration: " & e.msg, "store-unavailable")

comp.run()
