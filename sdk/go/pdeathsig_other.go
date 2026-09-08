//go:build !linux

package sdk

// dieWithParent is a no-op off Linux: there is no PR_SET_PDEATHSIG equivalent,
// and Unix simply orphans children. Mirrors sdk/niffler/sdk.nim's
// `when defined(linux)` guard — a build constraint, not a runtime check, so
// the Linux-only unix.Prctl symbols are never compiled for other targets.
func dieWithParent() {}
