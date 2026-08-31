import std/unittest
import ringbuffer

suite "ring buffer":
  test "push and pop in FIFO order":
    var rb = initRingBuffer[int](3)
    rb.push(1); rb.push(2); rb.push(3)
    check rb.len == 3
    check rb.pop() == 1
    check rb.pop() == 2
    check rb.len == 1
    check rb.pop() == 3
    check rb.len == 0

  test "overwrite oldest when full":
    var rb = initRingBuffer[int](2)
    rb.push(1); rb.push(2); rb.push(3); rb.push(4)
    check rb.len == 2
    check rb.pop() == 3
    check rb.pop() == 4

  test "works with strings":
    var rb = initRingBuffer[string](2)
    rb.push("a"); rb.push("b"); rb.push("c")
    check rb.pop() == "b"

  test "pop on empty raises":
    var rb = initRingBuffer[int](2)
    expect RingBufferEmptyError:
      discard rb.pop()
