//go:build linux

package main

import "syscall"

// guardSysProcAttr gives the launched MCP server its own process group (group
// cleanup covers launcher descendants) plus a kernel lifeline: if the guard
// itself is SIGKILLed, the server still receives SIGTERM — no orphaned MCP
// servers in any teardown path.
func guardSysProcAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
}
