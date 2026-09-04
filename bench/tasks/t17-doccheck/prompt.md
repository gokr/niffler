You are working in the git repository at {{REPO}}.

Task: The repository's invariant: every exported Go function must have a
doc comment immediately above it starting with `// <FunctionName>`
(see `README.md`).

1. Write a checker that verifies the invariant across every `.go` file and
   reports each violation (file, line, function). Make it invocable as
   `./check.sh` (create that file): exit 0 and print `clean` when the repo
   satisfies the invariant, exit 1 listing violations otherwise.
2. Fix every violation so `./check.sh` exits 0.

The checker may take any form — a script, a program, or, if your harness
can build and register custom tools at runtime, such a tool invoked from
`./check.sh`.

Rules:
- Run `./test.sh` (from the repository root) to verify — it must exit 0.
- Do NOT modify `test.sh`, `go.mod`, or `README.md`.
- Work only inside the repository. When the check passes, reply with a
  one-line summary of the checker you built and the fixes you made.
