import std/[locks, deques, options]

type
  ThreadSafeQueue*[T] = object
    queue: Deque[T]
    lock: Lock
    notEmpty: Cond

proc initThreadSafeQueue*[T](): ThreadSafeQueue[T] =
  initLock(result.lock)
  initCond(result.notEmpty)
  result.queue = initDeque[T]()

proc send*[T](queue: var ThreadSafeQueue[T], item: T) =
  acquire(queue.lock)
  try:
    queue.queue.addLast(item)
    signal(queue.notEmpty)
  finally:
    release(queue.lock)

proc trySend*[T](queue: var ThreadSafeQueue[T], item: T): bool =
  if tryAcquire(queue.lock):
    try:
      queue.queue.addLast(item)
      signal(queue.notEmpty)
      return true
    finally:
      release(queue.lock)
  return false

proc receive*[T](queue: var ThreadSafeQueue[T]): T =
  acquire(queue.lock)
  try:
    while queue.queue.len == 0:
      wait(queue.notEmpty, queue.lock)
    result = queue.queue.popFirst()
  finally:
    release(queue.lock)

proc tryReceive*[T](queue: var ThreadSafeQueue[T]): Option[T] =
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