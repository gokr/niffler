import std/[strformat, times, locks, strutils, os]

type
  LogLevel* = enum
    llDebug = "DEBUG"
    llInfo = "INFO" 
    llWarn = "WARN"
    llError = "ERROR"
    llFatal = "FATAL"

  Logger* = object
    level: LogLevel
    lock: Lock

var globalLogger {.threadvar.}: Logger

proc initLogger*(level: LogLevel = llInfo) =
  globalLogger.level = level
  initLock(globalLogger.lock)

proc formatLogMessage(level: LogLevel, threadName: string, msg: string): string =
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss.fff")
  return fmt"[{timestamp}] [{$level}] [{threadName}] {msg}"

proc shouldLog(level: LogLevel): bool =
  return ord(level) >= ord(globalLogger.level)

proc logMessage(level: LogLevel, threadName: string, msg: string) =
  if not shouldLog(level):
    return
    
  acquire(globalLogger.lock)
  try:
    let formatted = formatLogMessage(level, threadName, msg)
    if level >= llError:
      stderr.writeLine(formatted)
    else:
      stdout.writeLine(formatted)
    flushFile(stdout)
  finally:
    release(globalLogger.lock)

proc logDebug*(threadName: string, msg: string) =
  logMessage(llDebug, threadName, msg)

proc logInfo*(threadName: string, msg: string) =
  logMessage(llInfo, threadName, msg)

proc logWarn*(threadName: string, msg: string) =
  logMessage(llWarn, threadName, msg)

proc logError*(threadName: string, msg: string) =
  logMessage(llError, threadName, msg)

proc logFatal*(threadName: string, msg: string) =
  logMessage(llFatal, threadName, msg)

# Convenience templates for common use cases
template debug*(msg: string) =
  logDebug("main", msg)

template info*(msg: string) = 
  logInfo("main", msg)

template warn*(msg: string) =
  logWarn("main", msg)

template error*(msg: string) =
  logError("main", msg)

template fatal*(msg: string) =
  logFatal("main", msg)

# Error handling with automatic logging
proc handleError*(threadName: string, error: ref Exception): string =
  let errorMsg = fmt"Exception in {threadName}: {error.msg}"
  logError(threadName, errorMsg)
  logDebug(threadName, "Stack trace: " & error.getStackTrace())
  return errorMsg

proc handleErrorWithFallback*[T](threadName: string, operation: proc(): T, fallback: T): T =
  try:
    return operation()
  except Exception as e:
    discard handleError(threadName, e)
    return fallback

# Thread-safe error recovery
type
  ErrorRecovery* = object
    maxRetries*: int
    retryDelay*: int # milliseconds

proc withRetry*[T](threadName: string, operation: proc(): T, recovery: ErrorRecovery): T =
  var attempts = 0
  
  while attempts <= recovery.maxRetries:
    try:
      return operation()
    except Exception as e:
      attempts += 1
      let errorMsg = fmt"Attempt {attempts}/{recovery.maxRetries + 1} failed: {e.msg}"
      
      if attempts > recovery.maxRetries:
        logError(threadName, fmt"Operation failed after {attempts} attempts, giving up")
        raise e
      else:
        logWarn(threadName, errorMsg & fmt", retrying in {recovery.retryDelay}ms...")
        sleep(recovery.retryDelay)

proc setLogLevel*(level: LogLevel) =
  acquire(globalLogger.lock)
  try:
    globalLogger.level = level
  finally:
    release(globalLogger.lock)