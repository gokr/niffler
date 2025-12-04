## Text Extraction Module
##
## Provides configurable text extraction from HTML content using:
## - External tools like trafilatura (Python) for high-quality extraction
## - Built-in HTML parser as fallback
##
## Features:
## - Two modes: URL-based (pass URL to command) or stdin-based (pipe HTML content)
## - Command template substitution with {url} placeholder
## - Graceful fallback to built-in extraction on external tool failure
## - Improved built-in extraction with better content detection

import std/[osproc, strutils, strformat, xmltree, options, streams]
import pkg/htmlparser
import ../types/config
import ../core/config

type
  ExtractionResult* = object
    content*: string
    success*: bool
    errorMsg*: string
    usedExternal*: bool

proc isCommandAvailable*(command: string): bool =
  ## Check if external command is available in PATH
  try:
    let parts = command.split()
    if parts.len == 0:
      return false

    let commandName = parts[0]
    let (output, exitCode) = execCmdEx(fmt("which {commandName}"))
    return exitCode == 0 and output.strip().len > 0
  except:
    return false

proc substituteUrlTemplate*(cmdTemplate: string, url: string): string =
  ## Substitute {url} placeholder in command template with actual URL
  result = cmdTemplate.replace("{url}", url)

proc extractTextBuiltin*(html: string): ExtractionResult =
  ## Extract text from HTML using built-in parser with improved content detection
  result = ExtractionResult()

  try:
    let xml = parseHtml(html)
    var textResult = ""

    proc shouldSkipTag(tag: string): bool =
      ## Tags to skip entirely (scripts, styles, etc.)
      tag.toLowerAscii() in ["script", "style", "noscript", "iframe", "object", "embed"]

    proc isBlockElement(tag: string): bool =
      ## Block elements that should add newlines
      tag.toLowerAscii() in [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "br", "hr", "blockquote", "pre",
        "article", "section", "header", "footer", "nav", "aside",
        "table", "tr", "td", "th"
      ]

    proc extractText(node: XmlNode, text: var string, skipDepth: var int) =
      if node.kind == xnText:
        if skipDepth == 0:
          let textContent = node.text.strip()
          if textContent.len > 0:
            text.add(textContent & " ")
      elif node.kind == xnElement:
        let tag = node.tag.toLowerAscii()

        if shouldSkipTag(tag):
          skipDepth += 1

        for child in node:
          extractText(child, text, skipDepth)

        if isBlockElement(tag):
          text.add("\n")

        if shouldSkipTag(tag):
          skipDepth -= 1

    var skipDepth = 0
    extractText(xml, textResult, skipDepth)

    result.content = textResult.strip()
    result.content = result.content.multiReplace(
      ("\n\n\n\n", "\n\n"),
      ("\n\n\n", "\n\n"),
      ("  ", " ")
    )
    result.success = true
    result.usedExternal = false

  except Exception as e:
    result.errorMsg = fmt("Failed to parse HTML: {e.msg}")
    result.success = false

proc extractTextExternalUrl*(command: string, url: string): ExtractionResult =
  ## Extract text using external command with URL as argument
  result = ExtractionResult()

  try:
    let cmdWithUrl = substituteUrlTemplate(command, url)
    let commandParts = cmdWithUrl.split()

    if commandParts.len == 0:
      result.errorMsg = "Empty command template"
      return result

    if not isCommandAvailable(commandParts[0]):
      result.errorMsg = fmt("Command not found: {commandParts[0]}")
      return result

    let (output, exitCode) = execCmdEx(cmdWithUrl)

    result.success = (exitCode == 0)
    result.usedExternal = true

    if result.success:
      result.content = output.strip()
    else:
      result.errorMsg = fmt("Command exited with code {exitCode}")

  except Exception as e:
    result.errorMsg = fmt("Failed to execute external command: {e.msg}")

proc extractTextExternalStdin*(command: string, html: string): ExtractionResult =
  ## Extract text by piping HTML content to external command via stdin
  result = ExtractionResult()

  try:
    let commandParts = command.split()

    if commandParts.len == 0:
      result.errorMsg = "Empty command template"
      return result

    if not isCommandAvailable(commandParts[0]):
      result.errorMsg = fmt("Command not found: {commandParts[0]}")
      return result

    let process = startProcess(
      commandParts[0],
      args = commandParts[1..^1],
      options = {poUsePath, poStdErrToStdOut}
    )

    let inputStream = process.inputStream
    inputStream.write(html)
    process.inputStream.close()

    let outputStream = process.outputStream
    result.content = outputStream.readAll().strip()
    let exitCode = process.waitForExit()
    process.close()

    result.success = (exitCode == 0)
    result.usedExternal = true

    if not result.success:
      result.errorMsg = fmt("Command exited with code {exitCode}")

  except Exception as e:
    result.errorMsg = fmt("Failed to execute external command: {e.msg}")

proc extractText*(html: string, url: string, config: TextExtractionConfig): ExtractionResult =
  ## Main text extraction function that uses external tool or falls back to builtin
  result = ExtractionResult()

  if not config.enabled:
    return extractTextBuiltin(html)

  case config.mode:
  of temUrl:
    result = extractTextExternalUrl(config.command, url)
  of temStdin:
    result = extractTextExternalStdin(config.command, html)

  if not result.success and config.fallbackToBuiltin:
    result = extractTextBuiltin(html)

proc getDefaultTextExtractionConfig*(): TextExtractionConfig =
  ## Get default text extraction configuration
  TextExtractionConfig(
    enabled: true,  # Enable trafilatura by default for better text extraction
    command: "trafilatura -u {url}",
    mode: temUrl,
    fallbackToBuiltin: true
  )

proc getCurrentTextExtractionConfig*(): TextExtractionConfig {.gcsafe.} =
  ## Get current text extraction configuration from global config
  {.gcsafe.}:
    let config = loadConfig()
    if config.textExtraction.isSome():
      return config.textExtraction.get()
    else:
      return getDefaultTextExtractionConfig()
