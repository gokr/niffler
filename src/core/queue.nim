## Thread-Safe Queue Implementation
##
## This module provides a generic thread-safe queue implementation using
## locks and condition variables for efficient inter-thread communication.
##
## Features:
## - Generic type support for any data type
## - Blocking and non-blocking send/receive operations
## - Condition variables for efficient waiting
## - Lock-based synchronization for thread safety

import std/[locks, deques, options]

type
  ThreadSafeQueue*[T] = object
    queue: Deque[T]
    lock: Lock
    notEmpty: Cond

proc initThreadSafeQueue*[T](): ThreadSafeQueue[T] =
  ## Initialize a new thread-safe queue with locks and condition variables
  initLock(result.lock)
  initCond(result.notEmpty)
  result.queue = initDeque[T]()

proc send*[T](queue: var ThreadSafeQueue[T], item: T) =
  ## Blocking send operation - waits to acquire lock and signals waiting receivers
  acquire(queue.lock)
  try:
    queue.queue.addLast(item)
    signal(queue.notEmpty)
  finally:
    release(queue.lock)

proc trySend*[T](queue: var ThreadSafeQueue[T], item: T): bool =
  ## Non-blocking send operation - returns false if lock cannot be acquired immediately
  if tryAcquire(queue.lock):
    try:
      queue.queue.addLast(item)
      signal(queue.notEmpty)
      return true
    finally:
      release(queue.lock)
  return false

proc receive*[T](queue: var ThreadSafeQueue[T]): T =
  ## Blocking receive operation - waits until item is available in queue
  acquire(queue.lock)
  try:
    while queue.queue.len == 0:
      wait(queue.notEmpty, queue.lock)
    result = queue.queue.popFirst()
  finally:
    release(queue.lock)

proc tryReceive*[T](queue: var ThreadSafeQueue[T]): Option[T] =
  ## Non-blocking receive operation - returns None if queue is empty or lock unavailable
  if tryAcquire(queue.lock):
    try:
      if queue.queue.len > 0:
        return some(queue.queue.popFirst())
      else:
        return none(T)
    finally:
      release(queue.lock)
  return none(T)

proc len*[T](queue: var ThreadSafeQueue[T]): int =
  acquire(queue.lock)
  try:
    result = queue.queue.len
  finally:
    release(queue.lock)

proc close*[T](queue: var ThreadSafeQueue[T]) =
  acquire(queue.lock)
  try:
    queue.queue.clear()
  finally:
    release(queue.lock)