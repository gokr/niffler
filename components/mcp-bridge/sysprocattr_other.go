//go:build !linux

package main

import "syscall"

// guardSysProcAttr off Linux: own process group only — darwin's SysProcAttr
// has no Pdeathsig field. Cleanup still happens via the explicit
// process-group SIGTERM/SIGKILL in runGuard (transport.go), we just lose the
// kernel lifeline for the SIGKILL-the-guard case.
func guardSysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}
