# batchrename

This package has one function, `OldName`, whose definition lives in
`def.go` and which is called from every `fNN.go` file. Rename it to
`NewName` everywhere: the definition and every call site. The test suite
verifies the rename is complete and behavior is unchanged.

There are many call sites — use whatever your harness provides for
mechanical, repetitive work.
