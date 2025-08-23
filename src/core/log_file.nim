## Log File Management
##
## This module provides functionality to redirect debug and dump output to
## incrementally numbered log files for each LLM conversation session.

import std/[os, strformat, strutils, logging, times]

type
  LogFileManager* = ref object
    baseFilename: string
    currentLogFile: string
    fileHandle: File
    isActive: bool

var globalLogManager: LogFileManager = nil

proc findNextLogIndex(baseFilename: string): int =
  ## Find the next available log file index
  result = 1
  while fileExists(fmt"{baseFilename}-{result}.log"):
    inc result

proc initLogFileManager*(baseFilename: string): LogFileManager =
  ## Initialize the log file manager with a base filename
  let nextIndex = findNextLogIndex(baseFilename)
  let logFilename = fmt"{baseFilename}-{nextIndex}.log"
  
  result = LogFileManager(
    baseFilename: baseFilename,
    currentLogFile: logFilename,
    isActive: false
  )

proc activateLogFile*(manager: LogFileManager) =
  ## Activate logging to file for this conversation
  if not manager.isActive:
    manager.fileHandle = open(manager.currentLogFile, fmWrite)
    manager.isActive = true
    manager.fileHandle.writeLine(fmt"=== Niffler Log File: {manager.currentLogFile} ===")
    manager.fileHandle.writeLine(fmt"=== Started at: {now()} ===")
    manager.fileHandle.writeLine("")
    manager.fileHandle.flushFile()

proc closeLogFile*(manager: LogFileManager) =
  ## Close the current log file
  if manager.isActive:
    manager.fileHandle.writeLine("")
    manager.fileHandle.writeLine(fmt"=== Session ended at: {now()} ===")
    manager.fileHandle.close()
    manager.isActive = false

proc writeToLogFile*(manager: LogFileManager, message: string) =
  ## Write a message to the log file
  if manager.isActive:
    manager.fileHandle.write(message)
    manager.fileHandle.flushFile()

proc writeLineToLogFile*(manager: LogFileManager, message: string) =
  ## Write a line to the log file
  if manager.isActive:
    manager.fileHandle.writeLine(message)
    manager.fileHandle.flushFile()

proc setGlobalLogManager*(manager: LogFileManager) =
  ## Set the global log manager instance
  globalLogManager = manager

proc getGlobalLogManager*(): LogFileManager =
  ## Get the global log manager instance
  return globalLogManager

proc isLoggingActive*(): bool =
  ## Check if file logging is currently active
  return globalLogManager != nil and globalLogManager.isActive

# Custom log handler that writes to both console and file
type
  FileAndConsoleLogger* = ref object of Logger
    consoleLogger: ConsoleLogger
    logManager: LogFileManager
    
proc newFileAndConsoleLogger*(logManager: LogFileManager = nil): FileAndConsoleLogger =
  ## Create a logger that writes to both console and log file
  result = FileAndConsoleLogger(
    consoleLogger: newConsoleLogger(),
    logManager: logManager
  )

method log*(logger: FileAndConsoleLogger, level: Level, args: varargs[string, `$`]) {.gcsafe.} =
  ## Log message to both console and file if active
  let message = substituteLog(logger.fmtStr, level, args)
  
  # Always write to console
  logger.consoleLogger.log(level, message)
  
  # Write to file if logging is active and logger has a log manager
  if logger.logManager != nil and logger.logManager.isActive:
    logger.logManager.writeLineToLogFile(message)

# Override echo for dump output redirection
proc logEcho*(message: string) {.gcsafe.} =
  ## Echo that redirects to log file when active
  echo message
  # Note: This is simplified for thread safety. 
  # File logging happens via the main logger for debug/info messages.
  # HTTP dump messages go only to console to avoid GC safety issues.