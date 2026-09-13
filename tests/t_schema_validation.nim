## Unit tests for bounded nested-call JSON Schema validation.

import std/[json, strutils]
import ../core/schema_validation
import helpers

proc rejected(schema, args: JsonNode, fragment: string): bool =
  validateToolArgs(schema, args).contains(fragment)

proc changed(base: JsonNode, key: string, value: JsonNode): JsonNode =
  result = base.copy()
  result[key] = value

proc main() =
  let schema = %*{
    "type": "object",
    "additionalProperties": false,
    "required": ["name", "count", "mode", "tags", "config"],
    "properties": {
      "name": {"type": "string", "minLength": 2, "maxLength": 5},
      "count": {"type": "integer", "minimum": 1, "maximum": 3},
      "ratio": {"type": "number"},
      "enabled": {"type": "boolean"},
      "mode": {"type": "string", "enum": ["fast", "safe"]},
      "tags": {"type": "array", "minItems": 1, "maxItems": 2,
               "items": {"type": "string"}},
      "labels": {"type": "object",
                 "additionalProperties": {"type": "string"}},
      "config": {"type": "object", "maxProperties": 1,
                 "additionalProperties": false,
                 "properties": {"level": {"type": "integer"}}}
    }
  }
  let valid = %*{"name": "okay", "count": 2, "ratio": 0.5,
                 "enabled": false, "mode": "safe", "tags": ["a"],
                 "labels": {"team": "core"},
                 "config": {"level": 1}}
  check("complete supported schema accepts valid arguments",
        validateToolArgs(schema, valid).len == 0)
  check("root object enforced", rejected(schema, %*[1], "object"))
  check("required property enforced",
        rejected(schema, %*{"name": "okay"}, "count is required"))
  check("scalar type enforced",
        rejected(schema, changed(valid, "count", %"2"), "integer"))
  check("enum enforced",
        rejected(schema, changed(valid, "mode", %"slow"), "enum"))
  check("numeric bounds enforced",
        rejected(schema, changed(valid, "count", %4), "maximum"))
  check("string bounds enforced",
        rejected(schema, changed(valid, "name", %"x"), "minLength"))
  check("array item types enforced",
        rejected(schema, changed(valid, "tags", %*[1]), "string"))
  check("array bounds enforced",
        rejected(schema, changed(valid, "tags", %*[]), "too few"))
  check("additional properties rejected",
        rejected(schema, changed(valid, "extra", %true), "not an allowed"))
  check("additional property schema enforced",
        rejected(schema, changed(valid, "labels", %*{"team": 1}), "string"))

  let nullable = %*{"required": ["value"],
    "properties": {"value": {"type": "null"}}}
  check("required means present, not non-null",
    validateToolArgs(nullable, %*{"value": nil}).len == 0)
  check("missing required null still rejected",
    rejected(nullable, %*{}, "required"))
  for spec in [%*{"type": "array", "maxItems": 0},
               %*{"type": "object", "maxProperties": 0},
               %*{"type": "string", "maxLength": 0}]:
    let zeroSchema = %*{"properties": {"value": spec}}
    let nonempty = case spec{"type"}.getStr()
      of "array": %*[1]
      of "object": %*{"x": 1}
      else: %"x"
    check("zero maximum enforced for " & spec{"type"}.getStr(),
      validateToolArgs(zeroSchema, %*{"value": nonempty}).len > 0)
  let unicodeSchema = %*{"properties": {
    "value": {"type": "string", "minLength": 2, "maxLength": 2}}}
  check("string length counts Unicode characters, not UTF-8 bytes",
    validateToolArgs(unicodeSchema, %*{"value": "é🙂"}).len == 0)
  check("multibyte character does not satisfy minLength two",
    rejected(unicodeSchema, %*{"value": "é"}, "minLength"))

  var deepSchema = %*{"type": "object"}
  for i in 0 ..< 34:
    deepSchema = %*{"type": "object", "properties": {"x": deepSchema}}
  var deepValue = %*{}
  for i in 0 ..< 34:
    deepValue = %*{"x": deepValue}
  check("schema recursion is bounded",
        validateToolArgs(deepSchema, deepValue).contains("nesting depth"))

  var wideProperties = newJObject()
  for i in 0 ..< 10_001:
    wideProperties["field" & $i] = %*{"type": "string"}
  let wideSchema = %*{"type": "object", "properties": wideProperties}
  check("schema size is bounded independently of arguments",
        validateToolArgs(wideSchema, %*{}).contains("nodes"))

  report("schema validation")

main()
