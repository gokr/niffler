# Local worktree instructions

This checkout carries the Maki-inspired reliability slices. Keep each slice
small and independently testable; prefer the existing NATS contracts and
prompt-cache invariants over new global state. Run the narrowest component
contract test after changes, then the full server gate before merging.
