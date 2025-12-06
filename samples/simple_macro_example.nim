# Simple Nim Macro Example
# This demonstrates the basic concepts of Nim macros

import std/[macros, strutils]

# Macro 1: A simple debug macro that prints both the expression and its value
macro debug(expression: untyped): untyped =
  # This macro transforms: debug(x + y)
  # Into: echo("x + y = ", x + y)
  
  # Get the string representation of the expression
  let exprStr = expression.toStrLit
  
  # Create the result using quasi-quoting
  result = quote do:
    echo(`exprStr`, " = ", `expression`)

# Macro 2: A macro that generates a simple for loop
macro repeat(times: static[int], body: untyped): untyped =
  # This macro transforms: repeat(3, echo("hello"))
  # Into: for i in 0..<3: echo("hello")
  
  # Create a for loop
  let loopVar = ident("i")  # Create identifier "i"
  let start = newLit(0)     # Create literal 0
  let endRange = newLit(times)  # Create literal times
  
  # Build the for loop AST
  result = newNimNode(nnkForStmt)
  result.add(loopVar)  # loop variable: i
  result.add(newNimNode(nnkInfix).add(
    ident(".."),
    start,
    endRange
  ))  # range: 0..times
  result.add(body)  # loop body

# Macro 3: A macro that creates a getter and setter for a field
macro accessors(fieldName: untyped, fieldType: typedesc): untyped =
  # This macro transforms: accessors(name, string)
  # Into: 
  #   var name: string
  #   proc getName(): string = name
  #   proc setName(value: string) = name = value
  
  # Create the field variable
  let fieldVar = newNimNode(nnkVarSection).add(
    newIdentDefs(fieldName, fieldType)
  )
  
  # Create getter: getFieldName()
  let getterName = ident("get" & capitalizeAscii($fieldName))
  let getter = newProc(
    name = getterName,
    params = [fieldType],  # return type
    body = newStmtList(fieldName)  # return field
  )
  
  # Create setter: setFieldName(value: fieldType)
  let setterName = ident("set" & capitalizeAscii($fieldName))
  let valueParam = ident("value")
  let setter = newProc(
    name = setterName,
    params = [newEmptyNode(),  # no return type
              newIdentDefs(valueParam, fieldType)],  # parameter
    body = newStmtList(
      newAssignment(fieldName, valueParam)  # field = value
    )
  )
  
  # Return all three statements
  result = newStmtList(fieldVar, getter, setter)

# Let's test our macros
echo "=== Testing debug macro ==="
let x = 10
let y = 20
debug(x + y)  # Will print: x + y = 30
debug(x * y)  # Will print: x * y = 200

echo "\n=== Testing repeat macro ==="
repeat 3:
  echo("Hello from macro!")

echo "\n=== Testing accessors macro ==="
# Generate accessors for an 'age' field
accessors(age, int)

# Now we can use the generated accessor functions
setAge(25)
echo("Age is: ", getAge())  # Will print: Age is: 25

# Let's see what AST the debug macro generates
echo "\n=== AST inspection ==="
macro showAst(code: untyped): untyped =
  echo("AST for: ", code.repr)
  echo("Tree form: ", code.treeRepr)
  return code

showAst(debug(1 + 2))