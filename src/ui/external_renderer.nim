## External Rendering Module
##
## Provides configurable external tool integration for content and diff rendering.
## Supports tools like batcat for syntax highlighting and delta for advanced diff viewing.
##
## Features:
## - Command template substitution with placeholders
## - Graceful fallback to built-in rendering on external tool failure
## - Error handling and tool availability checking
## - Support for both file-based and stdin-based rendering

import std/[os, osproc, strutils, strformat, json, options, streams]
import ../types/config
import ../core/config

type
  RenderResult* = object
    content*: string
    success*: bool
    errorMsg*: string
    usedExternal*: bool

  RenderingContext* = object
    filePath*: Option[string]
    content*: Option[string]
    language*: Option[string]
    theme*: Option[string]
    lineNumbers*: bool

proc substituteCommandTemplate*(cmdTemplate: string, ctx: RenderingContext): string =
  ## Substitute placeholders in command template with actual values
  result = cmdTemplate
  
  # File path substitution
  if ctx.filePath.isSome():
    result = result.replace("{file}", ctx.filePath.get())
    result = result.replace("{path}", ctx.filePath.get())
  
  # Language/syntax substitution
  if ctx.language.isSome():
    result = result.replace("{language}", ctx.language.get())
    result = result.replace("{syntax}", ctx.language.get())
  
  # Theme substitution
  if ctx.theme.isSome():
    result = result.replace("{theme}", ctx.theme.get())
  else:
    result = result.replace("{theme}", "auto")
  
  # Line numbers flag
  let lineNumFlag = if ctx.lineNumbers: "--line-numbers" else: ""
  result = result.replace("{line-numbers}", lineNumFlag)

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

proc executeExternalRenderer*(commandTemplate: string, ctx: RenderingContext, inputContent: string = ""): RenderResult =
  ## Execute external rendering command with proper error handling
  result = RenderResult()
  
  try:
    let command = substituteCommandTemplate(commandTemplate, ctx)
    let commandParts = command.split()
    
    if commandParts.len == 0:
      result.errorMsg = "Empty command template"
      return result
    
    # Check if command is available
    if not isCommandAvailable(commandParts[0]):
      result.errorMsg = fmt("Command not found: {commandParts[0]}")
      return result
    
    # Execute command
    let process = startProcess(
      commandParts[0], 
      args = commandParts[1..^1],
      options = {poUsePath, poStdErrToStdOut}
    )
    
    # Send input content if provided (for stdin-based rendering)
    if inputContent.len > 0:
      let inputStream = process.inputStream
      inputStream.write(inputContent)
    process.inputStream.close()
    
    # Read output
    let outputStream = process.outputStream
    result.content = outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    
    result.success = (exitCode == 0)
    result.usedExternal = true
    
    if not result.success:
      result.errorMsg = fmt("Command exited with code {exitCode}")
      
  except Exception as e:
    result.errorMsg = fmt("Failed to execute external renderer: {e.msg}")

proc renderFileContent*(filePath: string, config: ExternalRenderingConfig, fallbackContent: string = ""): RenderResult =
  ## Render file content using external tool or fallback to built-in rendering
  result = RenderResult()
  
  if not config.enabled:
    result.content = fallbackContent
    result.success = true
    result.usedExternal = false
    return result
  
  # Determine language from file extension
  let ext = splitFile(filePath).ext.toLowerAscii()
  var language: Option[string]
  case ext:
    of ".nim": language = some("nim")
    of ".py": language = some("python")
    of ".js": language = some("javascript")
    of ".ts": language = some("typescript")
    of ".go": language = some("go")
    of ".rs": language = some("rust")
    of ".cpp", ".cc", ".cxx": language = some("cpp")
    of ".c": language = some("c")
    of ".h", ".hpp": language = some("c")
    of ".java": language = some("java")
    of ".md": language = some("markdown")
    of ".json": language = some("json")
    of ".yaml", ".yml": language = some("yaml")
    of ".toml": language = some("toml")
    of ".xml": language = some("xml")
    of ".html": language = some("html")
    of ".css": language = some("css")
    of ".sh", ".bash": language = some("bash")
    else: language = none(string)
  
  let ctx = RenderingContext(
    filePath: some(filePath),
    language: language,
    theme: some("auto"),
    lineNumbers: true
  )
  
  result = executeExternalRenderer(config.contentRenderer, ctx)
  
  # Fallback to built-in rendering if external command failed and fallback is enabled
  if not result.success and config.fallbackToBuiltin:
    result.content = fallbackContent
    result.success = true
    result.usedExternal = false

proc renderDiff*(diffContent: string, config: ExternalRenderingConfig, fallbackContent: string = ""): RenderResult =
  ## Render diff content using external tool or fallback to built-in rendering
  result = RenderResult()
  
  if not config.enabled:
    result.content = fallbackContent
    result.success = true
    result.usedExternal = false
    return result
  
  let ctx = RenderingContext(
    theme: some("auto"),
    lineNumbers: true
  )
  
  result = executeExternalRenderer(config.diffRenderer, ctx, diffContent)
  
  # Fallback to built-in rendering if external command failed and fallback is enabled
  if not result.success and config.fallbackToBuiltin:
    result.content = fallbackContent
    result.success = true
    result.usedExternal = false

proc renderContentWithTempFile*(content: string, fileExt: string, config: ExternalRenderingConfig, fallbackContent: string = ""): RenderResult =
  ## Render content by creating a temporary file (useful for syntax highlighting)
  result = RenderResult()
  
  if not config.enabled:
    result.content = fallbackContent
    result.success = true
    result.usedExternal = false
    return result
  
  try:
    # Create temporary file with appropriate extension
    let tempFile = getTempDir() / fmt("niffler_render_{getCurrentProcessId()}{fileExt}")
    writeFile(tempFile, content)
    
    # Render using the temporary file
    result = renderFileContent(tempFile, config, fallbackContent)
    
    # Clean up temporary file
    if fileExists(tempFile):
      removeFile(tempFile)
      
  except Exception as e:
    result.errorMsg = fmt("Failed to create temporary file: {e.msg}")
    if config.fallbackToBuiltin:
      result.content = fallbackContent
      result.success = true
      result.usedExternal = false

proc getDefaultExternalRenderingConfig*(): ExternalRenderingConfig =
  ## Get default external rendering configuration with batcat and delta
  ExternalRenderingConfig(
    enabled: true,
    contentRenderer: "batcat --color=always --style=numbers --theme=auto {file}",
    diffRenderer: "delta --line-numbers --syntax-theme=auto",
    fallbackToBuiltin: true
  )

proc getCurrentExternalRenderingConfig*(): ExternalRenderingConfig =
  ## Get current external rendering configuration from global config
  let config = loadConfig()
  if config.externalRendering.isSome():
    return config.externalRendering.get()
  else:
    return getDefaultExternalRenderingConfig()