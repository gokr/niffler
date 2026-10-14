## Birth-time agent definition resolution, shared by roots and subagents.
## Pure data: the caller supplies a store reader. Persona remains prompt text;
## an agent document holds technical defaults. Explicit fields (including empty
## values) win. Approvals are never supplied by definitions: only the human's
## session control may grant auto approval. Frozen-prefix effect: birth only.
import std/[json, strutils]

type DefinitionReader* = proc(kind, id: string): JsonNode {.closure.}

proc resolveAgentDefinition*(args: JsonNode, read: DefinitionReader): JsonNode =
  ## Resolve an `agent` store document into first-call arguments. Missing or
  ## malformed explicit selections fail closed, never silently run a different
  ## role. The result is a copy; caller-private fields are preserved unchanged.
  result = args.copy()
  let name = args{"agent"}.getStr("").strip()
  if name.len == 0: return
  if name.len > 64:
    raise newException(ValueError, "agent name exceeds 64 characters")
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      raise newException(ValueError, "invalid agent name")
  let doc = read("agent", name)
  if doc == nil:
    raise newException(ValueError, "agent '" & name & "' not found")
  if doc.kind != JObject:
    raise newException(ValueError, "agent definition must be an object")
  for key, value in doc:
    if key notin ["name", "note", "persona", "toolset", "model", "provider",
                  "thinking", "tools", "maxRounds", "maxCalls", "maxTokens",
                  "cwd"]:
      raise newException(ValueError, "unsupported agent definition field: " & key)
    if key in ["name", "note"]: continue
    if key == "tools":
      if value.kind != JArray:
        raise newException(ValueError, "agent tools must be an array")
      for item in value:
        if item.kind != JString:
          raise newException(ValueError, "agent tools must contain strings")
    elif key in ["maxRounds", "maxCalls", "maxTokens"]:
      if value.kind != JInt or value.getInt() < 1:
        raise newException(ValueError, "agent " & key & " must be positive")
      if key == "maxCalls" and value.getInt() > 500:
        raise newException(ValueError, "agent maxCalls must be <= 500")
    elif value.kind != JString:
      raise newException(ValueError, "agent " & key & " must be a string")
    if key == "thinking" and value.getStr() notin ["", "low", "medium", "high", "max"]:
      raise newException(ValueError, "invalid agent thinking effort")
    # Legacy tool-profile argument is still an explicit toolset choice.
    if key == "toolset" and args.hasKey("profile"): continue
    if key == "model" and args.hasKey("modelTier"): continue
    if not args.hasKey(key): result[key] = value.copy()
