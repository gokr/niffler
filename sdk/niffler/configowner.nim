## configowner — the owner half of the configuration surface
## (docs/research/CONFIG-CONTRACT.md).
##
## A component that owns settings keeps owning them: its values stay in its own
## store record, written by its own code. This module removes the boilerplate
## every owner would otherwise repeat — the `get`/`patch`/`reset` protocol, the
## compare-and-set write, and the idempotent declaration — while leaving the
## decisions to the owner (what a value means, how it is validated, when it
## takes effect).
##
## Deliberately Nim-only and wire-free: nothing here changes the envelope, the
## store contract or the other SDKs. It is a convenience for components that
## own settings, not a new protocol.
##
## Usage (see components/repomap and components/fetch):
##
##   let store = OwnerStore(kind: "repomap-settings", id: "main")
##   # in the tool:
##   result = c.ownerOp(store, args)          # get | patch | reset
##   # in an idle tick after registration:
##   c.declareConfig(declaration)
##
## Values are stored as a plain object under "values", so an owner can grow new
## keys without a migration and a hand-edited record cannot corrupt anything the
## owner does not read.

import std/[json, os, strutils]
import ./sdk

type
  OwnerStore* = object
    kind*: string  ## store kind holding this owner's values
    id*: string    ## store id inside that kind ("main" for a singleton)

proc loadOwnerValues*(c: Component, store: OwnerStore,
                      timeoutMs = 5_000): tuple[values: JsonNode, rev: int] =
  ## Current explicit values and their revision. An absent record is an empty
  ## configuration at revision 0 — the normal state of a domain nobody has
  ## changed yet, never an error.
  try:
    let item = c.storeGet(store.kind, store.id, timeoutMs)
    if item.value == nil: return (newJObject(), 0)
    let values = item.value{"values"}
    let usable = if values != nil and values.kind == JObject: values
                 else: newJObject()
    (usable, item.rev)
  except CatchableError:
    (newJObject(), 0)

proc ownerGet*(c: Component, store: OwnerStore, timeoutMs = 5_000): JsonNode =
  ## The `get` reply the config component expects.
  let (values, rev) = c.loadOwnerValues(store, timeoutMs)
  %*{"ok": true, "values": values, "rev": rev}

proc ownerPatch*(c: Component, store: OwnerStore, patch: JsonNode,
                 expectRev = -2, timeoutMs = 8_000): JsonNode =
  ## Apply a merge patch under compare-and-set. The caller (the config
  ## component) has already validated the schema; this owns the write.
  ## A stale revision is a refusal, never a lost update.
  if patch == nil or patch.kind != JObject:
    return errResult("patch must be a JSON object", "bad-request")
  let (current, rev) = c.loadOwnerValues(store, timeoutMs)
  if expectRev != -2 and expectRev != rev:
    return errResult("rev-conflict: revision " & $expectRev & " != " & $rev,
                     "rev-conflict")
  var values = current
  for name, value in patch.pairs:
    if value == nil or value.kind == JNull:
      # An explicit null UNSETS a value (that is how a secret is cleared);
      # it is not the same as omitting the property.
      values.delete(name)
    else:
      values[name] = value
  try:
    let newRev = c.storePut(store.kind, store.id, %*{"values": values}, rev,
                            timeoutMs)
    return %*{"ok": true, "rev": newRev, "values": values}
  except CatchableError as e:
    return errResult("cannot write settings: " & e.msg, "store-unavailable")

