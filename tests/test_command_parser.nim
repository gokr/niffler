import std/[unittest, options, strutils]
import ../src/core/command_parser

suite "Command Parser":
  test "Parse plain prompt with no commands":
    let parsed = parseCommand("Create a simple HTTP server")

    check parsed.mode.isNone()
    check parsed.conversationType.isNone()
    check parsed.model.isNone()
    check parsed.prompt == "Create a simple HTTP server"
    check not parsed.hasCommands()

  test "Parse /plan command":
    let parsed = parseCommand("/plan Create a feature plan")

    check parsed.mode.isSome()
    check parsed.mode.get() == emPlan
    check parsed.conversationType.isNone()
    check parsed.model.isNone()
    check parsed.prompt == "Create a feature plan"
    check parsed.hasCommands()

  test "Parse /code command":
    let parsed = parseCommand("/code Implement the server")

    check parsed.mode.isSome()
    check parsed.mode.get() == emCode
    check parsed.prompt == "Implement the server"
    check parsed.hasCommands()

  test "Parse /task command":
    let parsed = parseCommand("/task Research best practices")

    check parsed.conversationType.isSome()
    check parsed.conversationType.get() == ctTask
    check parsed.mode.isNone()
    check parsed.prompt == "Research best practices"
    check parsed.hasCommands()

  test "Parse /ask command":
    let parsed = parseCommand("/ask Add logging to server")

    check parsed.conversationType.isSome()
    check parsed.conversationType.get() == ctAsk
    check parsed.prompt == "Add logging to server"
    check parsed.hasCommands()

  test "Parse /model command with argument":
    let parsed = parseCommand("/model haiku Write documentation")

    check parsed.model.isSome()
    check parsed.model.get() == "haiku"
    check parsed.mode.isNone()
    check parsed.prompt == "Write documentation"
    check parsed.hasCommands()

  test "Parse /model without argument (invalid)":
    let parsed = parseCommand("/model")

    check parsed.model.isNone()
    check parsed.prompt == ""

  test "Parse multiple commands combined":
    let parsed = parseCommand("/plan /model sonnet Design database schema")

    check parsed.mode.isSome()
    check parsed.mode.get() == emPlan
    check parsed.model.isSome()
    check parsed.model.get() == "sonnet"
    check parsed.conversationType.isNone()
    check parsed.prompt == "Design database schema"
    check parsed.hasCommands()

  test "Parse all commands combined":
    let parsed = parseCommand("/task /plan /model haiku Quick research")

    check parsed.conversationType.isSome()
    check parsed.conversationType.get() == ctTask
    check parsed.mode.isSome()
    check parsed.mode.get() == emPlan
    check parsed.model.isSome()
    check parsed.model.get() == "haiku"
    check parsed.prompt == "Quick research"
    check parsed.hasCommands()

  test "Parse unknown command treats it as prompt":
    let parsed = parseCommand("/unknown Create something")

    check parsed.mode.isNone()
    check parsed.model.isNone()
    check parsed.prompt == "/unknown Create something"

  test "Parse empty string":
    let parsed = parseCommand("")

    check parsed.mode.isNone()
    check parsed.conversationType.isNone()
    check parsed.model.isNone()
    check parsed.prompt == ""
    check not parsed.hasCommands()

  test "Parse whitespace only":
    let parsed = parseCommand("   ")

    check parsed.prompt == ""
    check not parsed.hasCommands()

  test "Case insensitive commands":
    let parsed = parseCommand("/PLAN /MODEL Haiku Test")

    check parsed.mode.isSome()
    check parsed.mode.get() == emPlan
    check parsed.model.isSome()
    check parsed.model.get() == "Haiku"  # Model name preserves case
    check parsed.prompt == "Test"

  test "Commands with extra spaces":
    let parsed = parseCommand("  /plan   /model   sonnet   Design   schema  ")

    check parsed.mode.get() == emPlan
    check parsed.model.get() == "sonnet"
    check parsed.prompt == "Design schema"

  test "String representation for debugging":
    let parsed = parseCommand("/plan /model haiku Create tests")
    let str = $parsed

    check str.contains("plan")
    check str.contains("haiku")
    check str.contains("Create tests")

  test "Real-world example: task with plan mode and model":
    let parsed = parseCommand("/task /plan /model sonnet Research and design multi-agent architecture")

    check parsed.conversationType.get() == ctTask
    check parsed.mode.get() == emPlan
    check parsed.model.get() == "sonnet"
    check parsed.prompt == "Research and design multi-agent architecture"

  test "Real-world example: quick ask with cheap model":
    let parsed = parseCommand("/model haiku What is the current directory structure?")

    check parsed.conversationType.isNone()  # Default ask
    check parsed.mode.isNone()  # Default code
    check parsed.model.get() == "haiku"
    check parsed.prompt == "What is the current directory structure?"
