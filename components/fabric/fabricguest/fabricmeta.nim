## Runtime-schema macro and support types for typed Fabric programs.

import std/[json, macros, sets, strutils, tables]
import fabricguest

export json

type
  FabricTools* = object
  FabricArg*[T] = object
    present*: bool
    value*: T

let tools* = FabricTools()

converter toFabricArg*[T](value: T): FabricArg[T] =
  FabricArg[T](present: true, value: value)

proc fabricJson*[T](value: T): JsonNode =
  %value

proc fabricJson*(value: JsonNode): JsonNode =
  value

const nimKeywords = [
  "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct",
  "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
  "for", "from", "func", "generic", "if", "import", "in", "include",
  "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin",
  "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr",
  "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple",
  "type", "using", "var", "when", "while", "with", "without", "xor", "yield"]

proc nimName(raw: string): string =
  ## Produce a parseable identifier; exact wire names stay in wrapper bodies.
  for c in raw:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      result.add(c)
    else:
      result.add('_')
  if result.len == 0: result = "fabricValue"
  if result[0] in {'0'..'9'}: result = "fabric_" & result
  if result in nimKeywords: result.add("_value")

proc styleKey(name: string): string =
  for c in name:
    if c != '_': result.add(c.toLowerAscii())

proc scalarType(schema: JsonNode): NimNode =
  case schema{"type"}.getStr("")
  of "string": ident("string")
  of "integer": ident("int")
  of "number": ident("float")
  of "boolean": ident("bool")
  of "array":
    let item = schema{"items"}
    if item != nil and item{"type"}.getStr("") in
        ["string", "integer", "number", "boolean"]:
      newTree(nnkBracketExpr, ident("seq"), scalarType(item))
    else:
      ident("JsonNode")
  else:
    ident("JsonNode")

proc isScalarSchema(schema: JsonNode): bool =
  ## True when a wrapper can map the schema to a Nim scalar/seq type;
  ## everything else (objects, mixed arrays, absent schemas) stays JsonNode.
  if schema == nil or schema.kind != JObject: return false
  case schema{"type"}.getStr("")
  of "string", "integer", "number", "boolean": result = true
  of "array":
    let item = schema{"items"}
    result = item != nil and item{"type"}.getStr("") in
      ["string", "integer", "number", "boolean"]
  else: result = false

macro fabricTools*(snapshot: static[string]): untyped =
  ## Generate one method-style wrapper per unambiguous selected tool.
  let entries = parseJson(snapshot)
  result = newStmtList()
  if entries.kind != JArray:
    error("Fabric schema snapshot must be an array")

  var toolCounts = initCountTable[string]()
  for entry in entries:
    toolCounts.inc(styleKey(nimName(entry{"name"}.getStr(""))))

  for entry in entries:
    let rawTool = entry{"name"}.getStr("")
    let wrapperName = nimName(rawTool)
    if rawTool.len == 0 or toolCounts[styleKey(wrapperName)] > 1:
      continue
    let schema = entry{"schema"}
    let properties = schema{"properties"}
    let requiredNode = schema{"required"}
    var required = initHashSet[string]()
    if requiredNode != nil and requiredNode.kind == JArray:
      for node in requiredNode:
        required.incl(node.getStr(""))
    # Optional output typing: a tool may declare an outputSchema alongside
    # its input schema; scalar outputs become typed wrapper results,
    # everything else stays JsonNode (host validation remains authoritative).
    let outSchema = schema{"outputSchema"}
    let typedOut = isScalarSchema(outSchema)
    let returnType = if typedOut: scalarType(outSchema)
                     else: ident("JsonNode")

    var propertyCounts = initCountTable[string]()
    if properties != nil and properties.kind == JObject:
      for rawName, propertySchema in properties:
        propertyCounts.inc(styleKey(nimName(rawName)))
    var ambiguous = false
    for count in propertyCounts.values:
      if count > 1: ambiguous = true
    if ambiguous: continue

    var params = @[returnType,
                   newIdentDefs(ident("fabricTools"), ident("FabricTools"))]
    var body = newStmtList()
    let argsIdent = genSym(nskVar, "fabricCallArgs")
    body.add quote do:
      var `argsIdent` = newJObject()

    # Nim requires mandatory parameters before optional ones regardless of
    # registration order, so emit two stable passes over the raw properties.
    for requiredPass in [true, false]:
      if properties == nil or properties.kind != JObject: continue
      for rawName, propertySchema in properties:
        if (rawName in required) != requiredPass: continue
        let parameter = ident(nimName(rawName))
        let valueType = scalarType(propertySchema)
        if requiredPass:
          params.add(newIdentDefs(parameter, valueType))
          let key = newLit(rawName)
          body.add quote do:
            `argsIdent`[`key`] = fabricJson(`parameter`)
        else:
          let optionalType = newTree(nnkBracketExpr, ident("FabricArg"),
                                     valueType)
          params.add(newIdentDefs(parameter, optionalType,
                                  newCall(optionalType.copyNimTree())))
          let key = newLit(rawName)
          body.add quote do:
            if `parameter`.present:
              `argsIdent`[`key`] = fabricJson(`parameter`.value)

    let wireTool = newLit(rawTool)
    if typedOut:
      body.add quote do:
        result = to(parseJson(callTool(`wireTool`, $`argsIdent`)),
                    `returnType`)
    else:
      body.add quote do:
        result = parseJson(callTool(`wireTool`, $`argsIdent`))
    result.add(newProc(postfix(ident(wrapperName), "*"), params = params,
                       body = body))