proc ownerReset*(c: Component, store: OwnerStore, properties: seq[string],
                 expectRev = -2, timeoutMs = 8_000): JsonNode =
  ## Drop explicit values so the declared defaults apply again. An empty list
  ## means every property: the owner cannot ask config which ones exist, and a
  ## partial reset would silently leave values behind.
  let (current, rev) = c.loadOwnerValues(store, timeoutMs)
  if expectRev != -2 and expectRev != rev:
    return errResult("rev-conflict: revision " & $expectRev & " != " & $rev,
                     "rev-conflict")
  var values = current
  if properties.len == 0:
    values = newJObject()
  else:
    for name in properties: values.delete(name)
  if rev == 0:
    # Nothing was stored: reset is already the state. Writing an empty record
    # would make an untouched domain look configured.
    return %*{"ok": true, "rev": 0, "values": values}
  try:
    let newRev = c.storePut(store.kind, store.id, %*{"values": values}, rev,
                            timeoutMs)
    return %*{"ok": true, "rev": newRev, "values": values}
  except CatchableError as e:
    return errResult("cannot write settings: " & e.msg, "store-unavailable")

proc ownerOp*(c: Component, store: OwnerStore, args: JsonNode,
              timeoutMs = 8_000): JsonNode =
  ## Dispatch one `get`/`patch`/`reset` call from the config component. An
  ## unknown op refuses rather than defaulting to a read, so a caller bug
  ## cannot look like success.
  case args{"op"}.getStr("")
  of "get": c.ownerGet(store, timeoutMs)
  of "patch": c.ownerPatch(store, args{"patch"}, args{"expectRev"}.getInt(-2),
                           timeoutMs)
  of "reset":
    var names: seq[string]
    let list = args{"properties"}
    if list != nil and list.kind == JArray:
      for item in list: names.add(item.getStr(""))
    c.ownerReset(store, names, args{"expectRev"}.getInt(-2), timeoutMs)
  else:
    errResult("unsupported config op '" & args{"op"}.getStr("") & "'",
              "bad-request")

type
  Application* = enum
    ## When a declared change takes effect. There is deliberately no default
    ## anywhere: a declaration that omits it is refused by config.
    appImmediate = "immediate"
    appNextTurn = "next turn"
    appNextConversation = "next conversation"
    appComponentRestart = "component restart"

proc declaration*(domain, owner, ownerTool, title, description: string,
                  kind: string; application: Application;
                  schema: JsonNode; id = "main"; version = 1): JsonNode =
  ## Build a declaration with the timing REQUIRED as a typed argument, so an
  ## owner cannot inherit a silent "immediate" by forgetting the field.
  %*{"domain": domain, "version": version, "owner": owner,
     "ownerTool": ownerTool, "title": title, "description": description,
     "kind": kind, "id": id, "application": $application, "schema": schema}

proc declareConfig*(c: Component, declaration: JsonNode, timeoutMs = 1_000): bool =
  ## Publish this owner's declaration. Best effort by design: a failed
  ## declaration must not take the owner down — it only means the domain is not
  ## discoverable (the config component is optional, and a component can be run
  ## standalone with no harness at all). Returns whether it landed.
  ##
  ## The timeout is SHORT on purpose: this is called from the idle seam, which
  ## runs on the main pump thread. A long timeout there is a stall — with no
  ## config component the request cannot be answered at all, and a 10s wait
  ## per tick starved every other message the component owed.
  try:
    let reply = c.requestOk("config", "config_declare",
                            %*{"declaration": declaration}, timeoutMs)
    result = reply{"ok"}.getBool(false)
  except CatchableError:
    result = false

proc settingStr*(values: JsonNode, name, envName, dflt: string): string =
  ## One string setting: an explicit stored value wins, else the environment
  ## (the migration path every owner keeps while its env var is retired), else
  ## the default.
  if values != nil and values{name} != nil and values{name}.kind == JString:
    return values{name}.getStr("")
  let env = getEnv(envName, "")
  if env.len > 0: return env
  dflt

proc settingBool*(values: JsonNode, name, envName: string, dflt: bool): bool =
  ## One boolean setting. The env fallback keeps the historical spellings
  ## (1/true/yes, 0/false/no) so an existing deployment does not silently flip.
  if values != nil and values{name} != nil and values{name}.kind == JBool:
    return values{name}.getBool(false)
  let env = getEnv(envName, "").toLowerAscii()
  if env in ["1", "true", "yes", "on"]: return true
  if env in ["0", "false", "no", "off"]: return false
  dflt

