## Fixed-capacity FIFO ring buffer.
##
## * `push` appends; when full, the oldest element is silently overwritten.
## * `pop` removes and returns the oldest element; it raises
##   `RingBufferEmptyError` when empty.
## * `len` is the number of live elements (<= capacity).

type
  RingBufferEmptyError* = object of CatchableError
  RingBuffer*[T] = object
    data: seq[T]
    head: int    ## index of the oldest element
    count: int   ## number of live elements

proc initRingBuffer*[T](capacity: Positive): RingBuffer[T] =
  raise newException(CatchableError, "not implemented")

proc push*[T](rb: var RingBuffer[T], value: T) =
  raise newException(CatchableError, "not implemented")

proc pop*[T](rb: var RingBuffer[T]): T =
  raise newException(CatchableError, "not implemented")

proc len*[T](rb: RingBuffer[T]): int =
  raise newException(CatchableError, "not implemented")
