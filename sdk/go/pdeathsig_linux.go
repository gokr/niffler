//go:build linux

package sdk

import (
	"os"

	"golang.org/x/sys/unix"
)

// dieWithParent asks the kernel to SIGTERM this process the moment the parent
// dies — even on SIGKILL — so a crashed test or core can never leave
// components behind. The ppid re-check closes the fork race: if the parent
// died between fork and this call, we were re-parented and exit immediately.
func dieWithParent() {
	ppid := os.Getppid()
	_ = unix.Prctl(unix.PR_SET_PDEATHSIG, uintptr(unix.SIGTERM), 0, 0, 0)
	if os.Getppid() != ppid {
		os.Exit(1)
	}
}