proc settingInt*(values: JsonNode, name, envName: string, dflt: int): int =
  ## One positive-integer setting; a non-positive value falls back to the
  ## default, because a zeroed gate would silently admit everything.
  if values != nil and values{name} != nil and
      values{name}.kind in {JInt, JFloat}:
    let stored = values{name}.getInt(dflt)
    if stored > 0: return stored
    return dflt
  let raw = getEnv(envName, "")
  if raw.len == 0: return dflt
  try:
    let parsed = parseInt(raw)
    if parsed > 0: return parsed
  except ValueError:
    discard
  dflt

# ---------------------------------------------------------------------------
# Snapshot cache for owners whose settings are read deep inside code paths that
# have no component handle (log rotation, ring buffers, parsers).
#
# Refreshed from an EVENT, never by polling the store: the idle seam runs on
# the main pump thread, and a store read there is a blocking request/reply that
# starves every other message the component owes (it also stalls for the full
# store timeout in a component run WITHOUT a harness — which is how every
# component contract test starts a component, and how a standalone build runs.
# config publishes `ev.config.updated` after every applied change; a
# subscription to it is a normal handler, so the refresh costs nothing until a
# setting actually changes.

type OwnerSnapshot* = ref object
  store: OwnerStore
  values: JsonNode
  loaded: bool

proc newOwnerSnapshot*(store: OwnerStore): OwnerSnapshot =
  OwnerSnapshot(store: store, values: newJObject())

proc refresh*(s: OwnerSnapshot, c: Component, timeoutMs = 5_000) =
  ## Reload from the owner's record. Call this from a HANDLER (the
  ## ev.config.updated subscription or a startup hook), never from onIdle.
  ## A store that cannot answer keeps the last known values: losing the store
  ## must not silently reset retention to defaults.
  try:
    s.values = c.loadOwnerValues(s.store, timeoutMs).values
    s.loaded = true
  except CatchableError:
    if not s.loaded: s.values = newJObject()

proc watchConfig*(c: Component, s: OwnerSnapshot, domain: string,
                  onChanged: proc(c: Component) = nil) =
  ## Subscribe the snapshot to config's change event for one domain, so the
  ## values follow a config_patch with no polling and no restart.
  discard c.on("ev.config.updated") do (comp: Component, subject: string,
                                        payload: JsonNode):
    let changed = payload{"domain"}.getStr("")
    if changed.len > 0 and changed != domain: return
    s.refresh(comp)
    if onChanged != nil: onChanged(comp)

proc values*(s: OwnerSnapshot): JsonNode = s.values

proc str*(s: OwnerSnapshot, name, envName, dflt: string): string =
  settingStr(s.values, name, envName, dflt)

proc flag*(s: OwnerSnapshot, name, envName: string, dflt: bool): bool =
  settingBool(s.values, name, envName, dflt)

proc num*(s: OwnerSnapshot, name, envName: string, dflt: int): int =
  settingInt(s.values, name, envName, dflt)

proc ownerToolSchema*(domain, description: string): JsonNode =
  ## The hidden schema every owner tool shares. Mirrors
  ## OwnerToolSchema in sdk/go/configowner.go so an owner in either SDK
  ## presents the same contract to config.
  %*{"type": "object",
     "properties": {
       "op": {"type": "string", "enum": ["get", "patch", "reset"]},
       "patch": {"type": "object"},
       "properties": {"type": "array", "items": {"type": "string"}},
       "expectRev": {"type": "integer"}},
     "required": ["op"],
     "description": "Owner-side settings protocol for the " & domain &
       " configuration domain. Called by the config component, which validates the schema and enforces approval; never call it directly.",
     "x-harness": {"hidden": true}}
