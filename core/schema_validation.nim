## Bounded validation for the JSON Schema subset published by Niffler tools.

import std/[json, sets]

const
  maxSchemaDepth = 32
  maxSchemaNodes = 10_000

proc checkSchemaBounds(schema: JsonNode, depth: int, nodes: var int): string =
  if schema == nil: return ""
  inc nodes
  if nodes > maxSchemaNodes:
    return "tool schema exceeds " & $maxSchemaNodes & " nodes"
  if depth > maxSchemaDepth:
    return "tool schema exceeds nesting depth " & $maxSchemaDepth
  case schema.kind
  of JObject:
    for name, child in schema:
      let err = checkSchemaBounds(child, depth + 1, nodes)
      if err.len > 0: return err
  of JArray:
    for i in 0 ..< schema.len:
      let err = checkSchemaBounds(schema[i], depth + 1, nodes)
      if err.len > 0: return err
  else:
    discard

proc valueType(value: JsonNode): string =
  if value == nil: return "missing"
  case value.kind
  of JObject: "object"
  of JArray: "array"
  of JString: "string"
  of JInt: "integer"
  of JFloat: "number"
  of JBool: "boolean"
  of JNull: "null"

proc matchesType(value: JsonNode, expected: string): bool =
  if value == nil: return false
  case expected
  of "object": value.kind == JObject
  of "array": value.kind == JArray
  of "string": value.kind == JString
  of "integer": value.kind == JInt
  of "number": value.kind in {JInt, JFloat}
  of "boolean": value.kind == JBool
  of "null": value.kind == JNull
  else: true

proc validateNode(schema, value: JsonNode, path: string, depth: int,
                  nodes: var int): string =
  if schema == nil or schema.kind != JObject: return ""
  inc nodes
  if nodes > maxSchemaNodes:
    return "tool schema exceeds " & $maxSchemaNodes & " nodes"
  if depth > maxSchemaDepth:
    return "tool schema exceeds nesting depth " & $maxSchemaDepth

  let expected = schema{"type"}.getStr("")
  if expected.len > 0 and not matchesType(value, expected):
    return path & " must be " & expected & ", got " & value.valueType()

  let allowed = schema{"enum"}
  if allowed != nil and allowed.kind == JArray:
    var found = false
    for item in allowed:
      if item == value:
        found = true
        break
    if not found:
      return path & " must be one of the declared enum values"

  if value == nil: return ""
  case value.kind
  of JObject:
    let required = schema{"required"}
    if required != nil and required.kind == JArray:
      for field in required:
        let name = field.getStr("")
        if name.len > 0:
          let child = value{name}
          if child == nil or child.kind == JNull:
            return path & "." & name & " is required"
    if value.len < schema{"minProperties"}.getInt(0):
      return path & " has too few properties"
    let maxProperties = schema{"maxProperties"}.getInt(0)
    if maxProperties > 0 and value.len > maxProperties:
      return path & " has too many properties"
    let properties = schema{"properties"}
    var known = initHashSet[string]()
    if properties != nil and properties.kind == JObject:
      for name, childSchema in properties:
        known.incl(name)
        let child = value{name}
        if child != nil:
          let err = validateNode(childSchema, child, path & "." & name,
                                 depth + 1, nodes)
          if err.len > 0: return err
    let additional = schema{"additionalProperties"}
    if additional != nil:
      for name, child in value:
        if name in known: continue
        if additional.kind == JBool and not additional.getBool(true):
          return path & "." & name & " is not an allowed property"
        if additional.kind == JObject:
          let err = validateNode(additional, child, path & "." & name,
                                 depth + 1, nodes)
          if err.len > 0: return err
  of JArray:
    if value.len < schema{"minItems"}.getInt(0):
      return path & " has too few items"
    let maxItems = schema{"maxItems"}.getInt(0)
    if maxItems > 0 and value.len > maxItems:
      return path & " has too many items"
    let items = schema{"items"}
    if items != nil:
      for i in 0 ..< value.len:
        let err = validateNode(items, value[i], path & "[" & $i & "]",
                               depth + 1, nodes)
        if err.len > 0: return err
  of JString:
    if value.getStr().len < schema{"minLength"}.getInt(0):
      return path & " is shorter than minLength"
    let maxLength = schema{"maxLength"}.getInt(0)
    if maxLength > 0 and value.getStr().len > maxLength:
      return path & " is longer than maxLength"
  of JInt, JFloat:
    let number = value.getFloat()
    if schema{"minimum"} != nil and number < schema{"minimum"}.getFloat():
      return path & " is below minimum"
    if schema{"maximum"} != nil and number > schema{"maximum"}.getFloat():
      return path & " is above maximum"
  else:
    discard

proc validateToolArgs*(schema, args: JsonNode): string =
  ## Return an actionable error, or an empty string when arguments are valid.
  if args == nil or args.kind != JObject:
    return "arguments must be an object"
  var schemaNodes = 0
  result = checkSchemaBounds(schema, 0, schemaNodes)
  if result.len > 0: return
  var nodes = 0
  result = validateNode(schema, args, "arguments", 0, nodes)
