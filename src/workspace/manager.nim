## Workspace Management Module
##
## Manages multiple workspaces through the database. Each workspace represents
## a project directory with its own configuration and state.

import std/[options, tables, os, json, strutils, strformat, times]
import ../core/database
import debby/pools
import debby/mysql

type
  WorkspaceManager* = ref object
    db*: DatabaseBackend
    activeWorkspace*: Option[int]
    workspaceCache*: Table[int, Workspace]

proc newWorkspaceManager*(db: DatabaseBackend): WorkspaceManager =
  ## Create a new workspace manager
  result = WorkspaceManager(
    db: db,
    activeWorkspace: none(int),
    workspaceCache: initTable[int, Workspace]()
  )

proc listWorkspaces*(mgr: WorkspaceManager): seq[Workspace] =
  ## List all workspaces
  if mgr.db == nil:
    return @[]
  
  mgr.db.pool.withDb:
    result = db.filter(Workspace)

proc getWorkspace*(mgr: WorkspaceManager, id: int): Option[Workspace] =
  ## Get a workspace by ID
  if mgr.db == nil:
    return none(Workspace)
  
  # Check cache first
  if mgr.workspaceCache.hasKey(id):
    return some(mgr.workspaceCache[id])
  
  mgr.db.pool.withDb:
    let workspaces = db.filter(Workspace, it.id == id)
    if workspaces.len > 0:
      mgr.workspaceCache[id] = workspaces[0]
      return some(workspaces[0])
  
  return none(Workspace)

proc getWorkspaceByName*(mgr: WorkspaceManager, name: string): Option[Workspace] =
  ## Get a workspace by name
  if mgr.db == nil:
    return none(Workspace)
  
  mgr.db.pool.withDb:
    let workspaces = db.filter(Workspace, it.name == name)
    if workspaces.len > 0:
      return some(workspaces[0])
  
  return none(Workspace)

proc getWorkspaceByPath*(mgr: WorkspaceManager, path: string): Option[Workspace] =
  ## Get a workspace by path
  if mgr.db == nil:
    return none(Workspace)
  
  # Normalize path for comparison
  let normalizedPath = absolutePath(path)
  
  mgr.db.pool.withDb:
    let workspaces = db.filter(Workspace)
    for ws in workspaces:
      if absolutePath(ws.path) == normalizedPath:
        return some(ws)
  
  return none(Workspace)

proc createWorkspace*(mgr: WorkspaceManager, name, path: string, description: string = ""): Option[Workspace] =
  ## Create a new workspace
  if mgr.db == nil:
    return none(Workspace)
  
  # Check if workspace with this name or path already exists
  if getWorkspaceByName(mgr, name).isSome:
    raise newException(ValueError, fmt("Workspace '{name}' already exists"))
  
  let absPath = absolutePath(path)
  if not dirExists(absPath):
    raise newException(ValueError, fmt("Directory does not exist: {absPath}"))
  
  if getWorkspaceByPath(mgr, absPath).isSome:
    raise newException(ValueError, fmt("Workspace already exists for path: {absPath}"))
  
  var workspace = Workspace(
    id: 0,
    name: name,
    path: absPath,
    description: description,
    gitRemote: "",
    defaultBranch: "main",
    settings: "{}",
    createdAt: now().utc(),
    lastAccessed: now().utc()
  )
  
  mgr.db.pool.withDb:
    db.insert(workspace)
  
  # Update cache
  mgr.workspaceCache[workspace.id] = workspace
  
  return some(workspace)

proc updateWorkspace*(mgr: WorkspaceManager, id: int, updates: Workspace): bool =
  ## Update workspace fields
  if mgr.db == nil:
    return false
  
  let existing = getWorkspace(mgr, id)
  if existing.isNone:
    return false
  
  var workspace = existing.get
  
  # Apply updates
  if updates.name.len > 0:
    workspace.name = updates.name
  if updates.path.len > 0:
    workspace.path = updates.path
  if updates.description.len > 0:
    workspace.description = updates.description
  if updates.gitRemote.len > 0:
    workspace.gitRemote = updates.gitRemote
  if updates.defaultBranch.len > 0:
    workspace.defaultBranch = updates.defaultBranch
  if updates.settings.len > 0:
    workspace.settings = updates.settings
  
  workspace.lastAccessed = now().utc()
  
  mgr.db.pool.withDb:
    db.update(workspace)
  
  # Update cache
  mgr.workspaceCache[id] = workspace
  
  return true

proc deleteWorkspace*(mgr: WorkspaceManager, id: int): bool =
  ## Delete a workspace (soft delete - just mark as deleted or actually delete)
  if mgr.db == nil:
    return false
  
  let existing = getWorkspace(mgr, id)
  if existing.isNone:
    return false
  
  mgr.db.pool.withDb:
    db.delete(existing.get())
  
  # Remove from cache
  if mgr.workspaceCache.hasKey(id):
    mgr.workspaceCache.del(id)
  
  # Clear active workspace if it was this one
  if mgr.activeWorkspace.isSome and mgr.activeWorkspace.get == id:
    mgr.activeWorkspace = none(int)
  
  return true

proc setActiveWorkspace*(mgr: WorkspaceManager, id: int) =
  ## Set the active workspace
  let workspace = getWorkspace(mgr, id)
  if workspace.isNone:
    raise newException(ValueError, fmt("Workspace {id} not found"))
  
  mgr.activeWorkspace = some(id)
  
  # Update last accessed
  mgr.db.pool.withDb:
    var ws = workspace.get()
    ws.lastAccessed = now().utc()
    db.update(ws)

proc getActiveWorkspace*(mgr: WorkspaceManager): Option[Workspace] =
  ## Get the currently active workspace
  if mgr.activeWorkspace.isNone:
    return none(Workspace)
  return getWorkspace(mgr, mgr.activeWorkspace.get)

proc resolvePath*(mgr: WorkspaceManager, relativePath: string): string =
  ## Resolve a relative path against the active workspace
  let active = getActiveWorkspace(mgr)
  if active.isNone:
    # No active workspace, use current directory
    return absolutePath(relativePath)
  
  let workspace = active.get()
  let fullPath = joinPath(workspace.path, relativePath)
  return absolutePath(fullPath)

proc isPathInWorkspace*(mgr: WorkspaceManager, path: string): bool =
  ## Check if a path is within the active workspace
  let active = getActiveWorkspace(mgr)
  if active.isNone:
    return true  # No workspace restrictions
  
  let workspacePath = active.get().path
  let absPath = absolutePath(path)
  return absPath.startsWith(workspacePath)

proc getWorkspaceSettings*(mgr: WorkspaceManager, workspaceId: int): JsonNode =
  ## Get workspace settings as JSON
  let workspace = getWorkspace(mgr, workspaceId)
  if workspace.isNone:
    return newJObject()
  
  try:
    return parseJson(workspace.get().settings)
  except:
    return newJObject()

proc setWorkspaceSettings*(mgr: WorkspaceManager, workspaceId: int, settings: JsonNode) =
  ## Set workspace settings
  let workspace = getWorkspace(mgr, workspaceId)
  if workspace.isNone:
    raise newException(ValueError, fmt("Workspace {workspaceId} not found"))
  
  var ws = workspace.get()
  ws.settings = $settings
  ws.lastAccessed = now().utc()
  
  mgr.db.pool.withDb:
    db.update(ws)
  
  # Update cache
  mgr.workspaceCache[workspaceId] = ws
