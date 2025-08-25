## Dynamic System Prompt Generation
##
## This module generates context-aware system prompts based on the current mode,
## workspace state, and available tools. It implements the agentic behavior
## patterns by providing mode-specific instructions to the LLM.
##
## Key Features:
## - Mode-specific prompts for Plan vs Code behavior
## - Workspace context detection (git status, current directory)
## - Automatic instruction file discovery (CLAUDE.md, README.md)
## - Tool availability awareness
## - Environment information injection

import std/[strformat, strutils, os, times, osproc, sequtils, options, tables]
import ../types/[mode, messages]
import ../tools/registry
import config

# Base system prompt templates
const
  COMMON_SYSTEM_PROMPT* = """
You are Niffler, an AI-powered terminal assistant built in Nim. You provide conversational assistance with software development tasks while supporting tool calling for file operations, command execution, and web fetching.

Available tools: {availableTools}

Current environment:
- Working directory: {currentDir}
- Current time: {currentTime}
- OS: {osInfo}
{gitInfo}
{projectInfo}

General guidelines:
- Be concise and direct in responses
- Use tools when needed to gather information or make changes
- Follow project conventions and coding standards
- Always validate information before making changes
"""

  PLAN_MODE_PROMPT* = """
**PLAN MODE ACTIVE**

You are in Plan mode - focus on analysis, research, and breaking down tasks into actionable steps.

Plan mode priorities:
1. **Research thoroughly** before suggesting implementation
2. **Break down complex tasks** into smaller, manageable steps
3. **Identify dependencies** and potential challenges
4. **Suggest approaches** and gather requirements
5. **Use read/list tools extensively** to understand the codebase
6. **Create detailed plans** before moving to implementation

In Plan mode:
- Read files to understand current implementation
- List directories to explore project structure
- Research existing patterns and conventions
- Ask clarifying questions when requirements are unclear
- Propose step-by-step implementation plans
- Avoid making changes until the plan is clear
"""

  CODE_MODE_PROMPT* = """
**CODE MODE ACTIVE**

You are in Code mode - focus on implementation and execution of planned tasks.

Code mode priorities:
1. **Execute plans efficiently** and make concrete changes
2. **Implement solutions** using edit/create/bash tools
3. **Test implementations** and verify functionality
4. **Fix issues** as they arise during implementation
5. **Complete tasks systematically** following established plans
6. **Document changes** when significant

In Code mode:
- Make file edits and create new files as needed
- Execute commands to test and verify changes
- Implement features following the established plan
- Address errors and edge cases proactively
- Focus on working, tested solutions
- Be decisive in implementation choices
"""

proc getAvailableToolsList*(): string =
  ## Get formatted list of available tools for system prompt
  return registry.getAvailableToolsList()

proc getCurrentDirectoryInfo*(): string =
  ## Get current working directory information
  try:
    return getCurrentDir()
  except:
    return "Unknown"

proc getOSInfo*(): string =
  ## Get basic OS information
  when defined(windows):
    return "Windows"
  elif defined(macosx):
    return "macOS"
  elif defined(linux):
    return "Linux"
  else:
    return "Unix-like"

proc getGitInfo*(): string =
  ## Get comprehensive git repository information if available
  try:
    if not dirExists(".git"):
      return "\n- Git repository: No"
    
    var gitInfo = "\n- Git repository: Yes"
    
    # Get current branch
    if fileExists(".git/HEAD"):
      try:
        let headContent = readFile(".git/HEAD").strip()
        if headContent.startsWith("ref: refs/heads/"):
          let branch = headContent[16..^1]  # Remove "ref: refs/heads/"
          gitInfo.add(fmt"\n- Current branch: {branch}")
        else:
          gitInfo.add("\n- Current branch: (detached HEAD)")
      except:
        discard
    
    # Check for staged/unstaged changes
    try:
      let (statusOutput, statusCode) = execCmdEx("git status --porcelain")
      if statusCode == 0:
        let lines = statusOutput.splitLines().filterIt(it.len > 0)
        if lines.len > 0:
          gitInfo.add(fmt"\n- Changes: {lines.len} modified files")
        else:
          gitInfo.add("\n- Changes: Clean working tree")
    except:
      discard
    
    return gitInfo
  except:
    return ""

proc getProjectInfo*(): string =
  ## Get basic project context without hardcoded assumptions
  var additionalInfo = ""
  
  # Only include generic indicators that might be useful
  if fileExists("Dockerfile"):
    additionalInfo.add("\n- Containerized project")
  
  if fileExists("Makefile"):
    additionalInfo.add("\n- Has Makefile")
  
  # Count source files in common directories to give a sense of project size
  var sourceFileCount = 0
  let commonSourceDirs = @["src", "lib", "app", "."]
  
  for dir in commonSourceDirs:
    if dirExists(dir):
      try:
        for file in walkDirRec(dir):
          if file.splitFile().ext in [".nim", ".py", ".js", ".ts", ".rs", ".go", ".c", ".cpp", ".java"]:
            inc sourceFileCount
            if sourceFileCount > 100:  # Stop counting after 100 to avoid performance issues
              break
      except:
        continue
      if sourceFileCount > 100:
        break
  
  if sourceFileCount > 0:
    if sourceFileCount > 100:
      additionalInfo.add("\n- Large codebase (100+ source files)")
    elif sourceFileCount > 20:
      additionalInfo.add(fmt"\n- Medium codebase ({sourceFileCount} source files)")
    else:
      additionalInfo.add(fmt"\n- Small codebase ({sourceFileCount} source files)")
  
  return additionalInfo

proc parseMarkdownSections*(content: string): Table[string, string] =
  ## Parse markdown content and extract sections under h1 headings
  result = initTable[string, string]()
  let lines = content.splitLines()
  
  var currentHeading = ""
  var currentContent: seq[string] = @[]
  
  for line in lines:
    if line.startsWith("# "):
      # Save previous section if it exists
      if currentHeading.len > 0:
        result[currentHeading] = currentContent.join("\n").strip()
      
      # Start new section
      currentHeading = line[2..^1].strip()  # Remove "# " prefix
      currentContent = @[]
    else:
      # Add line to current section
      if currentHeading.len > 0:
        currentContent.add(line)
  
  # Save the last section
  if currentHeading.len > 0:
    result[currentHeading] = currentContent.join("\n").strip()

proc processFileIncludes*(content: string, basePath: string): string =
  ## Process @include directives in content and replace with file contents
  result = content
  let lines = content.splitLines()
  var processedLines: seq[string] = @[]
  
  for line in lines:
    let trimmedLine = line.strip()
    if trimmedLine.startsWith("@include "):
      let filename = trimmedLine[9..^1].strip()  # Remove "@include " prefix
      let includePath = if filename.isAbsolute(): filename else: basePath / filename
      
      if fileExists(includePath):
        try:
          let includeContent = readFile(includePath)
          processedLines.add(fmt"<!-- Included from {filename} -->")
          processedLines.add(includeContent)
          processedLines.add(fmt"<!-- End of {filename} -->")
        except:
          processedLines.add(fmt"<!-- Failed to include {filename} -->")
      else:
        processedLines.add(fmt"<!-- File not found: {filename} -->")
    else:
      processedLines.add(line)
  
  result = processedLines.join("\n")

proc extractSystemPromptsFromNiffler*(): tuple[common: string, planMode: string, codeMode: string] =
  ## Extract system prompts from NIFFLER.md searching project hierarchy then config dir
  var searchPaths: seq[string] = @[]
  
  # First search up the project hierarchy
  var searchPath = getCurrentDir()
  let maxDepth = 3  # Search up to 3 levels
  
  for depth in 0..<maxDepth:
    searchPaths.add(searchPath)
    let parentPath = searchPath.parentDir()
    if parentPath == searchPath:  # Reached root
      break
    searchPath = parentPath
  
  # Then search in config directory (~/.niffler)
  try:
    let configDir = getDefaultConfigPath().parentDir()
    searchPaths.add(configDir)
  except:
    discard
  
  # Search all paths for NIFFLER.md
  for searchDir in searchPaths:
    let nifflerPath = searchDir / "NIFFLER.md"
    if fileExists(nifflerPath):
      try:
        let rawContent = readFile(nifflerPath)
        # Process any @include directives
        let content = processFileIncludes(rawContent, searchDir)
        let sections = parseMarkdownSections(content)
        
        let commonPrompt = sections.getOrDefault("Common System Prompt", "")
        let planPrompt = sections.getOrDefault("Plan Mode Prompt", "")
        let codePrompt = sections.getOrDefault("Code Mode Prompt", "")
        
        return (commonPrompt, planPrompt, codePrompt)
      except:
        discard
  
  return ("", "", "")

