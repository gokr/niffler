//go:build !linux

package main

// dieWithParent is a no-op off Linux: no PR_SET_PDEATHSIG equivalent, and
// Unix simply orphans children.
func dieWithParent() {}
