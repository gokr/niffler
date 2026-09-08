//go:build linux

package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// dieWithParent: kernel-enforced cleanup (Linux): SIGTERM this server the
// moment the spawning core (or test/bench helper) dies — even on SIGKILL —
// so no orphaned bus can outlive its owner. The ppid re-check closes the
// fork race.
func dieWithParent() {
	ppid := os.Getppid()
	_ = unix.Prctl(unix.PR_SET_PDEATHSIG, uintptr(unix.SIGTERM), 0, 0, 0)
	if os.Getppid() != ppid {
		os.Exit(1)
	}
}
