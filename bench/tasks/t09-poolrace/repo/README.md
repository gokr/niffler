# pool

A tiny worker pool: `Run(jobs []int, workers int) int` doubles every job on
one of `workers` goroutines and returns the sum. The test suite fails —
find and fix the bug(s) in `pool.go`. Run `./test.sh` to test (it runs
`go test -race`).
