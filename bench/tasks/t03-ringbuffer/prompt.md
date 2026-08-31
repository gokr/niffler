You are working in the git repository at {{REPO}}.

Task: Implement the `RingBuffer` procs in `src/ringbuffer.nim` so the full
test suite passes. Semantics (also documented in the source):
- `initRingBuffer[T](capacity)` allocates an empty buffer with the given capacity.
- `push` appends; when the buffer is full the oldest element is overwritten.
- `pop` removes and returns the oldest element, raising `RingBufferEmptyError` when empty.
- `len` returns the number of live elements.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `tests/`, `test.sh`, or `README.md`. Keep the public API exactly as declared.
- Work only inside the repository. When the tests pass, reply with a one-line summary.