proc findInstructionFiles*(): string =
  ## Find and include instruction files, searching project hierarchy then config dir
  var instructionContent = ""
  
  # Get instruction files from config, or use defaults
  let config = loadConfig()
  let instructionFiles = if config.instructionFiles.isSome():
    config.instructionFiles.get()
  else:
    @["NIFFLER.md", "CLAUDE.md", "OCTO.md", "AGENT.md"]
  
  # Build search paths - project hierarchy first, then config directory
  var searchPaths: seq[string] = @[]
  var searchPath = getCurrentDir()
  let maxDepth = 3  # Search up to 3 levels
  
  for depth in 0..<maxDepth:
    searchPaths.add(searchPath)
    let parentPath = searchPath.parentDir()
    if parentPath == searchPath:  # Reached root
      break
    searchPath = parentPath
  
  # Add config directory to search paths
  try:
    let configDir = getDefaultConfigPath().parentDir()
    searchPaths.add(configDir)
  except:
    discard
  
  # Search all paths for instruction files
  for depth, searchDir in searchPaths:
    for filename in instructionFiles:
      let fullPath = searchDir / filename
      if fileExists(fullPath):
        try:
          let rawContent = readFile(fullPath)
          let relativePath = if depth == 0: filename else: "../".repeat(depth) & filename
          
          # For NIFFLER.md, exclude the system prompt sections but include everything else
          if filename == "NIFFLER.md":
            # Process includes first
            let contentWithIncludes = processFileIncludes(rawContent, searchDir)
            let sections = parseMarkdownSections(contentWithIncludes)
            var filteredContent = ""
            
            for heading, sectionContent in sections:
              # Skip the system prompt sections
              if heading notin ["Common System Prompt", "Plan Mode Prompt", "Code Mode Prompt"]:
                filteredContent.add(fmt"# {heading}\n\n{sectionContent}\n\n")
            
            if filteredContent.len > 0:
              instructionContent.add(fmt"\n\n--- {relativePath} ---\n{filteredContent}")
          else:
            # Process includes for non-NIFFLER.md files too
            let contentWithIncludes = processFileIncludes(rawContent, searchDir)
            instructionContent.add(fmt"\n\n--- {relativePath} ---\n{contentWithIncludes}")
          
          return instructionContent  # Return after finding the first instruction file
        except:
          continue
  
  return instructionContent

proc generateSystemPrompt*(mode: AgentMode): string =
  ## Generate complete system prompt based on current mode and context
  let availableTools = getAvailableToolsList()
  let currentDir = getCurrentDirectoryInfo()
  let currentTime = now().format("yyyy-MM-dd HH:mm:ss")
  let osInfo = getOSInfo()
  let gitInfo = getGitInfo()
  let projectInfo = getProjectInfo()
  let instructionFiles = findInstructionFiles()
  
  # Try to extract prompts from NIFFLER.md, fallback to hardcoded
  let (nifflerCommon, nifflerPlan, nifflerCode) = extractSystemPromptsFromNiffler()
  
  let commonPrompt = if nifflerCommon.len > 0: nifflerCommon else: COMMON_SYSTEM_PROMPT
  let planPrompt = if nifflerPlan.len > 0: nifflerPlan else: PLAN_MODE_PROMPT
  let codePrompt = if nifflerCode.len > 0: nifflerCode else: CODE_MODE_PROMPT
  
  # Build base prompt with context
  var systemPrompt = commonPrompt.multiReplace([
    ("{availableTools}", availableTools),
    ("{currentDir}", currentDir),
    ("{currentTime}", currentTime),
    ("{osInfo}", osInfo),
    ("{gitInfo}", gitInfo),
    ("{projectInfo}", projectInfo)
  ])
  
  # Add mode-specific instructions
  case mode:
  of amPlan:
    systemPrompt.add("\n\n" & planPrompt)
  of amCode:
    systemPrompt.add("\n\n" & codePrompt)
  
  # Add instruction files if found
  if instructionFiles.len > 0:
    systemPrompt.add("\n\n**Project Instructions:**")
    systemPrompt.add(instructionFiles)
  
  return systemPrompt

proc createSystemMessage*(mode: AgentMode): Message =
  ## Create a system message with generated prompt
  return Message(
    role: mrSystem,
    content: generateSystemPrompt(mode)
  )