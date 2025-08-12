import std/[json, strutils, tables, options, sequtils, macros]

type
  ValidationError* = object of CatchableError
    field*: string
    expected*: string
    actual*: string

  ValidationResult*[T] = object
    case isValid*: bool
    of true:
      value*: T
    of false:
      errors*: seq[ValidationError]

proc newValidationError*(field, expected, actual: string): ValidationError =
  result.field = field
  result.expected = expected
  result.actual = actual
  result.msg = "Validation failed for field '" & field & "': expected " & expected & ", got " & actual

proc valid*[T](value: T): ValidationResult[T] =
  ValidationResult[T](isValid: true, value: value)

proc invalid*[T](errors: seq[ValidationError]): ValidationResult[T] =
  ValidationResult[T](isValid: false, errors: errors)

proc invalid*[T](error: ValidationError): ValidationResult[T] =
  invalid[T](@[error])

# Basic validators
proc validateString*(node: JsonNode, field: string = ""): ValidationResult[string] =
  if node.kind != JString:
    return invalid[string](newValidationError(field, "string", $node.kind))
  return valid(node.getStr())

proc validateInt*(node: JsonNode, field: string = ""): ValidationResult[int] =
  if node.kind != JInt:
    return invalid[int](newValidationError(field, "int", $node.kind))
  return valid(node.getInt())

proc validateFloat*(node: JsonNode, field: string = ""): ValidationResult[float] =
  if node.kind != JFloat and node.kind != JInt:
    return invalid[float](newValidationError(field, "float", $node.kind))
  if node.kind == JFloat:
    return valid(node.getFloat())
  else:
    return valid(float(node.getInt()))

proc validateBool*(node: JsonNode, field: string = ""): ValidationResult[bool] =
  if node.kind != JBool:
    return invalid[bool](newValidationError(field, "bool", $node.kind))
  return valid(node.getBool())

proc validateArray*[T](node: JsonNode, validator: proc(node: JsonNode, field: string): ValidationResult[T], field: string = ""): ValidationResult[seq[T]] =
  if node.kind != JArray:
    return invalid[seq[T]](newValidationError(field, "array", $node.kind))
  
  var result: seq[T] = @[]
  var errors: seq[ValidationError] = @[]
  
  for i, item in node.getElems().pairs():
    let itemResult = validator(item, field & "[" & $i & "]")
    if itemResult.isValid:
      result.add(itemResult.value)
    else:
      errors.add(itemResult.errors)
  
  if errors.len > 0:
    return invalid[seq[T]](errors)
  return valid(result)

proc validateObject*(node: JsonNode, field: string = ""): ValidationResult[JsonNode] =
  if node.kind != JObject:
    return invalid[JsonNode](newValidationError(field, "object", $node.kind))
  return valid(node)

proc validateOptional*[T](node: JsonNode, validator: proc(node: JsonNode, field: string): ValidationResult[T], field: string = ""): ValidationResult[Option[T]] =
  if node.kind == JNull or not node.hasKey(field):
    return valid(none(T))
  
  let result = validator(node, field)
  if result.isValid:
    return valid(some(result.value))
  else:
    return invalid[Option[T]](result.errors)

proc validateEnum*[T: enum](node: JsonNode, field: string = ""): ValidationResult[T] =
  let strResult = validateString(node, field)
  if not strResult.isValid:
    return invalid[T](strResult.errors)
  
  try:
    let enumValue = parseEnum[T](strResult.value)
    return valid(enumValue)
  except ValueError:
    let validValues = toSeq(T.low..T.high).mapIt($it).join(", ")
    return invalid[T](newValidationError(field, "enum(" & validValues & ")", strResult.value))

# Field extraction helpers
proc getField*(obj: JsonNode, name: string): ValidationResult[JsonNode] =
  if not obj.hasKey(name):
    return invalid[JsonNode](newValidationError(name, "required field", "missing"))
  return valid(obj[name])

proc getOptionalField*(obj: JsonNode, name: string): ValidationResult[Option[JsonNode]] =
  if not obj.hasKey(name):
    return valid(none(JsonNode))
  return valid(some(obj[name]))

# Template for generating validators - simpler than macro
template defineValidator*(name: untyped, validateBody: untyped): untyped =
  proc `name Validator`*(node: JsonNode, field: string = ""): ValidationResult[`name`] =
    validateBody

# Union type validation helper
proc validateUnion*[T](validators: seq[proc(node: JsonNode, field: string): ValidationResult[T]], node: JsonNode, field: string = ""): ValidationResult[T] =
  var allErrors: seq[ValidationError] = @[]
  
  for validator in validators:
    let result = validator(node, field)
    if result.isValid:
      return result
    allErrors.add(result.errors)
  
  return invalid[T](allErrors)

# Thread-safe validation context
type
  ValidationContext* = object
    strictMode*: bool
    allowExtraFields*: bool

proc newValidationContext*(strictMode: bool = true, allowExtraFields: bool = false): ValidationContext =
  ValidationContext(strictMode: strictMode, allowExtraFields: allowExtraFields)

# Helper to combine validation results
proc combine*[T, U](result1: ValidationResult[T], result2: ValidationResult[U]): ValidationResult[(T, U)] =
  if result1.isValid and result2.isValid:
    return valid((result1.value, result2.value))
  
  var errors: seq[ValidationError] = @[]
  if not result1.isValid:
    errors.add(result1.errors)
  if not result2.isValid:
    errors.add(result2.errors)
  
  return invalid[(T, U)](errors)