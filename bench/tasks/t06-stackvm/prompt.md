You are working in the git repository at {{REPO}}.

Task: `vm.go` and `asm.go` implement the tiny stack machine specified in
`README.md` — but several opcode implementations violate the spec, and some
opcodes and assembly features are missing entirely. Fix the broken
implementations and add what is missing so the full test suite passes.

Read `README.md` carefully: it is the contract. The tests exercise the spec
edge cases (operand order, jump semantics, underflow, label resolution).

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test.sh`, `vm_test.go`, or `README.md`.
- Work only inside the repository. When the tests pass, reply with a one-line summary.
