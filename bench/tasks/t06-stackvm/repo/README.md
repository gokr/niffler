# stackvm — a tiny stack machine

`vm.go` is the executor, `asm.go` the assembler. **This file is the
normative spec**; the tests encode it.

## Machine model

- One stack of ints. Inputs are consumed with `READ`, results produced with
  `WRITE`.
- `Execute(prog, inputs...)` returns everything `WRITE` produced, in order.
- Running past the last instruction is an **implicit halt**.
- Every invalid operation is an **error**: stack underflow, unknown opcode,
  modulo by zero, exhausted input, and a jump target outside
  `[0, len(prog))`.

## Instructions

`a` = second-from-top, `b` = top of the stack.

| mnemonic | stack before → after | semantics |
|----------|----------------------|-----------|
| `PUSH n` | … → … n              | push the literal n |
| `ADD`    | … a b → … (a+b)      | |
| `SUB`    | … a b → … (a-b)      | a was pushed first |
| `MUL`    | … a b → … (a*b)      | |
| `MOD`    | … a b → … (a%b)      | Go remainder (sign of the dividend); b = 0 → error |
| `NEG`    | … x → … (-x)         | |
| `DUP`    | … x → … x x          | needs 1 element |
| `SWAP`   | … a b → … b a        | needs 2 elements |
| `OVER`   | … a b → … a b a      | copies the second element; needs 2 |
| `DROP`   | … x → …              | |
| `EQ`     | … a b → … c          | c = 1 iff a == b, else 0 |
| `LT`     | … a b → … c          | c = 1 iff a < b, else 0 |
| `READ`   | … → … input          | push the next input value; exhausted input → error |
| `WRITE`  | … x → …              | append x to the output |
| `JMP t`  |                      | pc = t (absolute instruction index) |
| `JZ t`   | pops c               | pc = t iff c == 0 |
| `JNZ t`  | pops c               | pc = t iff c != 0 |
| `HALT`   |                      | stop and return the output |

Inputs are pushed in the order given, so the **last input ends on top**.

## Assembly language

- One instruction per line; mnemonics are **uppercase**.
- `name:` defines a label referring to the instruction index of the **next
  emitted instruction**. Redefining a label is an error.
- `;` starts a comment running to the end of the line; blank lines are
  ignored.
- Jump targets are labels or literal instruction indexes; `PUSH` takes a
  literal only.
- `PUSH` and the jumps take exactly one operand; every other instruction
  takes none. Unknown mnemonics, unknown labels, and wrong operand counts
  are errors.
