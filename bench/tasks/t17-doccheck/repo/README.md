# doccheck

The repository holds Go files. The project invariant: **every exported
function (a top-level function whose name starts with an uppercase letter)
must have a doc comment — a comment line immediately above it that starts
with `// <FunctionName>`.**

Your job:

1. Write a checker that verifies the invariant across every `.go` file and
   reports each violation (file, line, function name). Make it invocable as
   `./check.sh` (create that file): it must exit 0 and print `clean` when
   the repo satisfies the invariant, and exit 1 listing violations
   otherwise.
2. Fix every violation the checker reports so that `./check.sh` exits 0.

The checker may be implemented any way you like — a script, a program, or,
if your harness can build and register custom tools at runtime, such a
tool invoked from `./check.sh`.

`./test.sh` runs your `./check.sh` and also verifies the repository still
compiles.
