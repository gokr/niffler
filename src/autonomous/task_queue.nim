## Autonomous Task Queue Module
##
## Handles task queue processing for autonomous agents. Tasks are pulled from
## the database and processed using the existing task execution system.

import std/[options, json, strformat, strutils, os, logging]
import ../core/database
import ../core/task_executor
import ../core/channels
import ../workspace/manager
import ../types/[config, agents]
import ../tools/registry
import debby/pools
import debby/mysql

type
  TaskProcessor* = ref object
    db*: DatabaseBackend
    workspaceMgr*: WorkspaceManager
    agentId*: string
    agent*: AgentDefinition
    modelConfig*: ModelConfig
    channels*: ptr ThreadChannels
    running*: bool
    pollInterval*: int           ## Milliseconds between polls
    currentTask*: Option[TaskQueueEntry]

proc newTaskProcessor*(
  db: DatabaseBackend, 
  workspaceMgr: WorkspaceManager, 
  agentId: string,
  agent: AgentDefinition,
  modelConfig: ModelConfig,
  channels: ptr ThreadChannels
): TaskProcessor =
  ## Create a new task processor
  result = TaskProcessor(
    db: db,
    workspaceMgr: workspaceMgr,
    agentId: agentId,
    agent: agent,
    modelConfig: modelConfig,
    channels: channels,
    running: false,
    pollInterval: 1000,          ## Default 1 second poll interval
    currentTask: none(TaskQueueEntry)
  )

proc fetchNextTask*(processor: TaskProcessor): Option[TaskQueueEntry] =
  ## Fetch the next pending task from the queue
  if processor.db == nil:
    return none(TaskQueueEntry)
  
  var queryStr = """
    SELECT id, workspace_id, priority, task_type, source_channel, source_id, 
           instruction, context, assigned_agent
    FROM task_queue_entry 
    WHERE status = 'pending' AND (assigned_agent = ? OR assigned_agent = '')
    ORDER BY priority DESC, created_at ASC
    LIMIT 1
  """
  
  let rows = processor.db.pool.query(queryStr, processor.agentId)
  
  if rows.len > 0:
    let row = rows[0]
    try:
      var task = TaskQueueEntry(
        id: parseInt(row[0]),
        workspaceId: if row[1] != "" and row[1] != "NULL": some(parseInt(row[1])) else: none(int),
        priority: parseInt(row[2]),
        taskType: parseEnum[TaskType](row[3]),
        sourceChannel: row[4],
        sourceId: row[5],
        instruction: row[6],
        context: row[7],
        assignedAgent: row[8],
        status: tsQueuePending
      )
      return some(task)
    except Exception as e:
      error(fmt("Failed to parse task row: {e.msg}"))
  
  return none(TaskQueueEntry)

proc claimTask*(processor: TaskProcessor, taskId: int): bool =
  ## Claim a task for this agent
  if processor.db == nil:
    return false
  
  processor.db.pool.withDb:
    # Check if task is still pending
    let rows = db.query("SELECT id FROM task_queue_entry WHERE id = ? AND status = 'pending'", taskId)
    if rows.len == 0:
      return false
    
    # Update task status
    db.query("""
      UPDATE task_queue_entry 
      SET status = 'running', assigned_agent = ?, started_at = NOW() 
      WHERE id = ?
    """, processor.agentId, taskId)
    
    return true

proc completeTask*(processor: TaskProcessor, taskId: int, result: string) =
  ## Mark a task as completed
  if processor.db == nil:
    return
  
  processor.db.pool.withDb:
    db.query("""
      UPDATE task_queue_entry 
      SET status = 'completed', result = ?, completed_at = NOW() 
      WHERE id = ?
    """, result, taskId)
  
  processor.currentTask = none(TaskQueueEntry)

proc failTask*(processor: TaskProcessor, taskId: int, error: string) =
  ## Mark a task as failed
  if processor.db == nil:
    return
  
  processor.db.pool.withDb:
    db.query("""
      UPDATE task_queue_entry 
      SET status = 'failed', error = ?, completed_at = NOW() 
      WHERE id = ?
    """, error, taskId)
  
  processor.currentTask = none(TaskQueueEntry)

proc createTask*(
  db: DatabaseBackend,
  instruction: string,
  taskType: TaskType = ttUserRequest,
  sourceChannel: string = "internal",
  sourceId: string = "",
  workspaceId: Option[int] = none(int),
  assignedAgent: string = "",
  priority: int = 0,
  context: JsonNode = newJObject()
): int =
  ## Create a new task in the queue
  if db == nil:
    return 0
  
  let wsIdStr = if workspaceId.isSome: $workspaceId.get else: "NULL"
  
  db.pool.withDb:
    db.query("""
      INSERT INTO task_queue_entry 
      (workspace_id, priority, status, task_type, source_channel, source_id, instruction, context, assigned_agent)
      VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
    """, wsIdStr, $priority, $taskType, sourceChannel, sourceId, instruction, $context, assignedAgent)
    
    # Get the last inserted ID
    let idRows = db.query("SELECT LAST_INSERT_ID()")
    if idRows.len > 0:
      return parseInt(idRows[0][0])
  
  return 0

proc processTask*(processor: TaskProcessor, task: TaskQueueEntry) =
  ## Process a single task using the existing task execution system
  {.gcsafe.}:
    debug(fmt("Processing task {task.id}: {task.instruction}"))
    
    try:
      # Set up workspace context if specified
      if task.workspaceId.isSome:
        processor.workspaceMgr.setActiveWorkspace(task.workspaceId.get)
      
      # Get tool schemas for this agent
      let toolSchemas = getAllToolSchemas()
      
      # Execute the task using the existing task executor
      let taskResult = executeTask(
        processor.agent,
        task.instruction,
        processor.modelConfig,
        processor.channels,
        toolSchemas,
        processor.db
      )
      
      # Store the result
      if taskResult.success:
        let resultJson = %*{
          "success": true,
          "summary": taskResult.summary,
          "artifacts": taskResult.artifacts,
          "toolCalls": taskResult.toolCalls,
          "tokensUsed": taskResult.tokensUsed,
          "durationMs": taskResult.durationMs
        }
        completeTask(processor, task.id, $resultJson)
        info(fmt("Task {task.id} completed successfully"))
      else:
        failTask(processor, task.id, taskResult.error)
        error(fmt("Task {task.id} failed: {taskResult.error}"))
        
    except Exception as e:
      error(fmt("Task {task.id} failed: {e.msg}"))
      failTask(processor, task.id, e.msg)

proc taskProcessorLoop*(processor: TaskProcessor) {.gcsafe.} =
  ## Main task processor loop
  processor.running = true
  info(fmt("Task processor started for agent {processor.agentId}"))
  
  while processor.running:
    try:
      # Fetch next task
      let nextTask = fetchNextTask(processor)
      
      if nextTask.isSome:
        let task = nextTask.get()
        info(fmt("Found task {task.id}: {task.instruction}"))
        
        # Claim the task
        if claimTask(processor, task.id):
          processor.currentTask = some(task)
          # Process the task
          processTask(processor, task)
        else:
          warn(fmt("Failed to claim task {task.id}"))
      else:
        # No tasks available, sleep before next poll
        sleep(processor.pollInterval)
    except Exception as e:
      error(fmt("Error in task processor loop: {e.msg}"))
      sleep(processor.pollInterval)
  
  info(fmt("Task processor stopped for agent {processor.agentId}"))

proc startTaskProcessor*(processor: TaskProcessor) =
  ## Start the task processor
  if processor.running:
    warn("Task processor is already running")
    return
  
  # Run synchronously for now
  taskProcessorLoop(processor)

proc stopTaskProcessor*(processor: TaskProcessor) =
  ## Stop the task processor
  processor.running = false
  info("Task processor stop requested")

proc isRunning*(processor: TaskProcessor): bool =
  ## Check if the task processor is running
  return processor.running

proc getCurrentTask*(processor: TaskProcessor): Option[TaskQueueEntry] =
  ## Get the currently executing task
  return processor.currentTask
