## Autonomous Task Queue Module
##
## Handles task queue processing for autonomous agents. Tasks are pulled from
## the database and processed by the agent.

import std/[options, json, strformat, strutils, times, os, logging, algorithm]
import ../core/database
import ../workspace/manager
import ../types/config
import debby/pools
import debby/mysql

type
  TaskProcessor* = ref object
    db*: DatabaseBackend
    workspaceMgr*: WorkspaceManager
    agentId*: string
    running*: bool
    pollInterval*: int           ## Milliseconds between polls
    currentTask*: Option[TaskQueueEntry]

proc newTaskProcessor*(db: DatabaseBackend, workspaceMgr: WorkspaceManager, agentId: string): TaskProcessor =
  ## Create a new task processor
  result = TaskProcessor(
    db: db,
    workspaceMgr: workspaceMgr,
    agentId: agentId,
    running: false,
    pollInterval: 1000,          ## Default 1 second poll interval
    currentTask: none(TaskQueueEntry)
  )

proc fetchNextTask*(processor: TaskProcessor): Option[TaskQueueEntry] =
  ## Fetch the next pending task from the queue
  if processor.db == nil:
    return none(TaskQueueEntry)
  
  var queryStr = """
    SELECT * FROM task_queue_entry 
    WHERE status = 'pending' AND (assigned_agent = ? OR assigned_agent = '')
    ORDER BY priority DESC, created_at ASC
    LIMIT 1
  """
  
  let rows = processor.db.pool.query(queryStr, processor.agentId)
  
  if rows.len > 0:
    # Parse the row into a TaskQueueEntry object
    # TODO: Implement proper parsing from database row
    discard
  
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

proc cancelTask*(processor: TaskProcessor, taskId: int) =
  ## Cancel a task
  if processor.db == nil:
    return
  
  processor.db.pool.withDb:
    db.query("""
      UPDATE task_queue_entry 
      SET status = 'cancelled', completed_at = NOW() 
      WHERE id = ?
    """, taskId)
  
  if processor.currentTask.isSome and processor.currentTask.get().id == taskId:
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
  
  let wsId = if workspaceId.isSome: $workspaceId.get else: "NULL"
  
  db.pool.withDb:
    db.query("""
      INSERT INTO task_queue_entry 
      (workspace_id, priority, status, task_type, source_channel, source_id, instruction, context, assigned_agent)
      VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
    """, wsId, $priority, $taskType, sourceChannel, sourceId, instruction, $context, assignedAgent)
    
    # Get the last inserted ID
    let idRows = db.query("SELECT LAST_INSERT_ID()")
    if idRows.len > 0:
      return parseInt(idRows[0][0])
  
  return 0

proc getTask*(db: DatabaseBackend, taskId: int): Option[TaskQueueEntry] =
  ## Get a task by ID
  if db == nil:
    return none(TaskQueueEntry)
  
  # TODO: Implement proper query and parsing
  return none(TaskQueueEntry)

proc listTasks*(
  db: DatabaseBackend,
  status: Option[TaskStatus] = none(TaskStatus),
  workspaceId: Option[int] = none(int),
  agentId: string = "",
  limit: int = 100
): seq[TaskQueueEntry] =
  ## List tasks with optional filters
  if db == nil:
    return @[]
  
  # TODO: Implement proper query with filters
  return @[]

proc processTask*(processor: TaskProcessor, task: TaskQueueEntry) =
  ## Process a single task
  ## This is the main entry point for task execution
  debug(fmt("Processing task {task.id}: {task.instruction}"))
  
  try:
    # Set up workspace context if specified
    if task.workspaceId.isSome:
      processor.workspaceMgr.setActiveWorkspace(task.workspaceId.get)
    
    # Parse context
    let context = parseJson(task.context)
    
    # TODO: Integrate with the existing API worker to process the task
    # For now, just mark as completed with a placeholder result
    # This should be replaced with actual task execution
    
    let result = fmt("Task {task.id} processed successfully. Instruction: {task.instruction}")
    completeTask(processor, task.id, result)
    
    info(fmt("Task {task.id} completed successfully"))
  except Exception as e:
    error(fmt("Task {task.id} failed: {e.msg}"))
    failTask(processor, task.id, e.msg)

proc taskProcessorLoop*(processor: TaskProcessor) {.gcsafe.} =
  ## Main task processor loop - runs in a separate thread
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
  ## Start the task processor in a new thread
  if processor.running:
    warn("Task processor is already running")
    return
  
  # TODO: Proper threading implementation
  # For now, run synchronously
  taskProcessorLoop(processor)
  # spawn taskProcessorLoop(processor)

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
