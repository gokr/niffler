# Tool implementations index
# This file exports all tool implementations and provides registration functions

import ./bash, ./read, ./list, ./edit, ./create, ./fetch
# Add more tool imports as they are implemented:

proc registerAllTools*() =
  ## Register all available tools in the global registry
  registerBashTool()
  registerReadTool()
  registerListTool()
  registerEditTool()
  registerCreateTool()
  registerFetchTool()
  # Add more tool registrations as they are implemented: